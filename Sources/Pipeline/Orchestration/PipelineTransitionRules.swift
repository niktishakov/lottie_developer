import Foundation

struct PipelineTransitionRules {
    func canEnter(_ stage: PipelineStage, in run: PipelineRun) -> Bool {
        switch stage {
        case .sourceIntake:
            return true
        case .canonicalization:
            return run.status(for: .sourceIntake) == .pass
        case .draftGeneration:
            return run.status(for: .canonicalization) == .pass
        case .syntaxGate:
            return run.status(for: .draftGeneration) == .pass
        case .motionSemanticGate:
            return run.status(for: .syntaxGate) == .pass
        case .runtimeGate:
            return run.status(for: .motionSemanticGate) == .pass
        case .issueResolutionLoop:
            return run.status(for: .syntaxGate) == .fail
                || run.status(for: .motionSemanticGate) == .fail
                || run.status(for: .runtimeGate) == .fail
                || run.currentStage == .issueResolutionLoop
        case .releaseCandidate:
            return run.status(for: .syntaxGate) == .pass
                && run.status(for: .motionSemanticGate) == .pass
                && run.status(for: .runtimeGate) == .pass
        case .publishHandoff:
            return run.readyCandidate?.approvedAt != nil
        }
    }

    func retryBudget(for stage: PipelineStage) -> Int {
        switch stage {
        case .canonicalization:
            return 2
        case .draftGeneration:
            return 2
        case .issueResolutionLoop:
            return 3
        default:
            return 1
        }
    }
}
