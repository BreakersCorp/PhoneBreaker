import SwiftData
import Foundation

@Model
class SpinSessionModel {
    var totalSpins: Double
    var duration: TimeInterval
    var maxRPM: Double
    var date: Date
    var fingerProbability: Double
    var chaosScore: Double
    var spinMode: String  // ← nouveau : "spin", "backflip", "sideflip"

    init(totalSpins: Double, duration: TimeInterval, maxRPM: Double, fingerProbability: Double, chaosScore: Double, spinMode: String) {
        self.totalSpins = totalSpins
        self.duration = duration
        self.maxRPM = maxRPM
        self.date = Date()
        self.fingerProbability = fingerProbability
        self.chaosScore = chaosScore
        self.spinMode = spinMode
    }
}

extension SpinSessionModel {
    /// Seuil de fingerProbability à partir duquel une rotation est
    /// considérée comme "réelle" (✅ Vrai spin) et non un mouvement
    /// effectué avec un support.
    static let realSpinThreshold = 0.7

    var isRealSpin: Bool {
        fingerProbability >= Self.realSpinThreshold
    }
}
