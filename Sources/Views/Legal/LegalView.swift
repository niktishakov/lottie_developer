import SwiftUI

enum LegalPage: String, Identifiable {
    case terms
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: L10n.string("paywall.terms")
        case .privacy: L10n.string("paywall.privacy")
        }
    }
}

struct LegalView: View {
    let page: LegalPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appGlassCard(cornerRadius: 20, fillOpacity: 0.08, borderOpacity: 0.16)
                    .padding(16)
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle(page.title)
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("fileInfo.done")) {
                        dismiss()
                    }
                    .foregroundStyle(.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var content: String {
        switch page {
        case .terms: L10n.string("legal.terms.content")
        case .privacy: L10n.string("legal.privacy.content")
        }
    }
}
