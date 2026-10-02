#if os(macOS)
import SwiftUI

@main
struct LottieDeveloperMacApp: App {
    init() {
        WorkspaceSetup.stripQuarantine()
        WorkspaceSetup.refreshIfInstalled()
    }

    var body: some Scene {
        WindowGroup("Lottie Developer") {
            ContentView()
        }
        .defaultSize(width: 560, height: 640)
    }
}
#endif
