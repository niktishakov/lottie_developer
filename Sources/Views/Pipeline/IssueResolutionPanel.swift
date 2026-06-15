import SwiftUI

struct IssueResolutionPanel: View {
    let run: PipelineRun
    let selectedStage: PipelineStage
    let onResolve: () -> Void
    let onReRunGates: () -> Void
    let onRollback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Issue Resolution")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            Text("Retries for \(selectedStage.title): \(run.retryCount(for: selectedStage))")
                .font(.caption)
                .foregroundStyle(AppTheme.textMuted)

            if let reason = run.reason(for: selectedStage) {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            HStack(spacing: 8) {
                Button("Apply Fix") { onResolve() }
                    .buttonStyle(.borderedProminent)
                Button("Re-run Gates") { onReRunGates() }
                    .buttonStyle(.bordered)
                Button("Rollback") { onRollback() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .appGlassCard(cornerRadius: 16, fillOpacity: 0.1, borderOpacity: 0.2)
    }
}
