import CoreMotion
import Combine
import Foundation

enum SpinMode: String {
    case spin = "spin"
    case backflip = "backflip"
    case sideflip = "sideflip"

    var label: String {
        switch self {
        case .spin: return "🌀 Spin"
        case .backflip: return "🔄 Backflip"
        case .sideflip: return "↔️ Sideflip"
        }
    }
}

class MotionManager: ObservableObject {
    private let motion = CMMotionManager()

    @Published var currentSpins: Double = 0.0
    @Published var currentRPM: Double = 0.0
    @Published var isSpinning: Bool = false
    @Published var allTimeBest: Double = UserDefaults.standard.double(forKey: "allTimeBest")
    @Published var lastCompletedSession: SpinSessionModel? = nil
    @Published var stillDelay: Double = 0.5
    @Published var currentFingerProbability: Double = 0.0
    @Published var isBlockedAfterReverse: Bool = false
    @Published var currentChaosScore: Double = 0.0
    @Published var currentMode: SpinMode = .spin  // ← mode détecté en temps réel

    private var totalRadians: Double = 0.0
    private var maxRPM: Double = 0.0
    private var sessionStart: Date?
    private var stillTimer: Timer?
    private let stillThresholdZ: Double = 30   // spin sur doigt — rapide
    private let stillThresholdX: Double = 15   // backflip — moins rapide
    private let stillThresholdY: Double = 15   // sideflip — moins rapide
    private var spinDirection: Double = 0.0
    private var reverseBlockTimer: Timer?
    private var previousZ: Double = 0.0
    // Timestamp CoreMotion (horloge monotone, en secondes) du dernier échantillon
    // intégré. Sert à calculer le vrai delta-t entre deux échantillons plutôt que
    // de supposer que gyroUpdateInterval (0.02s) s'est écoulé — le callback tourne
    // sur le main thread, qui est aussi occupé à rafraîchir la UI SwiftUI, donc la
    // cadence réelle peut dériver de la cadence demandée.
    private var lastGyroTimestamp: TimeInterval?

    private var rotationRateZSamples: [Double] = []
    private var rotationRateXYSamples: [Double] = []
    private var accelerometerSamples: [Double] = []

    // Détection du mode
    private var detectionSamples: [(x: Double, y: Double, z: Double)] = []
    private let detectionSampleCount = 20  // nombre d'échantillons pour détecter l'axe
    private var detectedMode: SpinMode = .spin
    private var modeDetected: Bool = false

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

            // Détection du mode — attend un mouvement significatif avant de décider
            if self.isSpinning && !self.modeDetected {
                let maxAxis = max(abs(data.rotationRate.x), max(abs(data.rotationRate.y), abs(data.rotationRate.z)))

                // N'échantillonne que si le mouvement est déjà significatif
                if maxAxis > 2.0 {
                    self.detectionSamples.append((
                        x: abs(data.rotationRate.x),
                        y: abs(data.rotationRate.y),
                        z: abs(data.rotationRate.z)
                    ))

                    if self.detectionSamples.count >= self.detectionSampleCount {
                        let avgX = self.detectionSamples.map(\.x).reduce(0, +) / Double(self.detectionSamples.count)
                        let avgY = self.detectionSamples.map(\.y).reduce(0, +) / Double(self.detectionSamples.count)
                        let avgZ = self.detectionSamples.map(\.z).reduce(0, +) / Double(self.detectionSamples.count)

                        if avgZ >= avgX && avgZ >= avgY {
                            self.detectedMode = .spin
                        } else if avgX >= avgY {
                            self.detectedMode = .backflip
                        } else {
                            self.detectedMode = .sideflip
                        }

                        self.modeDetected = true
                        self.currentMode = self.detectedMode

                        // Le mode réel peut différer de l'hypothèse de départ (spin/Z) :
                        // on reverrouille le sens de rotation sur le bon axe et on
                        // repart sur une intégration propre pour ne pas mélanger des
                        // données accumulées sur le mauvais axe.
                        switch self.detectedMode {
                        case .spin:
                            self.spinDirection = data.rotationRate.z > 0 ? 1.0 : -1.0
                        case .backflip:
                            self.spinDirection = data.rotationRate.x > 0 ? 1.0 : -1.0
                        case .sideflip:
                            self.spinDirection = data.rotationRate.y > 0 ? 1.0 : -1.0
                        }
                        self.totalRadians = 0.0
                        self.currentSpins = 0.0
                        self.maxRPM = 0.0
                        self.rotationRateZSamples = []
                        self.rotationRateXYSamples = []
                        self.accelerometerSamples = []
                    }
                }
            }

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

            if (self.isSpinning && rpm > threshold) || (!self.isSpinning && startThresholdMet) {
                self.stillTimer?.invalidate()
                self.stillTimer = nil

                if !self.isSpinning {
                    self.isSpinning = true
                    self.totalRadians = 0.0
                    self.maxRPM = 0.0
                    self.sessionStart = Date()
                    self.rotationRateZSamples = []
                    self.rotationRateXYSamples = []
                    self.accelerometerSamples = []
                    self.previousZ = 0.0
                    self.detectionSamples = []
                    self.modeDetected = false
                    self.detectedMode = .spin
                    self.currentMode = .spin
                    // Pas de référence de temps précédente pour cette nouvelle
                    // session : le premier échantillon intégré retombera sur
                    // l'intervalle nominal (voir plus bas).
                    self.lastGyroTimestamp = nil

                    // Sens de rotation initial : on prend l'axe qui bouge le
                    // plus à cet instant plutôt que de toujours supposer Z
                    // (spin), sinon un backflip/sideflip démarre toujours
                    // avec un sens de référence arbitraire.
                    let absX = abs(data.rotationRate.x)
                    let absY = abs(data.rotationRate.y)
                    let absZ = abs(data.rotationRate.z)
                    if absZ >= absX && absZ >= absY {
                        self.spinDirection = data.rotationRate.z > 0 ? 1.0 : -1.0
                    } else if absX >= absY {
                        self.spinDirection = data.rotationRate.x > 0 ? 1.0 : -1.0
                    } else {
                        self.spinDirection = data.rotationRate.y > 0 ? 1.0 : -1.0
                    }
                }

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
                    self.endSession()
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

                self.previousZ = signedRate

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

            } else if self.isSpinning && self.stillTimer == nil {
                self.stillTimer = Timer.scheduledTimer(
                    withTimeInterval: self.stillDelay,
                    repeats: false
                ) { [weak self] _ in
                    self?.endSession()
                }
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

    func endSession() {
        guard let start = sessionStart, isSpinning else { return }

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

        if session.totalSpins > allTimeBest {
            allTimeBest = session.totalSpins
            UserDefaults.standard.set(allTimeBest, forKey: "allTimeBest")
        }

        lastCompletedSession = session

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
        previousZ = 0.0
        lastGyroTimestamp = nil
        reverseBlockTimer?.invalidate()
        reverseBlockTimer = nil
        detectionSamples = []
        modeDetected = false
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
        endSession()
    }
}
