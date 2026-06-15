import SwiftUI

struct PromptSpecInputView: View {
    @Binding var prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt/Spec")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            TextEditor(text: $prompt)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Prompt Spec")

            Text("Coming in M2")
                .font(.caption)
                .foregroundStyle(AppTheme.textMuted)
        }
        .padding(12)
        .appGlassCard(cornerRadius: 14, fillOpacity: 0.08, borderOpacity: 0.15)
    }
}
