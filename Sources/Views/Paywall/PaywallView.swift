import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(PurchaseStore.self) private var purchaseStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProduct: Product?
    @State private var isPurchasing = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showLegal: LegalPage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    featureList
                    pricingOptions
                    purchaseButton
                    reassuranceNote
                    restoreButton
                    legalFooter
                }
                .padding(24)
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel")) { dismiss() }
                }
            }
            .alert(L10n.string("library.error.title"), isPresented: $showError) {
                Button(L10n.string("library.error.ok")) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $showLegal) { page in
                LegalView(page: page)
            }
        }
        .presentationDetents([.large])
        .task {
            await purchaseStore.loadProducts()
            selectedProduct = purchaseStore.products.first {
                $0.id == PurchaseStore.lifetimeID
            }
        }
        .interactiveDismissDisabled(isPurchasing)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(L10n.string("paywall.title"))
                .font(.title2.bold())

            Text(L10n.string("paywall.subtitle"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Features

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow(icon: "square.and.arrow.down.on.square", text: L10n.string("paywall.feature.import"))
            featureRow(icon: "folder", text: L10n.string("paywall.feature.library"))
            featureRow(icon: "arrow.up.circle", text: L10n.string("paywall.feature.updates"))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: - Pricing

    private var pricingOptions: some View {
        HStack(spacing: 12) {
            ForEach(purchaseStore.products, id: \.id) { product in
                pricingCard(for: product)
            }
        }
    }

    private func pricingCard(for product: Product) -> some View {
        let isSelected = selectedProduct?.id == product.id
        let isLifetime = product.id == PurchaseStore.lifetimeID

        return Button {
            selectedProduct = product
        } label: {
            VStack(spacing: 8) {
                if isLifetime {
                    Text(L10n.string("paywall.lifetime.badge"))
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.cyan))
                }

                Text(isLifetime
                    ? L10n.string("paywall.lifetime")
                    : L10n.string("paywall.annual"))
                    .font(.headline)

                Text(product.displayPrice)
                    .font(.title2.bold())

                Text(isLifetime
                    ? L10n.string("paywall.lifetime.description")
                    : L10n.string("paywall.annual.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isSelected ? Color.cyan : .clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Purchase Button

    private var purchaseButton: some View {
        Button {
            Task { await performPurchase() }
        } label: {
            Group {
                if isPurchasing {
                    ProgressView()
                        .tint(.white)
                } else if let product = selectedProduct {
                    let isLifetime = product.id == PurchaseStore.lifetimeID
                    Text(isLifetime
                        ? L10n.format("paywall.cta.lifetime", product.displayPrice)
                        : L10n.format("paywall.cta.annual", product.displayPrice))
                } else {
                    Text("...")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [.cyan, .blue],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .disabled(selectedProduct == nil || isPurchasing)
    }

    // MARK: - Restore

    private var reassuranceNote: some View {
        Text(L10n.string("paywall.reassurance"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    private var restoreButton: some View {
        Button {
            Task {
                await purchaseStore.restorePurchases()
                if purchaseStore.isPro {
                    dismiss()
                }
            }
        } label: {
            Text(L10n.string("paywall.restore"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Legal

    private var legalFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button(L10n.string("paywall.terms")) {
                    showLegal = .terms
                }
                Button(L10n.string("paywall.privacy")) {
                    showLegal = .privacy
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(L10n.string("paywall.legal"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Actions

    private func performPurchase() async {
        guard let product = selectedProduct else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await purchaseStore.purchase(product)
            if purchaseStore.isPro {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
