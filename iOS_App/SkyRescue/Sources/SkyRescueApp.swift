import SwiftUI

@main
struct SkyRescueApp: App {
    @StateObject private var meshtastic = MeshtasticBLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(meshtastic)
        }
    }
}
