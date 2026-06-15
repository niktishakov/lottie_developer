import Foundation

@MainActor
final class AIProviderRegistry {
    static let shared = AIProviderRegistry()

    private(set) var activeProvider: AIProviderAdapter = NullAIProviderAdapter()

    func register(provider: AIProviderAdapter) {
        activeProvider = provider
    }
}
