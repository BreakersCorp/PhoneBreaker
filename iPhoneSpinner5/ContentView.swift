import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var motion = MotionManager()
    @Query(sort: \SpinSessionModel.date, order: .reverse) var sessions: [SpinSessionModel]
    @Environment(\.modelContext) private var modelContext
    @State private var showResetConfirmation = false

    var bestSession: SpinSessionModel? {
        sessions.max(by: { $0.totalSpins < $1.totalSpins })
    }

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
                            motion.isSpinning ? .blue.opacity(0.15) :
                            motion.isBlockedAfterReverse ? .gray.opacity(0.08) :
                            .green.opacity(0.12)
                        )
                        .frame(width: 260, height: 260)
                        .animation(.easeInOut(duration: 0.3), value: motion.isSpinning)

                    VStack(spacing: 6) {
                        Text("\(motion.currentSpins, specifier: "%.2f")")
                            .font(.system(size: 72, weight: .bold, design: .rounded))
                            .foregroundStyle(motion.isSpinning ? .blue : .primary)
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
                                .font(.caption)
                                .foregroundStyle(.blue.opacity(0.8))
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

                // --- Scores ---
                if let best = bestSession {
                    HStack {
                        Label("Meilleur (session)", systemImage: "trophy.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                        Spacer()
                        Text("\(best.totalSpins, specifier: "%.2f") tours")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }

                HStack {
                    Label("Record absolu", systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.subheadline)
                    Spacer()
                    Text("\(motion.allTimeBest, specifier: "%.2f") tours")
                        .font(.subheadline)
                        .fontWeight(.semibold)
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
                                    .font(.headline)
                                Spacer()
                                Text(SpinMode(rawValue: session.spinMode)?.label ?? "🌀 Spin")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(Int(session.maxRPM)) RPM max")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }

                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.blue.opacity(0.7))
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
                        .listRowBackground(fingerColor(session.fingerProbability).opacity(0.25))
                    }
                    .environment(\.defaultMinListRowHeight, 0)
                    .listStyle(.plain)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        VStack {
                            Label("Délai : \(motion.stillDelay, specifier: "%.1f")s", systemImage: "timer")
                                .font(.caption)
                            Slider(value: $motion.stillDelay, in: 0.2...2.0, step: 0.1)
                        }
                        .padding(.horizontal)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
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
            }
            .onChange(of: motion.lastCompletedSession) { _, session in
                if let session = session {
                    modelContext.insert(session)
                }
            }
        }
    }

    private func resetScores() {
        for session in sessions {
            modelContext.delete(session)
        }
        motion.allTimeBest = 0.0
        UserDefaults.standard.set(0.0, forKey: "allTimeBest")
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
