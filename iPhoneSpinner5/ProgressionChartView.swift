import SwiftUI
import SwiftData
import Charts

// Graphique de progression, présenté en sheet depuis la barre d'outils
// (l'écran principal est déjà dense). Chaque session est un point ;
// la ligne ambre en escalier suit le record courant, calculé sur les
// seules sessions réelles — les sessions "support" restent visibles
// mais grisées, pour expliquer pourquoi elles ne font pas monter la
// ligne.
struct ProgressionChartView: View {
    let sessions: [SpinSessionModel]
    @State private var selectedMode: SpinMode = .spin
    @Environment(\.dismiss) private var dismiss

    // Sessions du mode sélectionné en ordre chronologique (la @Query de
    // ContentView arrive triée par date décroissante).
    private var modeSessions: [SpinSessionModel] {
        sessions
            .filter { $0.spinMode == selectedMode.rawValue }
            .sorted { $0.date < $1.date }
    }

    // Record courant au fil du temps : maximum cumulé des sessions réelles.
    private var recordProgression: [(date: Date, best: Double)] {
        var best = 0.0
        var points: [(date: Date, best: Double)] = []
        for session in modeSessions where session.isRealSpin {
            best = max(best, session.totalSpins)
            points.append((session.date, best))
        }
        return points
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Mode", selection: $selectedMode) {
                    ForEach(SpinMode.allCases, id: \.self) { mode in
                        Text(mode.emoji).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if modeSessions.isEmpty {
                    Spacer()
                    Text("Aucune session pour ce mode")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                } else {
                    Chart {
                        ForEach(recordProgression, id: \.date) { point in
                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("Tours", point.best)
                            )
                            .foregroundStyle(Color("PBAmber"))
                            .interpolationMethod(.stepEnd)
                        }
                        ForEach(modeSessions) { session in
                            PointMark(
                                x: .value("Date", session.date),
                                y: .value("Tours", session.totalSpins)
                            )
                            .foregroundStyle(
                                session.isRealSpin ? Color("AccentColor") : Color.gray.opacity(0.5)
                            )
                        }
                    }
                    .chartYAxisLabel(String(localized: "tours"))

                    // Légende manuelle : la légende automatique de Charts
                    // ne couvre pas des séries stylées à la main.
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color("AccentColor"))
                                .frame(width: 8, height: 8)
                            Text("Sessions réelles")
                        }
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.gray.opacity(0.5))
                                .frame(width: 8, height: 8)
                            Text("Avec support")
                        }
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color("PBAmber"))
                                .frame(width: 14, height: 3)
                            Text("Record")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color("PBBackground").ignoresSafeArea())
            .navigationTitle(Text("Progression"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    // Données factices : une progression plausible sur deux semaines,
    // avec quelques sessions "support" (fingerProbability basse) qui ne
    // doivent pas faire monter la ligne de record.
    let spins: [Double] = [2.1, 3.4, 1.2, 5.6, 4.8, 7.9, 3.2, 12.4, 6.1, 9.7, 5.0, 11.2]
    let samples: [SpinSessionModel] = spins.enumerated().map { index, value in
        let session = SpinSessionModel(
            totalSpins: value,
            duration: 3.5,
            maxRPM: 320,
            fingerProbability: index % 4 == 3 ? 0.3 : 0.9,
            chaosScore: 0.5,
            spinMode: SpinMode.spin.rawValue
        )
        session.date = Calendar.current.date(byAdding: .day, value: index - spins.count, to: .now)!
        return session
    }
    return ProgressionChartView(sessions: samples)
}
