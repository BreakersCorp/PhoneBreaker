import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var motion = MotionManager()
    @Query(sort: \SpinSessionModel.date, order: .reverse) var sessions: [SpinSessionModel]
    @Environment(\.modelContext) private var modelContext
    @State private var showResetConfirmation = false

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter
    }()

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
                    modeScoresRow { mode in
                        // Max entre le record persisté (UserDefaults) et le
                        // meilleur des sessions réelles stockées : les sessions
                        // antérieures à la séparation des records par mode
                        // n'ont jamais écrit leur record par mode.
                        let stored = motion.allTimeBests[mode] ?? 0.0
                        let fromSessions = bestRealSessionSpins(for: mode) ?? 0.0
                        let best = max(stored, fromSessions)
                        return best > 0 ? best : nil
                    }
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

                // --- Liste ---
                if sessions.isEmpty {
                    Spacer()
                    Text("Lance une session pour commencer !")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                } else {
                    let maxSpins = sessions.map(\.totalSpins).max() ?? 1.0

                    List(sessions) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(session.totalSpins, specifier: "%.2f") tours")
                                    .font(.headline.monospacedDigit())
                                Spacer()
                                Text(SpinMode(rawValue: session.spinMode)?.label ?? "🌀 Spin")
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
                                Text("\(session.date, formatter: dateFormatter)")
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
                    .environment(\.defaultMinListRowHeight, 0)
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color("PBBackground").ignoresSafeArea())
            .tint(Color("AccentColor"))
            .toolbar {
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
            }
            .onChange(of: motion.lastCompletedSession) { _, session in
                if let session = session {
                    modelContext.insert(session)
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

    private func resetScores() {
        for session in sessions {
            modelContext.delete(session)
        }
        for mode in SpinMode.allCases {
            motion.allTimeBests[mode] = 0.0
            UserDefaults.standard.set(0.0, forKey: "allTimeBest_\(mode.rawValue)")
        }
        // Ancienne clé du record global (avant la séparation par mode).
        UserDefaults.standard.removeObject(forKey: "allTimeBest")
    }

    private func durationString(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        let ms = Int((duration - Double(seconds)) * 100)
        return String(format: "%ds %02dms", seconds, ms)
    }

    private func fingerLabel(_ probability: Double) -> String {
        switch probability {
        case 0.7...: return "✅ Vrai spin"
        case 0.4..<0.7: return "⚠️ Incertain"
        default: return "❌ Support"
        }
    }

    private func fingerColor(_ probability: Double) -> Color {
        switch probability {
        case 0.7...: return .green
        case 0.4..<0.7: return .orange
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
