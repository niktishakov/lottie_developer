import Foundation

struct RollbackService {
    func rollback(run: inout PipelineRun, to revisionID: UUID) -> Bool {
        guard let target = run.revisions.first(where: { $0.id == revisionID }) else {
            return false
        }
        guard target.stageResult == .pass else {
            return false
        }

        let rollbackRevision = ArtifactRevision(
            id: UUID(),
            parentRevisionID: run.latestRevisionID,
            sourceArtifactID: run.sourceArtifact.id,
            stage: .issueResolutionLoop,
            createdAt: .now,
            actor: "user",
            diffSummary: "Rollback to revision \(revisionID.uuidString)",
            rollbackPointer: revisionID,
            stageResult: .pass
        )

        run.revisions.append(rollbackRevision)
        run.currentStage = .issueResolutionLoop
        run.readyCandidate = nil
        run.readyLottie = nil
        return true
    }
}
