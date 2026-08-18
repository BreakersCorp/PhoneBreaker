import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var motion = MotionManager()
    @StateObject private var gameCenter = GameCenterManager()
    @Query(sort: \SpinSessionModel.date, order: .reverse) var sessions: [SpinSessionModel]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // --- Zone principale ---
                ZStack {
                    Circle()
                        .fill(
                            motion.isSpinning ? Color("AccentColor").opacity(0.16) :
                            motion.isBlockedAfterReverse ? .gray.opacity(0.10) :
                            Color("PBSurface")
                        )
                        .frame(width: 260, height: 260)
                        .animation(.easeInOut(duration: 0.3), value: motion.isSpinning)

                    VStack(spacing: 6) {
                        Text("\(motion.currentSpins, specifier: "%.2f")")
                            .font(.system(size: 72, weight: .bold, design: .monospaced))
                            .foregroundStyle(motion.isSpinning ? Color("AccentColor") : .primary)
                            .contentTransition(.numericText())
                            .animation(.default, value: motion.currentSpins)

                        Text("tours")
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        if motion.isSpinning {
                            Text(motion.currentMode.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .transition(.opacity)

                            Text("\(Int(motion.currentRPM)) RPM")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color("AccentColor").opacity(0.85))
                                .transition(.opacity)

                            Text(fingerLabel(motion.currentFingerProbability))
                                .font(.caption2)
                                .foregroundStyle(fingerColor(motion.currentFingerProbability))
                                .transition(.opacity)

                            HStack(spacing: 4) {
                                Text("Chaos")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.2f", motion.currentChaosScore))
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(chaosColor(motion.currentChaosScore))
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(.gray.opacity(0.2))
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(chaosColor(motion.currentChaosScore))
                                            .frame(width: geo.size.width * min(motion.currentChaosScore, 2.0) / 2.0)
                                    }
                                }
                                .frame(width: 60, height: 4)
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .padding(.top, 40)
                .padding(.bottom, 24)

                // --- Scores (séparés par type de rotation) ---
                VStack(alignment: .leading, spacing: 4) {
                    Label("Record absolu", systemImage: "star.fill")
                        .foregroundStyle(Color("PBAmber"))
                        .font(.subheadline)
                    modeScoresRow { bestScore(for: $0) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Moyenne", systemImage: "chart.bar.fill")
                        .foregroundStyle(Color("PBAmber"))
                        .font(.subheadline)
                    modeScoresRow { averageRealSpins(for: $0) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                // --- Records des amis (Game Center) ---
                if gameCenter.isAuthenticated {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Records des amis", systemImage: "person.2.fill")
                                .foregroundStyle(Color("PBAmber"))
                                .font(.subheadline)
                            Spacer()
                            Button {
                                Task { await gameCenter.refreshFriendRecords() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .disabled(gameCenter.isLoadingFriends)
                        }
                        if gameCenter.friendRecords.isEmpty {
                            Text("Aucun record d'ami pour l'instant")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            // Les 3 meilleurs amis suffisent ici : l'espace
                            // vertical est compté, la liste des sessions
                            // reste la zone principale.
                            ForEach(gameCenter.friendRecords.prefix(3)) { friend in
                                HStack {
                                    Text(friend.displayName)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    ForEach(SpinMode.allCases, id: \.self) { mode in
                                        HStack(spacing: 3) {
                                            Text(mode.emoji)
                                                .font(.caption2)
                                            Text(spinsString(friend.bests[mode]))
                                                .font(.caption.monospacedDigit())
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                // --- Liste ---
                if sessions.isEmpty {
                    Spacer()
                    Text("Lance une session pour commencer !")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                } else {
                    let maxSpins = sessions.map(\.totalSpins).max() ?? 1.0

                    List {
                        ForEach(sessions) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(session.totalSpins, specifier: "%.2f") tours")
                                        .font(.headline.monospacedDigit())
                                    Spacer()
                                    Text((SpinMode(rawValue: session.spinMode) ?? .spin).label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("\(Int(session.maxRPM)) RPM max")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Color("PBAmber"))
                                }

                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color("PBAmber").opacity(0.7))
                                        .frame(width: geo.size.width * (session.totalSpins / maxSpins), height: 6)
                                }
                                .frame(height: 6)

                                HStack(spacing: 4) {
                                    Text("Chaos")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "%.2f", session.chaosScore))
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(chaosColor(session.chaosScore))
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(.gray.opacity(0.2))
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(chaosColor(session.chaosScore))
                                                .frame(width: geo.size.width * min(session.chaosScore, 2.0) / 2.0)
                                        }
                                    }
                                    .frame(height: 4)
                                }

                                HStack {
                                    Text(durationString(session.duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    // Format sensible à la locale : ordre jour/mois
                                    // et horloge 12/24h adaptés à la langue.
                                    Text(session.date, format: .dateTime.day(.twoDigits).month(.twoDigits).hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(
                                Color("PBSurface").overlay(fingerColor(session.fingerProbability).opacity(0.25))
                            )
                        }
                        .onDelete(perform: deleteSessions)
                    }
                    .environment(\.defaultMinListRowHeight, 0)
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color("PBBackground").ignoresSafeArea())
            .tint(Color("AccentColor"))
            // Haptique de célébration quand un record absolu vient d'être
            // battu (recordsBeaten est incrémenté par le MotionManager en
            // fin de session).
            .sensoryFeedback(.success, trigger: motion.recordsBeaten)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: recordsShareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!hasAnyRecord)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }
            .confirmationDialog(
                "Réinitialiser les scores ?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Réinitialiser", role: .destructive) {
                    resetScores()
                }
                Button("Annuler", role: .cancel) {}
            }
            .onAppear {
                motion.startTracking()
                gameCenter.authenticate()
            }
            // En arrière-plan, le gyroscope et l'accéléromètre continueraient
            // de tourner et de vider la batterie : on coupe le suivi (ce qui
            // termine proprement une éventuelle session en cours) et on le
            // relance au retour au premier plan. .inactive est ignoré : c'est
            // un état transitoire (centre de notifications, appel entrant) qui
            // ne doit pas interrompre un spin.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    motion.startTracking()
                case .background:
                    motion.stopTracking()
                default:
                    break
                }
            }
            .onChange(of: motion.lastCompletedSession) { _, session in
                if let session = session {
                    modelContext.insert(session)
                    // Game Center ne garde que le meilleur score : on peut
                    // soumettre chaque session réelle sans comparer au record.
                    if session.isRealSpin {
                        gameCenter.submit(
                            spins: session.totalSpins,
                            mode: SpinMode(rawValue: session.spinMode) ?? .spin
                        )
                    }
                }
            }
            .onChange(of: gameCenter.isAuthenticated) { _, authenticated in
                // À la connexion, pousse les records locaux existants pour que
                // les leaderboards reflètent l'historique d'avant l'intégration
                // Game Center.
                guard authenticated else { return }
                for mode in SpinMode.allCases {
                    if let best = bestScore(for: mode) {
                        gameCenter.submit(spins: best, mode: mode)
                    }
                }
            }
        }
    }

    // Une ligne de scores par mode : "🌀 12.34   🔄 4.56   ↔️ –",
    // le tiret signalant qu'aucun score n'existe encore pour ce mode.
    private func modeScoresRow(value: @escaping (SpinMode) -> Double?) -> some View {
        HStack {
            ForEach(SpinMode.allCases, id: \.self) { mode in
                HStack(spacing: 4) {
                    Text(mode.emoji)
                        .font(.caption)
                    Text(spinsString(value(mode)))
                        .font(.subheadline.monospacedDigit())
                        .fontWeight(.semibold)
                }
                if mode != SpinMode.allCases.last {
                    Spacer()
                }
            }
        }
    }

    // Record affiché pour un mode : max entre le record persisté (UserDefaults)
    // et le meilleur des sessions réelles stockées, car les sessions
    // antérieures à la séparation des records par mode n'ont jamais écrit
    // leur record par mode. nil si aucun record n'existe.
    private func bestScore(for mode: SpinMode) -> Double? {
        let stored = motion.allTimeBests[mode] ?? 0.0
        let fromSessions = bestRealSessionSpins(for: mode) ?? 0.0
        let best = max(stored, fromSessions)
        return best > 0 ? best : nil
    }

    private var hasAnyRecord: Bool {
        SpinMode.allCases.contains { bestScore(for: $0) != nil }
    }

    // Texte des records partagé via la feuille de partage native,
    // limité aux modes qui ont déjà un record. Format avec emojis
    // (préféré par les testeurs) ; le locale: rend les nombres dans le
    // format de la langue (virgule en français).
    private var recordsShareText: String {
        var lines = [String(localized: "🏆 Mes records de spin :")]
        for mode in SpinMode.allCases {
            guard let best = bestScore(for: mode) else { continue }
            let value = String(format: String(localized: "%.2f tours"), locale: .current, best)
            lines.append(String(format: String(localized: "%1$@ : %2$@"), mode.label, value))
        }
        return lines.joined(separator: "\n")
    }

    // Meilleur score des sessions "réelles" (vrai spin) stockées pour un mode
    // donné, nil s'il n'y en a aucune.
    private func bestRealSessionSpins(for mode: SpinMode) -> Double? {
        sessions.lazy
            .filter { $0.spinMode == mode.rawValue && $0.isRealSpin }
            .map(\.totalSpins)
            .max()
    }

    // Moyenne des tours des sessions "réelles" (vrai spin) pour un mode donné,
    // nil s'il n'y en a aucune.
    private func averageRealSpins(for mode: SpinMode) -> Double? {
        let realSpins = sessions
            .filter { $0.spinMode == mode.rawValue && $0.isRealSpin }
            .map(\.totalSpins)
        guard !realSpins.isEmpty else { return nil }
        return realSpins.reduce(0, +) / Double(realSpins.count)
    }

    private func spinsString(_ spins: Double?) -> String {
        guard let spins else { return "–" }
        return String(format: "%.2f", spins)
    }

    // Suppression par swipe d'une session : ne touche pas aux records
    // persistés (allTimeBests), qui survivent volontairement à la
    // suppression de la session qui les a établis.
    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
    }

    private func resetScores() {
        for session in sessions {
            modelContext.delete(session)
        }
        // Les records (et leur persistance UserDefaults) appartiennent au
        // MotionManager : les écraser directement ici désynchroniserait sa
        // copie interne, côté file de traitement.
        motion.resetBests()
    }

    private func durationString(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        let ms = Int((duration - Double(seconds)) * 1000)
        return String(format: "%ds %03dms", seconds, ms)
    }

    private func fingerLabel(_ probability: Double) -> String {
        switch probability {
        case SpinSessionModel.realSpinThreshold...: return String(localized: "✅ Vrai spin")
        case 0.4..<SpinSessionModel.realSpinThreshold: return String(localized: "⚠️ Incertain")
        default: return String(localized: "❌ Support")
        }
    }

    private func fingerColor(_ probability: Double) -> Color {
        switch probability {
        case SpinSessionModel.realSpinThreshold...: return .green
        case 0.4..<SpinSessionModel.realSpinThreshold: return .orange
        default: return .red
        }
    }

    private func chaosColor(_ score: Double) -> Color {
        switch score {
        case 0.0..<0.3: return .blue
        case 0.3..<0.7: return .green
        case 0.7..<1.3: return .orange
        default: return .red
        }
    }
}
