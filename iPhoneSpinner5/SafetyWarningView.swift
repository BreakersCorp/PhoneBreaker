import SwiftUI

// Avertissement de sécurité affiché au premier lancement : l'app incite à
// faire tournoyer, voire lancer, le téléphone — on informe l'utilisateur
// des précautions et du transfert de risque AVANT le premier usage, et
// ContentView mémorise son accord (AppStorage) pour ne plus le réafficher.
struct SafetyWarningView: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color("PBAmber"))
                .padding(.bottom, 20)

            Text("Avant de spinner")
                .font(.title.bold())
                .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 22) {
                safetyRow("figure.walk", "Dégage l'espace autour de toi avant chaque session.")
                safetyRow("bed.double.fill", "Privilégie une surface molle : canapé, lit, tapis.")
                safetyRow("person.2.fill", "Ne lance jamais ton téléphone près d'autres personnes.")
                safetyRow("hand.raised.fill", "Tu utilises PhoneBreaker à tes propres risques. L'éditeur décline toute responsabilité en cas de dommage matériel ou corporel.")
            }
            .padding(.horizontal, 32)

            Spacer()

            Button(action: onAccept) {
                Text("J'ai compris")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("AccentColor"))
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .background(Color("PBBackground").ignoresSafeArea())
    }

    private func safetyRow(_ systemImage: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color("PBAmber"))
                .frame(width: 32)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    SafetyWarningView(onAccept: {})
}
