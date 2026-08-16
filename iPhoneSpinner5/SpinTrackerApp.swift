import SwiftUI
import SwiftData

@main
struct SpinTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: SpinSessionModel.self)
    }
}
