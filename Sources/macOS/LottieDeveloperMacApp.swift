#if os(macOS)
import SwiftUI

@main
struct LottieDeveloperMacApp: App {
    var body: some Scene {
        WindowGroup("Lottie Developer") {
            ContentView()
        }
        .defaultSize(width: 560, height: 640)
    }
}
#endif
