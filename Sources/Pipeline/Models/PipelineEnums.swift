import Foundation

enum SourceType: String, Codable, CaseIterable {
    case lottieJSON
    case svg
    case promptSpec

    var title: String {
        switch self {
        case .lottieJSON: return "Lottie JSON"
        case .svg: return "SVG"
        case .promptSpec: return "Prompt/Spec"
        }
    }

    var isAvailableInM1: Bool {
        self != .promptSpec
    }
}

enum PipelineStage: Int, Codable, CaseIterable, Identifiable {
    case sourceIntake = 1
    case canonicalization
    case draftGeneration
    case syntaxGate
    case motionSemanticGate
    case runtimeGate
    case issueResolutionLoop
    case releaseCandidate
    case publishHandoff

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sourceIntake: return "Source Intake"
        case .canonicalization: return "Canonicalization"
        case .draftGeneration: return "Draft Generation"
        case .syntaxGate: return "Syntax Gate"
        case .motionSemanticGate: return "Motion Semantic Gate"
        case .runtimeGate: return "Runtime Gate"
        case .issueResolutionLoop: return "Issue Resolution"
        case .releaseCandidate: return "Release Candidate"
        case .publishHandoff: return "Publish/Handoff"
        }
    }
}

enum StageResultStatus: String, Codable {
    case pass
    case fail
    case degraded
    case retryable

    var sortRank: Int {
        switch self {
        case .pass: return 3
        case .retryable: return 2
        case .degraded: return 1
        case .fail: return 0
        }
    }
}

enum FindingSeverity: String, Codable, CaseIterable {
    case critical
    case high
    case medium
    case low

    var sortRank: Int {
        switch self {
        case .critical: return 4
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }
}

enum AIErrorCode: String, Codable {
    case timeout
    case quotaExceeded
    case invalidOutput
    case providerUnavailable
    case policyBlocked
}
