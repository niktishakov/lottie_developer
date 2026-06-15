import Foundation

enum AIProviderError: Error {
    case notConfigured
}

struct NullAIProviderAdapter: AIProviderAdapter {
    let capabilities = AICapabilities(
        supportsGenerate: false,
        supportsPatch: false,
        maxInputSize: 0,
        structuredOutput: false
    )

    func execute(_ request: AIRequest) async throws -> AIResult {
        throw AIProviderError.notConfigured
    }
}
