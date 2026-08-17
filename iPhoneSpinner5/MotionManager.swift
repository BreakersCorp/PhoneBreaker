import CoreMotion
import Combine
import Foundation

enum SpinMode: String, CaseIterable {
    case spin = "spin"
    case backflip = "backflip"
    case sideflip = "sideflip"

    var label: String {
        switch self {
        case .spin: return String(localized: "🌀 Spin")
        case .backflip: return String(localized: "🔄 Backflip")
        case .sideflip: return String(localized: "↔️ Sideflip")
        }
    }

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

    @Published var currentSpins: Double = 0.0
    @Published var currentRPM: Double = 0.0
    @Published var isSpinning: Bool = false
    // Records absolus séparés par type de rotation, persistés dans
    // UserDefaults sous les clés "allTimeBest_<mode>".
    @Published var allTimeBests: [SpinMode: Double] = MotionManager.loadAllTimeBests()
    @Published var lastCompletedSession: SpinSessionModel? = nil
    @Published var currentFingerProbability: Double = 0.0
    @Published var isBlockedAfterReverse: Bool = false
    @Published var currentChaosScore: Double = 0.0
    @Published var currentMode: SpinMode = .spin  // ← mode détecté en temps réel

    private var totalRadians: Double = 0.0
    private var maxRPM: Double = 0.0
    private var sessionStart: Date?
    private var stillTimer: Timer?
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
    private var reverseBlockTimer: Timer?
    // Timestamp CoreMotion (horloge monotone, en secondes) du dernier échantillon
    // intégré. Sert à calculer le vrai delta-t entre deux échantillons plutôt que
    // de supposer que gyroUpdateInterval (0.02s) s'est écoulé — le callback tourne
    // sur le main thread, qui est aussi occupé à rafraîchir la UI SwiftUI, donc la
    // cadence réelle peut dériver de la cadence demandée.
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

        motion.startGyroUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data else { return }

            // DEBUG print:
//            print(String(format: "[RAW] x=%.2f y=%.2f z=%.2f",
//                abs(data.rotationRate.x),
//                abs(data.rotationRate.y),
//                abs(data.rotationRate.z)))

            if self.isBlockedAfterReverse { return }

            // Sélectionne le bon axe selon le mode détecté
            let primaryRate: Double
            switch self.detectedMode {
            case .spin:
                primaryRate = abs(data.rotationRate.z)
            case .backflip:
                primaryRate = abs(data.rotationRate.x)
            case .sideflip:
                primaryRate = abs(data.rotationRate.y)
            }

            let conv = 60 / (2 * Double.pi)
            let rpm = primaryRate * conv
            self.currentRPM = rpm

            let threshold: Double
            switch self.detectedMode {
            case .spin: threshold = self.stillThresholdZ
            case .backflip: threshold = self.stillThresholdX
            case .sideflip: threshold = self.stillThresholdY
            }

            // Pour démarrer une session, on regarde les 3 axes (pas seulement
            // celui du mode par défaut) — sinon un backflip/sideflip pur ne
            // dépasse jamais le seuil Z et la session ne démarre jamais.
            let rpmX = abs(data.rotationRate.x) * conv
            let rpmY = abs(data.rotationRate.y) * conv
            let rpmZ = abs(data.rotationRate.z) * conv
            let startThresholdMet = rpmZ > self.stillThresholdZ
                || rpmX > self.stillThresholdX
                || rpmY > self.stillThresholdY

            if !self.isSpinning {
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
                    self.startCandidateSamples = min(self.startCandidateSamples + 1, self.requiredStartSamples)
                    let accelActivity: Double?
                    if let accelData = self.motion.accelerometerData {
                        accelActivity = abs(accelData.acceleration.x)
                            + abs(accelData.acceleration.y)
                            + abs(accelData.acceleration.z - 1.0)
                    } else {
                        accelActivity = nil
                    }
                    self.pendingSamples.append(PendingSample(
                        timestamp: data.timestamp,
                        x: data.rotationRate.x,
                        y: data.rotationRate.y,
                        z: data.rotationRate.z,
                        accelActivity: accelActivity
                    ))
                } else {
                    self.startCandidateSamples = max(self.startCandidateSamples - 1, 0)
                    if self.startCandidateSamples == 0 {
                        self.pendingSamples.removeAll()
                    } else if !self.pendingSamples.isEmpty {
                        self.pendingSamples.removeFirst()
                    }
                }
                guard self.startCandidateSamples >= self.requiredStartSamples else { return }
                self.startCandidateSamples = 0

