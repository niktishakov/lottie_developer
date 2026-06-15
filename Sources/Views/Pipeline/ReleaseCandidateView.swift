import SwiftUI

struct ReleaseCandidateView: View {
    let candidate: ReadyCandidate
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Release Candidate")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            if candidate.riskFlags.isEmpty {
                Text("No risk flags")
                    .foregroundStyle(.green)
            } else {
                ForEach(candidate.riskFlags, id: \.self) { flag in
                    Text("• \(flag)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if candidate.approvedAt == nil {
                Button("Approve Candidate") {
                    onApprove()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Approve Candidate")
            } else {
                Text("Approved")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
        .appGlassCard(cornerRadius: 16, fillOpacity: 0.1, borderOpacity: 0.2)
    }
}
