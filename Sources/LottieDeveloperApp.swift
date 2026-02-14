import SwiftUI

@main
struct LottieDeveloperApp: App {
    @State private var store = AnimationStore()

    var body: some Scene {
        WindowGroup {
            AnimationLibraryView()
                .environment(store)
        }
        #if targetEnvironment(macCatalyst)
        .defaultSize(width: 900, height: 700)
        #endif
    }
}
