import SwiftUI

struct PipelineStatusView: View {
    let run: PipelineRun
    @Binding var selectedStage: PipelineStage
    let onSelect: (PipelineStage) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PipelineStage.allCases) { stage in
                    Button {
                        selectedStage = stage
                        onSelect(stage)
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(stage.rawValue)")
                                .font(.caption2.weight(.bold))
                            Text(stage.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(chipBackground(for: stage))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(stage == selectedStage ? Color.cyan : Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stage \(stage.rawValue) \(stage.title)")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func chipBackground(for stage: PipelineStage) -> some ShapeStyle {
        switch run.status(for: stage) {
        case .pass:
            return AnyShapeStyle(Color.green.opacity(0.3))
        case .fail:
            return AnyShapeStyle(Color.red.opacity(0.35))
        case .degraded:
            return AnyShapeStyle(Color.orange.opacity(0.35))
        case .retryable:
            return AnyShapeStyle(Color.white.opacity(0.08))
        }
    }
}
