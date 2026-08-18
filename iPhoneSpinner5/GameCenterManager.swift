import Combine
import GameKit
import SwiftUI

extension SpinMode {
    // Identifiant du leaderboard Game Center pour ce mode. Doit correspondre
    // exactement aux IDs configurés dans App Store Connect.
    var leaderboardID: String { "bestScore.\(rawValue)" }
}

// Records d'un ami agrégés sur les trois leaderboards, pour l'affichage
// dans la section "Records des amis".
struct FriendRecord: Identifiable, Equatable {
    let playerID: String
    let displayName: String
    var bests: [SpinMode: Double]

    var id: String { playerID }
}

@MainActor
final class GameCenterManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var friendRecords: [FriendRecord] = []
    @Published var isLoadingFriends = false

    // Les scores Game Center sont des entiers ; les leaderboards sont
    // configurés en "2 décimales" dans App Store Connect, donc
    // 12.34 tours est soumis comme 1234.
    private static let scoreScale = 100.0

    // Initialise le joueur local. GameKit rappelle le handler à chaque
    // changement d'état d'authentification (y compris après un retour
    // au premier plan), on rafraîchit donc les amis à chaque passage.
    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let viewController {
                    Self.presentAuthenticationSheet(viewController)
                    return
                }
                if let error {
                    print("Game Center auth: \(error.localizedDescription)")
                }
                self.isAuthenticated = GKLocalPlayer.local.isAuthenticated
                if self.isAuthenticated {
                    await self.refreshFriendRecords()
                }
            }
        }
    }

    // Soumet un score (en tours) au leaderboard du mode. Game Center ne
    // retient que le meilleur score par joueur : on peut soumettre chaque
    // session réelle sans comparer au record local.
    func submit(spins: Double, mode: SpinMode) {
        guard isAuthenticated else { return }
        Task {
            do {
                try await GKLeaderboard.submitScore(
                    Int((spins * Self.scoreScale).rounded()),
                    context: 0,
                    player: GKLocalPlayer.local,
                    leaderboardIDs: [mode.leaderboardID]
                )
            } catch {
                print("Game Center submit: \(error.localizedDescription)")
            }
        }
    }

    // Identifiants des succès. Doivent correspondre exactement aux IDs
    // configurés dans App Store Connect (même convention pointée que les
    // leaderboards).
    private enum AchievementID {
        static let firstRealSpin = "achievement.firstRealSpin"
        static let tenSpinsSession = "achievement.tenSpinsSession"
        static let rpm500 = "achievement.rpm500"
        static let allModes = "achievement.allModes"
        static let sessions100 = "achievement.sessions100"
    }

    // Rapporte la progression des succès après une session réelle. Game
    // Center ignore un percentComplete inférieur à celui déjà enregistré :
    // on peut donc soumettre la progression courante à chaque session sans
    // relire l'état distant, et re-rapporter un succès déjà complété est
    // sans effet (pas de seconde bannière).
    func reportAchievements(session: SpinSessionModel, realSessionCount: Int, realModesPlayed: Int) {
        guard isAuthenticated else { return }

        func achievement(_ identifier: String, percent: Double) -> GKAchievement {
            let achievement = GKAchievement(identifier: identifier)
            achievement.percentComplete = min(max(percent, 0), 100)
            achievement.showsCompletionBanner = true
            return achievement
        }

        let achievements = [
            achievement(AchievementID.firstRealSpin, percent: 100),
            achievement(AchievementID.tenSpinsSession, percent: session.totalSpins / 10.0 * 100),
            achievement(AchievementID.rpm500, percent: session.maxRPM / 500.0 * 100),
            achievement(AchievementID.allModes, percent: Double(realModesPlayed) / Double(SpinMode.allCases.count) * 100),
            // 100 sessions réelles visées : 1 session = 1 %.
            achievement(AchievementID.sessions100, percent: Double(realSessionCount))
        ]

        Task {
            do {
                try await GKAchievement.report(achievements)
            } catch {
                print("Game Center achievements: \(error.localizedDescription)")
            }
        }
    }

    func refreshFriendRecords() async {
        guard isAuthenticated, !isLoadingFriends else { return }
        isLoadingFriends = true
        defer { isLoadingFriends = false }

        do {
            let leaderboards = try await GKLeaderboard.loadLeaderboards(
                IDs: SpinMode.allCases.map(\.leaderboardID)
            )
            var records: [String: FriendRecord] = [:]
            for leaderboard in leaderboards {
                guard let mode = SpinMode.allCases.first(where: {
                    $0.leaderboardID == leaderboard.baseLeaderboardID
                }) else { continue }

                let (_, entries, _) = try await leaderboard.loadEntries(
                    for: .friendsOnly,
                    timeScope: .allTime,
                    range: NSRange(location: 1, length: 25)
                )
                for entry in entries {
                    // Le scope friendsOnly inclut aussi le joueur local ;
                    // on ne veut afficher que les amis.
                    guard entry.player.gamePlayerID != GKLocalPlayer.local.gamePlayerID else { continue }
                    let id = entry.player.gamePlayerID
                    var record = records[id] ?? FriendRecord(
                        playerID: id,
                        displayName: entry.player.displayName,
                        bests: [:]
                    )
                    record.bests[mode] = Double(entry.score) / Self.scoreScale
                    records[id] = record
                }
            }
            // Meilleurs spinners en premier, tous modes confondus.
            friendRecords = records.values.sorted {
                ($0.bests.values.max() ?? 0) > ($1.bests.values.max() ?? 0)
            }
        } catch {
            print("Game Center friends: \(error.localizedDescription)")
        }
    }

    // GameKit fournit un view controller de connexion quand le joueur n'est
    // pas encore authentifié ; à nous de le présenter.
    private static func presentAuthenticationSheet(_ viewController: UIViewController) {
        // Au lancement à froid, la scène peut encore être foregroundInactive
        // quand GameKit rappelle le handler : sans repli sur une scène
        // connectée quelconque, la feuille de connexion serait perdue.
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        scene?.keyWindow?.rootViewController?.present(viewController, animated: true)
    }
}
