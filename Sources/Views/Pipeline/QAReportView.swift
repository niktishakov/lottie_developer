import SwiftUI

struct QAReportView: View {
    let report: QAReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QA Report")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            if let report {
                if report.allFindings.isEmpty {
                    Text("No findings")
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(report.allFindings) { finding in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(color(for: finding.severity))
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.message)
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text("\(finding.stage.title) · \(finding.code)")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textMuted)
                            }
                        }
                    }
                }
            } else {
                Text("Run any gate to generate report")
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(14)
        .appGlassCard(cornerRadius: 16, fillOpacity: 0.1, borderOpacity: 0.2)
    }

    private func color(for severity: FindingSeverity) -> Color {
        switch severity {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .blue
        }
    }
}
