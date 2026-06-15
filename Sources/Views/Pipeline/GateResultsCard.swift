import SwiftUI

struct GateResultsCard: View {
    let gateResult: GateResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gate Results")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            row("Syntax", gateResult.syntax)
            row("Motion", gateResult.motionSemantic)
            row("Runtime", gateResult.runtime)
        }
        .padding(14)
        .appGlassCard(cornerRadius: 16, fillOpacity: 0.1, borderOpacity: 0.2)
    }

    private func row(_ title: String, _ status: StageResultStatus) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(status.rawValue.uppercased())
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(capsuleColor(status), in: Capsule())
                .foregroundStyle(.white)
        }
    }

    private func capsuleColor(_ status: StageResultStatus) -> Color {
        switch status {
        case .pass: .green
        case .fail: .red
        case .degraded: .orange
        case .retryable: .blue
        }
    }
}