                self.stillTimer?.invalidate()
                self.stillTimer = nil

                self.isSpinning = true
                self.totalRadians = 0.0
                self.maxRPM = 0.0
                self.sessionStart = Date()
                self.rotationRateZSamples = []
                self.rotationRateXYSamples = []
                self.accelerometerSamples = []
                self.lastGyroTimestamp = nil

                let bufferedSamples = self.pendingSamples
                self.pendingSamples = []

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
                    self.detectedMode = .spin
                } else if avgAbsX >= avgAbsY {
                    self.detectedMode = .backflip
                } else {
                    self.detectedMode = .sideflip
                }
                self.currentMode = self.detectedMode

                let axisValues: [Double]
                switch self.detectedMode {
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
                self.spinDirection = weightedSum > 0 ? 1.0 : -1.0

                // Rejoue les échantillons accumulés pendant la fenêtre
                // anti-rebond (celui-ci inclus) avec l'axe/sens qu'on vient
                // de verrouiller, pour compter ces ~120ms de rotation au lieu
                // de les jeter. Un échantillon dont le signe ne correspond
                // pas au sens verrouillé (bruit en tout début de geste) est
                // simplement ignoré, pas traité comme un "reverse".
                for sample in bufferedSamples {
                    let rate: Double
                    switch self.detectedMode {
                    case .spin: rate = sample.z
                    case .backflip: rate = sample.x
                    case .sideflip: rate = sample.y
                    }
                    let signedRate = rate * self.spinDirection
                    guard signedRate > 0 else { continue }

                    let dt = self.lastGyroTimestamp.map { sample.timestamp - $0 } ?? self.motion.gyroUpdateInterval
                    self.lastGyroTimestamp = sample.timestamp

                    self.totalRadians += signedRate * dt
                    self.currentSpins = self.totalRadians / (2 * .pi)
                    self.maxRPM = max(self.maxRPM, abs(rate) * conv)

                    self.rotationRateZSamples.append(signedRate)
                    self.rotationRateXYSamples.append(abs(sample.x) + abs(sample.y))
                    if let accelActivity = sample.accelActivity {
                        self.accelerometerSamples.append(accelActivity)
                    }
                }

                self.currentFingerProbability = self.computeFingerProbability(
                    zSamples: self.rotationRateZSamples,
                    xySamples: self.rotationRateXYSamples,
                    accelSamples: self.accelerometerSamples
                )
                self.currentChaosScore = self.computeChaosScore(
                    zSamples: self.rotationRateZSamples,
                    xySamples: self.rotationRateXYSamples,
                    accelSamples: self.accelerometerSamples
                )

                // Le rejeu ci-dessus a déjà traité l'échantillon courant
                // (dernier élément du buffer) : on s'arrête là pour ne pas le
                // compter une deuxième fois via le traitement normal
                // plus bas.
                return
            } else if rpm <= threshold {
                // Session en cours mais retombée sous le seuil : on laisse le
                // stillTimer existant suivre son cours, ou on en démarre un.
                if self.stillTimer == nil {
                    self.stillTimer = Timer.scheduledTimer(
                        withTimeInterval: self.stillDelay,
                        repeats: false
                    ) { [weak self] _ in
                        self?.endSession(reason: "stillTimer")
                    }
                }
                return
            } else {
                self.stillTimer?.invalidate()
                self.stillTimer = nil
            }

            // À partir d'ici self.isSpinning == true : soit on vient de
            // démarrer (anti-rebond passé), soit la session continue.
            do {
                // Vérifie le sens de rotation sur le bon axe
                let signedRate: Double
                switch self.detectedMode {
                case .spin:
                    signedRate = data.rotationRate.z * self.spinDirection
                case .backflip:
                    signedRate = data.rotationRate.x * self.spinDirection
                case .sideflip:
                    signedRate = data.rotationRate.y * self.spinDirection
                }

                if signedRate < -0.5 {
                    self.endSession(reason: "reverse")
                    self.isBlockedAfterReverse = true
                    self.reverseBlockTimer?.invalidate()
                    self.reverseBlockTimer = Timer.scheduledTimer(
                        withTimeInterval: self.stillDelay,
                        repeats: false
                    ) { [weak self] _ in
                        self?.isBlockedAfterReverse = false
                        self?.reverseBlockTimer = nil
                    }
                    return
                }

                guard signedRate > 0 else { return }

                // Delta-t réel écoulé depuis le dernier échantillon intégré,
                // basé sur l'horloge CoreMotion (data.timestamp) plutôt que sur
                // gyroUpdateInterval : le callback tourne sur le main thread, qui
                // est aussi sollicité par les rafraîchissements SwiftUI, donc la
                // cadence réelle peut s'écarter de la cadence demandée (0.02s) et
                // cette erreur s'accumulerait sur toute la session si on l'ignorait.
                // Au premier échantillon de la session (pas de référence encore),
                // on retombe sur l'intervalle nominal pour ne pas perdre cet
                // échantillon.
                let dt = self.lastGyroTimestamp.map { data.timestamp - $0 } ?? self.motion.gyroUpdateInterval
                self.lastGyroTimestamp = data.timestamp

                self.totalRadians += signedRate * dt
                self.currentSpins = self.totalRadians / (2 * .pi)
                self.maxRPM = max(self.maxRPM, rpm)

                self.rotationRateZSamples.append(signedRate)

                let xyActivity = abs(data.rotationRate.x) + abs(data.rotationRate.y)
                self.rotationRateXYSamples.append(xyActivity)

                if let accelData = self.motion.accelerometerData {
                    let accelActivity = abs(accelData.acceleration.x) +
                                       abs(accelData.acceleration.y) +
                                       abs(accelData.acceleration.z - 1.0)
                    self.accelerometerSamples.append(accelActivity)
                }

                self.currentFingerProbability = self.computeFingerProbability(
                    zSamples: self.rotationRateZSamples,
                    xySamples: self.rotationRateXYSamples,
                    accelSamples: self.accelerometerSamples
                )

                self.currentChaosScore = self.computeChaosScore(
                    zSamples: self.rotationRateZSamples,
                    xySamples: self.rotationRateXYSamples,
                    accelSamples: self.accelerometerSamples
                )
            }
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

    func endSession(reason: String = "unknown") {
        guard let start = sessionStart, isSpinning else { return }

        // En dessous du seuil minimum, on considère que c'est un mouvement
        // accidentel (attraper/poser le téléphone) plutôt qu'un vrai spin :
        // pas de session sauvegardée, pas de mise à jour des records. L'état
        // est quand même réinitialisé plus bas dans tous les cas.
        if currentSpins >= minValidSpins {
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

            let session = SpinSessionModel(
                totalSpins: currentSpins,
                duration: Date().timeIntervalSince(start),
                maxRPM: maxRPM,
                fingerProbability: probability,
                chaosScore: chaos,
                spinMode: detectedMode.rawValue
            )

            // Seules les rotations "réelles" (vrai spin, pas un mouvement
            // avec support) comptent pour les records.
            if session.isRealSpin, session.totalSpins > (allTimeBests[detectedMode] ?? 0.0) {
                allTimeBests[detectedMode] = session.totalSpins
                UserDefaults.standard.set(session.totalSpins, forKey: "allTimeBest_\(detectedMode.rawValue)")
            }

            lastCompletedSession = session
        }

        isSpinning = false
        currentSpins = 0.0
        currentRPM = 0.0
        currentFingerProbability = 0.0
        currentChaosScore = 0.0
        currentMode = .spin
        totalRadians = 0.0
        maxRPM = 0.0
        sessionStart = nil
        stillTimer = nil
        spinDirection = 0.0
        lastGyroTimestamp = nil
        reverseBlockTimer?.invalidate()
        reverseBlockTimer = nil
        detectedMode = .spin
        rotationRateZSamples = []
        rotationRateXYSamples = []
        accelerometerSamples = []
    }

    func stopTracking() {
        motion.stopGyroUpdates()
        motion.stopAccelerometerUpdates()
        stillTimer?.invalidate()
        reverseBlockTimer?.invalidate()
        reverseBlockTimer = nil
        isBlockedAfterReverse = false
        endSession(reason: "stopTracking")
    }
}
