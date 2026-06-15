import SwiftUI

struct RevisionHistoryView: View {
    let revisions: [ArtifactRevision]
    let onRollback: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Revision History")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            if revisions.isEmpty {
                Text("No revisions yet")
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                ForEach(revisions.reversed()) { revision in
                    HStack(spacing: 8) {
                        Text("S\(revision.stage.rawValue)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.15), in: Capsule())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(revision.diffSummary ?? "Revision")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(revision.createdAt, style: .time)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.textMuted)
                        }

                        Spacer()

                        if revision.stageResult == .pass {
                            Button("Rollback") {
                                onRollback(revision.id)
                            }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.cyan)
                        }
                    }
                }
            }
        }
        .padding(14)
        .appGlassCard(cornerRadius: 16, fillOpacity: 0.1, borderOpacity: 0.2)
    }
}
