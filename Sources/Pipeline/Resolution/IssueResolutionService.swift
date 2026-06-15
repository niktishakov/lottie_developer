import Foundation

struct IssueResolutionService {
    func applyManualResolution(to run: inout PipelineRun, actor: String) -> ArtifactRevision {
        let revision = ArtifactRevision(
            id: UUID(),
            parentRevisionID: run.latestRevisionID,
            sourceArtifactID: run.sourceArtifact.id,
            stage: .issueResolutionLoop,
            createdAt: .now,
            actor: actor,
            diffSummary: "Manual issue resolution applied",
            rollbackPointer: run.latestPassingRevisionID,
            stageResult: .pass
        )
        run.revisions.append(revision)
        run.currentStage = .issueResolutionLoop
        return revision
    }
}
