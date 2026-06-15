import Foundation

@MainActor
protocol PipelineOrchestrating {
    func runStage(_ stage: PipelineStage, runID: UUID) async -> StageResultStatus
    func rerunFromStage(_ stage: PipelineStage, runID: UUID) async
    func rollback(runID: UUID, to revisionID: UUID) async -> Bool
}

@MainActor
final class PipelineOrchestrator: PipelineOrchestrating {
    private unowned let revisionStore: RevisionStore

    init(revisionStore: RevisionStore) {
        self.revisionStore = revisionStore
    }

    func runStage(_ stage: PipelineStage, runID: UUID) async -> StageResultStatus {
        await revisionStore.runStage(stage, runID: runID)
    }

    func rerunFromStage(_ stage: PipelineStage, runID: UUID) async {
        _ = await revisionStore.runStage(stage, runID: runID)
    }

    func rollback(runID: UUID, to revisionID: UUID) async -> Bool {
        await revisionStore.rollback(runID: runID, to: revisionID)
    }
}
