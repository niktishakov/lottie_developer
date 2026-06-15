import Foundation

struct ReleaseCandidateService {
    func build(for run: PipelineRun) -> ReadyCandidate {
        let gate = run.gateResult
        var riskFlags: [String] = []

        if gate.syntax != .pass { riskFlags.append("syntax_not_passed") }
        if gate.motionSemantic != .pass { riskFlags.append("motion_not_passed") }
        if gate.runtime != .pass { riskFlags.append("runtime_not_passed") }

        if let severity = run.latestReport?.highestSeverity,
           severity == .critical || severity == .high {
            riskFlags.append("high_severity_findings")
        }

        return ReadyCandidate(
            id: UUID(),
            revisionID: run.latestRevisionID ?? UUID(),
            gateResults: gate,
            riskFlags: riskFlags,
            approvedAt: nil
        )
    }
}
