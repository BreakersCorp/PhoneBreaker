import CoreMotion
import Combine
import Foundation

enum SpinMode: String, CaseIterable {
    case spin = "spin"
    case backflip = "backflip"
    case sideflip = "sideflip"

    // Nom du mode sans emoji, pour les contextes où l'emoji ferait
    // tache (texte de partage notamment).
    var name: String {
        switch self {
        case .spin: return String(localized: "Spin")
        case .backflip: return String(localized: "Backflip")
        case .sideflip: return String(localized: "Sideflip")
        }
    }

    var label: String { "\(emoji) \(name)" }

    var emoji: String {
        switch self {
        case .spin: return "🌀"
        case .backflip: return "🔄"
        case .sideflip: return "↔️"
        }
    }
}

class MotionManager: ObservableObject {
    private let motion = CMMotionManager()

    // --- État publié, réservé à l'affichage. Écrit uniquement depuis le main
    // thread, via des instantanés envoyés par la file de traitement (voir
    // publishLive et endSession). Pendant une session la publication est
    // throttlée à uiPublishInterval : publier à la cadence brute du gyroscope
    // (50 Hz) forcerait SwiftUI à recalculer la vue à chaque échantillon.
    @Published var currentSpins: Double = 0.0
    @Published var currentRPM: Double = 0.0
    @Published var isSpinning: Bool = false
    // Records absolus séparés par type de rotation, persistés dans
    // UserDefaults sous les clés "allTimeBest_<mode>". Miroir d'affichage
    // de `bests`, qui reste la référence côté traitement.
    @Published var allTimeBests: [SpinMode: Double] = MotionManager.loadAllTimeBests()
    // Compteurs d'événements de fin de session, purs déclencheurs pour le
    // retour haptique côté vue (les valeurs ne sont jamais affichées).
    // Exclusifs l'un de l'autre : une session sauvegardée incrémente
    // recordsBeaten si elle bat le record de son mode, sessionsCompleted
    // sinon — la vue joue un motif haptique différent pour chacun.
    @Published var recordsBeaten: Int = 0
    @Published var sessionsCompleted: Int = 0
    @Published var lastCompletedSession: SpinSessionModel? = nil
    @Published var currentFingerProbability: Double = 0.0
    @Published var isBlockedAfterReverse: Bool = false
    @Published var currentChaosScore: Double = 0.0
    @Published var currentMode: SpinMode = .spin  // ← mode détecté en temps réel

