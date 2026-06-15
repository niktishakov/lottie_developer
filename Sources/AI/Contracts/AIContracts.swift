import Foundation

struct AIRequest: Codable {
    let taskType: String
    let inputRef: String
    let constraints: [String: String]
    let budgetHint: Double?
}

struct AIResult: Codable {
    let summary: String
    let findings: [String]
    let patchedJSONRef: String?
    let confidence: Double
    let warnings: [String]
    let cost: Double?
}

struct AICapabilities: Codable {
    let supportsGenerate: Bool
    let supportsPatch: Bool
    let maxInputSize: Int
    let structuredOutput: Bool
}

protocol AIProviderAdapter {
    var capabilities: AICapabilities { get }
    func execute(_ request: AIRequest) async throws -> AIResult
}
