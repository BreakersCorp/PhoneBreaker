import SwiftUI
import SwiftData

@main
struct SpinTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Identité "Signal" : instrument de mesure, pas une app qui
                // s'adapte au thème système — le fond quasi noir et le vert
                // phosphore sont pensés ensemble, donc on fixe le mode sombre.
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: SpinSessionModel.self)
    }
}
