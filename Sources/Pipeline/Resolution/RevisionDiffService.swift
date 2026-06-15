import Foundation

struct RevisionDiffService {
    func makeDiffSummary(previous: ArtifactRevision?, nextStage: PipelineStage) -> String {
        guard let previous else {
            return "Initial revision created at stage \(nextStage.rawValue)"
        }
        return "Transitioned from stage \(previous.stage.rawValue) to stage \(nextStage.rawValue)"
    }
}