    // --- File de traitement des échantillons. Tout l'état privé ci-dessous
    // lui appartient et ne doit être lu/écrit que depuis cette file : les
    // callbacks CoreMotion y arrivent via motionOperationQueue, et les appels
    // externes (stopTracking, resetBests) y sautent explicitement.
    private let processingQueue = DispatchQueue(label: "MotionManager.processing")
    private lazy var motionOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = processingQueue
        return queue
    }()

    // Cadence maximum de publication vers l'UI pendant une session.
    private let uiPublishInterval: TimeInterval = 1.0 / 15.0
    private var lastPublishTimestamp: TimeInterval = 0.0

    // Équivalents internes des @Published, côté traitement.
    private var sessionActive = false
    private var blockedAfterReverse = false
    private var bests: [SpinMode: Double] = MotionManager.loadAllTimeBests()
    private var liveFingerProbability: Double = 0.0
    private var liveChaosScore: Double = 0.0

    private var totalRadians: Double = 0.0
    private var maxRPM: Double = 0.0
    private var sessionStart: Date?
    // Fins de session/déblocage différés : la file de traitement n'a pas de
    // run loop, donc pas de Timer — on utilise des DispatchWorkItem
    // annulables planifiés sur processingQueue.
    private var stillWorkItem: DispatchWorkItem?
    // Délai (secondes) sous le seuil avant de considérer la session terminée.
    private let stillDelay: Double = 0.2
    private let stillThresholdZ: Double = 30   // spin sur doigt — rapide
    private let stillThresholdX: Double = 15   // backflip — moins rapide
    private let stillThresholdY: Double = 15   // sideflip — moins rapide
    // Anti-rebond au démarrage : nombre d'échantillons consécutifs au-dessus
    // du seuil requis avant de réellement lancer une session. Un geste
    // parasite bref (attraper/retourner le téléphone) ne dépasse le seuil
    // que sur 1-2 échantillons ; sans ce filtre il déclenchait quand même
    // isSpinning (clignotement de l'UI) et verrouillait un sens de rotation
    // arbitraire qui bloquait ensuite le vrai spin (faux "reverse" détecté
    // juste après, via isBlockedAfterReverse).
    private var startCandidateSamples: Int = 0
    private let requiredStartSamples: Int = 6   // ~120 ms à 0.02s/échantillon
    // Nombre de tours minimum pour qu'une session soit sauvegardée. L'anti-
    // rebond filtre les gestes brefs isolés, mais un tilt bref et soutenu
    // (attraper/poser le téléphone) peut quand même le passer sans jamais
    // vraiment "spinner" ensuite (RPM qui retombe sous le seuil dès
    // l'échantillon suivant le démarrage). Ce filtre agit en dernier
    // recours, sur le total final.
    private let minValidSpins: Double = 0.15
    private var spinDirection: Double = 0.0
    private var reverseBlockWorkItem: DispatchWorkItem?
    // Timestamp CoreMotion (horloge monotone, en secondes) du dernier échantillon
    // intégré. Sert à calculer le vrai delta-t entre deux échantillons plutôt que
    // de supposer que gyroUpdateInterval (0.02s) s'est écoulé — la cadence réelle
    // de livraison peut dériver de la cadence demandée.
    private var lastGyroTimestamp: TimeInterval?

    // Échantillons bruts accumulés pendant la fenêtre anti-rebond (voir
    // requiredStartSamples), pour pouvoir les rejouer et les compter une fois
    // la session confirmée — sans ça, les ~120ms de rotation avant
    // confirmation seraient perdues.
    private struct PendingSample {
        let timestamp: TimeInterval
        let x: Double
        let y: Double
        let z: Double
        let accelActivity: Double?
    }
    private var pendingSamples: [PendingSample] = []

    private var rotationRateZSamples: [Double] = []
    private var rotationRateXYSamples: [Double] = []
    private var accelerometerSamples: [Double] = []

    private var detectedMode: SpinMode = .spin

    private static func loadAllTimeBests() -> [SpinMode: Double] {
        var bests: [SpinMode: Double] = [:]
        for mode in SpinMode.allCases {
            bests[mode] = UserDefaults.standard.double(forKey: "allTimeBest_\(mode.rawValue)")
        }
        // Migration de l'ancien record global (avant la séparation par mode) :
        // on ne connaît pas le mode d'origine, on l'attribue au spin, le mode
        // historique par défaut.
        let legacy = UserDefaults.standard.double(forKey: "allTimeBest")
        if legacy > (bests[.spin] ?? 0.0) {
            bests[.spin] = legacy
            UserDefaults.standard.set(legacy, forKey: "allTimeBest_\(SpinMode.spin.rawValue)")
        }
        return bests
    }

    func startTracking() {
        guard motion.isGyroAvailable else { return }
        motion.gyroUpdateInterval = 0.02

        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.05
            motion.startAccelerometerUpdates()
        }

        // Les échantillons sont traités hors du main thread : le main est
        // déjà occupé à rafraîchir la UI SwiftUI, et n'a de toute façon
        // besoin que d'instantanés throttlés (voir publishLive).
        motion.startGyroUpdates(to: motionOperationQueue) { [weak self] data, error in
            guard let self = self, let data = data else { return }
            self.process(data)
        }
    }

    // Traitement d'un échantillon gyroscope. Tourne sur processingQueue.
    private func process(_ data: CMGyroData) {
        if blockedAfterReverse { return }

        // Sélectionne le bon axe selon le mode détecté
        let primaryRate: Double
        switch detectedMode {
        case .spin:
            primaryRate = abs(data.rotationRate.z)
        case .backflip:
            primaryRate = abs(data.rotationRate.x)
        case .sideflip:
            primaryRate = abs(data.rotationRate.y)
        }

        let conv = 60 / (2 * Double.pi)
        let rpm = primaryRate * conv

        let threshold: Double
        switch detectedMode {
        case .spin: threshold = stillThresholdZ
        case .backflip: threshold = stillThresholdX
        case .sideflip: threshold = stillThresholdY
        }

        // Pour démarrer une session, on regarde les 3 axes (pas seulement
        // celui du mode par défaut) — sinon un backflip/sideflip pur ne
        // dépasse jamais le seuil Z et la session ne démarre jamais.
        let rpmX = abs(data.rotationRate.x) * conv
        let rpmY = abs(data.rotationRate.y) * conv
        let rpmZ = abs(data.rotationRate.z) * conv
        let startThresholdMet = rpmZ > stillThresholdZ
            || rpmX > stillThresholdX
            || rpmY > stillThresholdY

        if !sessionActive {
            // Anti-rebond « leaky bucket » : chaque échantillon au-dessus
            // du seuil fait avancer le compteur, chaque échantillon en
            // dessous le fait seulement reculer d'un cran (pas de reset
            // brutal à 0). Un vrai spin a presque toujours un ou deux
            // échantillons de bruit/creux au démarrage (accélération
            // progressive, gyroscope pas parfaitement lisse) ; avec un
            // reset strict, ce creux annulait toute la progression et
            // empêchait la session de démarrer — c'était le bug. Un
            // geste parasite isolé (1-2 échantillons puis plus rien),
            // lui, redescend à 0 avant d'avoir pu atteindre le seuil.
            // Tant qu'il reste de la progression, on bufferise
            // l'échantillon pour pouvoir rejouer toute la fenêtre si le
            // démarrage se confirme.
            if startThresholdMet {
                startCandidateSamples = min(startCandidateSamples + 1, requiredStartSamples)
                let accelActivity: Double?
                if let accelData = motion.accelerometerData {
                    accelActivity = abs(accelData.acceleration.x)
                        + abs(accelData.acceleration.y)
                        + abs(accelData.acceleration.z - 1.0)
                } else {
                    accelActivity = nil
                }
                pendingSamples.append(PendingSample(
                    timestamp: data.timestamp,
                    x: data.rotationRate.x,
                    y: data.rotationRate.y,
                    z: data.rotationRate.z,
                    accelActivity: accelActivity
                ))
            } else {
                startCandidateSamples = max(startCandidateSamples - 1, 0)
                if startCandidateSamples == 0 {
                    pendingSamples.removeAll()
                } else if !pendingSamples.isEmpty {
                    pendingSamples.removeFirst()
                }
            }
            guard startCandidateSamples >= requiredStartSamples else { return }
            startCandidateSamples = 0

            stillWorkItem?.cancel()
            stillWorkItem = nil

            sessionActive = true
            totalRadians = 0.0
            maxRPM = 0.0
            sessionStart = Date()
            rotationRateZSamples = []
            rotationRateXYSamples = []
            accelerometerSamples = []
            lastGyroTimestamp = nil

            let bufferedSamples = pendingSamples
            pendingSamples = []

            // Mode ET sens de rotation sont déterminés tout de suite à
            // partir de TOUTE la fenêtre anti-rebond (moyenne/somme sur
            // ~6+ échantillons), pas sur un seul échantillon instantané
            // ni via une fenêtre de détection séparée après coup. Un
            // échantillon isolé peut être bruité (le gyroscope n'est pas
            // parfaitement lisse) et donner un axe/signe qui ne reflète
            // pas le mouvement réel. Décider après coup posait un
            // problème encore plus grave pour backflip/sideflip : en
            // attendant, le code supposait Z (spin) par défaut, donc le
            // RPM lu (sur Z, quasi nul pour un vrai backflip/sideflip)
            // retombait aussitôt sous le seuil et coupait la session
            // avant même que le mode soit confirmé.
            let avgAbsX = bufferedSamples.map { abs($0.x) }.reduce(0, +) / Double(bufferedSamples.count)
            let avgAbsY = bufferedSamples.map { abs($0.y) }.reduce(0, +) / Double(bufferedSamples.count)
            let avgAbsZ = bufferedSamples.map { abs($0.z) }.reduce(0, +) / Double(bufferedSamples.count)
            if avgAbsZ >= avgAbsX && avgAbsZ >= avgAbsY {
                detectedMode = .spin
            } else if avgAbsX >= avgAbsY {
                detectedMode = .backflip
            } else {
                detectedMode = .sideflip
            }

            let axisValues: [Double]
            switch detectedMode {
            case .spin: axisValues = bufferedSamples.map { $0.z }
            case .backflip: axisValues = bufferedSamples.map { $0.x }
            case .sideflip: axisValues = bufferedSamples.map { $0.y }
            }
            // Somme pondérée par récence plutôt qu'à poids égal : un
            // backflip/sideflip est souvent un lancer en l'air (rotation
            // libre sur plusieurs axes à la fois, contrairement au spin
            // sur doigt qui est mécaniquement contraint à un seul axe),
            // donc le tout début du buffer peut encore refléter le
            // dernier contact de la main plutôt que la rotation une fois
            // stabilisée. Les échantillons les plus récents (les plus
            // proches de ce qui va suivre en direct) comptent plus.
            var weightedSum = 0.0
            for (index, value) in axisValues.enumerated() {
                weightedSum += value * Double(index + 1)
            }
            spinDirection = weightedSum > 0 ? 1.0 : -1.0

            // Rejoue les échantillons accumulés pendant la fenêtre
            // anti-rebond (celui-ci inclus) avec l'axe/sens qu'on vient
            // de verrouiller, pour compter ces ~120ms de rotation au lieu
            // de les jeter. Un échantillon dont le signe ne correspond
            // pas au sens verrouillé (bruit en tout début de geste) est
            // simplement ignoré, pas traité comme un "reverse".
            for sample in bufferedSamples {
                let rate: Double
                switch detectedMode {
                case .spin: rate = sample.z
                case .backflip: rate = sample.x
                case .sideflip: rate = sample.y
                }
                let signedRate = rate * spinDirection
                guard signedRate > 0 else { continue }

                let dt = lastGyroTimestamp.map { sample.timestamp - $0 } ?? motion.gyroUpdateInterval
                lastGyroTimestamp = sample.timestamp

                totalRadians += signedRate * dt
                maxRPM = max(maxRPM, abs(rate) * conv)

                rotationRateZSamples.append(signedRate)
                rotationRateXYSamples.append(abs(sample.x) + abs(sample.y))
                if let accelActivity = sample.accelActivity {
                    accelerometerSamples.append(accelActivity)
                }
            }

            liveFingerProbability = computeFingerProbability(
                zSamples: rotationRateZSamples,
                xySamples: rotationRateXYSamples,
                accelSamples: accelerometerSamples
            )
            liveChaosScore = computeChaosScore(
                zSamples: rotationRateZSamples,
                xySamples: rotationRateXYSamples,
                accelSamples: accelerometerSamples
            )

            // Le RPM affiché est recalculé sur l'axe qu'on vient de
            // verrouiller — celui du haut de la fonction supposait encore
            // le mode de la session précédente.
            let liveRPM: Double
            switch detectedMode {
            case .spin: liveRPM = rpmZ
            case .backflip: liveRPM = rpmX
            case .sideflip: liveRPM = rpmY
            }
            publishLive(timestamp: data.timestamp, rpm: liveRPM, force: true)

            // Le rejeu ci-dessus a déjà traité l'échantillon courant
            // (dernier élément du buffer) : on s'arrête là pour ne pas le
            // compter une deuxième fois via le traitement normal
            // plus bas.
            return
        } else if rpm <= threshold {
            // Session en cours mais retombée sous le seuil : on laisse le
            // travail de fin de session existant suivre son cours, ou on en
            // planifie un.
            if stillWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.stillWorkItem = nil
                    self.endSession(reason: "stillTimer")
                }
                stillWorkItem = work
                processingQueue.asyncAfter(deadline: .now() + stillDelay, execute: work)
            }
            return
        } else {
            stillWorkItem?.cancel()
            stillWorkItem = nil
        }

        // À partir d'ici sessionActive == true : la session continue.
        do {
            // Vérifie le sens de rotation sur le bon axe
            let signedRate: Double
            switch detectedMode {
            case .spin:
                signedRate = data.rotationRate.z * spinDirection
            case .backflip:
                signedRate = data.rotationRate.x * spinDirection
            case .sideflip:
                signedRate = data.rotationRate.y * spinDirection
            }

            if signedRate < -0.5 {
                endSession(reason: "reverse")
                blockedAfterReverse = true
                DispatchQueue.main.async { self.isBlockedAfterReverse = true }
                reverseBlockWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.blockedAfterReverse = false
                    self.reverseBlockWorkItem = nil
                    DispatchQueue.main.async { self.isBlockedAfterReverse = false }
                }
                reverseBlockWorkItem = work
                processingQueue.asyncAfter(deadline: .now() + stillDelay, execute: work)
                return
            }

            guard signedRate > 0 else { return }

            // Delta-t réel écoulé depuis le dernier échantillon intégré,
            // basé sur l'horloge CoreMotion (data.timestamp) plutôt que sur
            // gyroUpdateInterval : la cadence réelle de livraison peut
            // s'écarter de la cadence demandée (0.02s) et cette erreur
            // s'accumulerait sur toute la session si on l'ignorait.
            // Au premier échantillon de la session (pas de référence encore),
            // on retombe sur l'intervalle nominal pour ne pas perdre cet
            // échantillon.
            let dt = lastGyroTimestamp.map { data.timestamp - $0 } ?? motion.gyroUpdateInterval
            lastGyroTimestamp = data.timestamp

            totalRadians += signedRate * dt
            maxRPM = max(maxRPM, rpm)

            rotationRateZSamples.append(signedRate)

            let xyActivity = abs(data.rotationRate.x) + abs(data.rotationRate.y)
            rotationRateXYSamples.append(xyActivity)

            if let accelData = motion.accelerometerData {
                let accelActivity = abs(accelData.acceleration.x) +
                                   abs(accelData.acceleration.y) +
                                   abs(accelData.acceleration.z - 1.0)
                accelerometerSamples.append(accelActivity)
            }

            liveFingerProbability = computeFingerProbability(
                zSamples: rotationRateZSamples,
                xySamples: rotationRateXYSamples,
                accelSamples: accelerometerSamples
            )

            liveChaosScore = computeChaosScore(
                zSamples: rotationRateZSamples,
                xySamples: rotationRateXYSamples,
                accelSamples: accelerometerSamples
            )

            publishLive(timestamp: data.timestamp, rpm: rpm)
        }
    }

    // Envoie un instantané de l'état de la session vers les @Published (main
    // thread). Throttlé à uiPublishInterval sauf si force (transitions de
    // session), pour ne pas imposer un recalcul SwiftUI à chaque échantillon.
    private func publishLive(timestamp: TimeInterval, rpm: Double, force: Bool = false) {
        guard force || timestamp - lastPublishTimestamp >= uiPublishInterval else { return }
        lastPublishTimestamp = timestamp

        let spins = totalRadians / (2 * .pi)
        let spinning = sessionActive
        let mode = detectedMode
        let finger = liveFingerProbability
        let chaos = liveChaosScore
        DispatchQueue.main.async {
            self.currentSpins = spins
            self.currentRPM = rpm
            self.isSpinning = spinning
            self.currentMode = mode
            self.currentFingerProbability = finger
            self.currentChaosScore = chaos
        }
    }

    private func computeChaosScore(
        zSamples: [Double],
        xySamples: [Double],
        accelSamples: [Double]
    ) -> Double {
        guard zSamples.count > 5 else { return 0.0 }

        let zMean = zSamples.reduce(0, +) / Double(zSamples.count)
        let zVariance = zSamples.map { pow($0 - zMean, 2) }.reduce(0, +) / Double(zSamples.count)
        let zChaos = zVariance / 20.0

        let xyMean = xySamples.reduce(0, +) / Double(xySamples.count)
        let xyChaos = xyMean / 5.0

        let accelChaos: Double
        if accelSamples.count > 1 {
            let accelMean = accelSamples.reduce(0, +) / Double(accelSamples.count)
            let accelVariance = accelSamples.map { pow($0 - accelMean, 2) }.reduce(0, +) / Double(accelSamples.count)
            accelChaos = accelVariance / 2.0
        } else {
            accelChaos = 0.0
        }

        var jerkSum: Double = 0.0
        for i in 1..<zSamples.count {
            jerkSum += abs(zSamples[i] - zSamples[i - 1])
        }
        let jerkMean = jerkSum / Double(zSamples.count - 1)
        let jerkChaos = jerkMean / 3.0

        let combined = (zChaos * 0.2) + (xyChaos * 0.4) + (accelChaos * 0.2) + (jerkChaos * 0.2)
        return max(combined, 0.0)
    }

    private func computeFingerProbability(
        zSamples: [Double],
        xySamples: [Double],
        accelSamples: [Double]
    ) -> Double {
        guard zSamples.count > 5 else { return 0.5 }

        let zMean = zSamples.reduce(0, +) / Double(zSamples.count)
        let zVariance = zSamples.map { pow($0 - zMean, 2) }.reduce(0, +) / Double(zSamples.count)
        let zScore = min(zVariance / 0.5, 1.0)

        let xyMean = xySamples.reduce(0, +) / Double(xySamples.count)
        let xyScore = min(xyMean / 2.0, 1.0)

        let accelScore: Double
        if accelSamples.isEmpty {
            accelScore = 0.5
        } else {
            let accelMean = accelSamples.reduce(0, +) / Double(accelSamples.count)
            accelScore = min(accelMean / 0.3, 1.0)
        }

        let combined = (zScore * 0.2) + (xyScore * 0.7) + (accelScore * 0.1)
        return min(max(combined, 0.0), 1.0)
    }

    // Termine la session en cours. Doit être appelée sur processingQueue.
    private func endSession(reason: String = "unknown") {
        guard let start = sessionStart, sessionActive else { return }

        let spins = totalRadians / (2 * .pi)

        // En dessous du seuil minimum, on considère que c'est un mouvement
        // accidentel (attraper/poser le téléphone) plutôt qu'un vrai spin :
        // pas de session sauvegardée, pas de mise à jour des records. L'état
        // est quand même réinitialisé plus bas dans tous les cas.
        if spins >= minValidSpins {
            let probability = computeFingerProbability(
                zSamples: rotationRateZSamples,
                xySamples: rotationRateXYSamples,
                accelSamples: accelerometerSamples
            )

            let chaos = computeChaosScore(
                zSamples: rotationRateZSamples,
                xySamples: rotationRateXYSamples,
                accelSamples: accelerometerSamples
            )

            let mode = detectedMode
            let duration = Date().timeIntervalSince(start)
            let peakRPM = maxRPM

            // Seules les rotations "réelles" (vrai spin, pas un mouvement
            // avec support) comptent pour les records.
            var isNewRecord = false
            if probability >= SpinSessionModel.realSpinThreshold,
               spins > (bests[mode] ?? 0.0) {
                bests[mode] = spins
                UserDefaults.standard.set(spins, forKey: "allTimeBest_\(mode.rawValue)")
                isNewRecord = true
            }
            let bestsSnapshot = bests

            DispatchQueue.main.async {
                self.allTimeBests = bestsSnapshot
                if isNewRecord {
                    self.recordsBeaten += 1
                } else {
                    self.sessionsCompleted += 1
                }
                // Le @Model SwiftData est construit sur le main thread, où
                // ContentView l'insérera dans le modelContext : seules des
                // valeurs simples voyagent entre les files.
                self.lastCompletedSession = SpinSessionModel(
                    totalSpins: spins,
                    duration: duration,
                    maxRPM: peakRPM,
                    fingerProbability: probability,
                    chaosScore: chaos,
                    spinMode: mode.rawValue
                )
            }
        }

        sessionActive = false
        totalRadians = 0.0
        maxRPM = 0.0
        sessionStart = nil
        stillWorkItem?.cancel()
        stillWorkItem = nil
        spinDirection = 0.0
        lastGyroTimestamp = nil
        reverseBlockWorkItem?.cancel()
        reverseBlockWorkItem = nil
        detectedMode = .spin
        liveFingerProbability = 0.0
        liveChaosScore = 0.0
        rotationRateZSamples = []
        rotationRateXYSamples = []
        accelerometerSamples = []

        DispatchQueue.main.async {
            self.isSpinning = false
            self.currentSpins = 0.0
            self.currentRPM = 0.0
            self.currentFingerProbability = 0.0
            self.currentChaosScore = 0.0
            self.currentMode = .spin
        }
    }

    // Remise à zéro des records absolus (bouton corbeille). La copie de
    // référence (`bests`) appartient à la file de traitement, d'où le saut
    // de file avant de mettre à jour UserDefaults et le miroir publié.
    func resetBests() {
        processingQueue.async {
            for mode in SpinMode.allCases {
                self.bests[mode] = 0.0
                UserDefaults.standard.set(0.0, forKey: "allTimeBest_\(mode.rawValue)")
            }
            // Ancienne clé du record global (avant la séparation par mode).
            UserDefaults.standard.removeObject(forKey: "allTimeBest")
            let cleared = self.bests
            DispatchQueue.main.async {
                self.allTimeBests = cleared
            }
        }
    }

    func stopTracking() {
        motion.stopGyroUpdates()
        motion.stopAccelerometerUpdates()
        // La fin de session manipule l'état interne : elle doit s'exécuter
        // sur la file de traitement, après les derniers callbacks déjà
        // en vol.
        processingQueue.async {
            self.reverseBlockWorkItem?.cancel()
            self.reverseBlockWorkItem = nil
            self.blockedAfterReverse = false
            self.endSession(reason: "stopTracking")
            DispatchQueue.main.async { self.isBlockedAfterReverse = false }
        }
    }
}
