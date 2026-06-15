import SwiftUI

struct CanonicalizationResultView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .orange : .green)
            Text(message)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
        }
        .padding(10)
        .appGlassCard(cornerRadius: 12, fillOpacity: 0.08, borderOpacity: 0.15)
    }
}
