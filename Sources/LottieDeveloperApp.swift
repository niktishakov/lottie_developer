import SwiftUI

@main
struct LottieDeveloperApp: App {
    @State private var store = AnimationStore()
    @State private var purchaseStore = PurchaseStore()
    @State private var revisionStore = RevisionStore()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    DeveloperRootView()
                        .environment(store)
                        .environment(purchaseStore)
                        .environment(revisionStore)
                        .task {
                            await store.loadMetadataIfNeeded()
                            await store.loadDemoAnimationIfNeeded()
                            await revisionStore.loadIfNeeded(animationStore: store)
                            await purchaseStore.loadProducts()
                        }
                } else {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                        .environment(store)
                        .environment(purchaseStore)
                        .environment(revisionStore)
                        .task {
                            await store.loadMetadataIfNeeded()
                            await store.loadDemoAnimationIfNeeded()
                            await revisionStore.loadIfNeeded(animationStore: store)
                            await purchaseStore.loadProducts()
                        }
                }
            }
            .preferredColorScheme(.dark)
        }
        #if targetEnvironment(macCatalyst)
        .defaultSize(width: 900, height: 700)
        #endif
    }
}
