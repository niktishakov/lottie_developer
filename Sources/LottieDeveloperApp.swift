import SwiftUI

@main
struct LottieDeveloperApp: App {
    @State private var store = AnimationStore()
    @State private var purchaseStore = PurchaseStore()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                AnimationLibraryView()
                    .environment(store)
                    .environment(purchaseStore)
                    .task {
                        await store.loadMetadataIfNeeded()
                        await store.loadDemoAnimationIfNeeded()
                        await purchaseStore.loadProducts()
                    }
            } else {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                    .environment(store)
                    .environment(purchaseStore)
                    .task {
                        await store.loadMetadataIfNeeded()
                        await store.loadDemoAnimationIfNeeded()
                        await purchaseStore.loadProducts()
                    }
            }
        }
        #if targetEnvironment(macCatalyst)
        .defaultSize(width: 900, height: 700)
        #endif
    }
}
