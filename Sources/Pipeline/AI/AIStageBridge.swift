import Foundation

@MainActor
struct AIStageBridge {
    func canUseAI(for stage: PipelineStage) -> Bool {
        stage == .draftGeneration || stage == .issueResolutionLoop
    }
}
