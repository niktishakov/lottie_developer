import SwiftUI
import StoreKit

struct PaywallView: View {
    /// Когда передан из онбординга — вызывается при dismiss/покупке для завершения онбординга.
    /// Когда nil (вызов из библиотеки) — используется стандартный dismiss().
    var onDismissToLibrary: (() -> Void)?

    @Environment(PurchaseStore.self) private var purchaseStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProduct: Product?
    @State private var isPurchasing = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showLegal: LegalPage?
    @State private var logoPlayback = PlaybackState()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    featureList
                    pricingOptions
                    purchaseButton
                    reassuranceNote
                    restoreButton

                    if onDismissToLibrary != nil {
                        continueForFreeButton
                    }

                    legalFooter
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(paywallBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismissPaywall()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .accessibilityLabel(L10n.string("common.cancel"))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
            configureLogoPlayback()
        }
        .interactiveDismissDisabled(isPurchasing)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 14) {
            animatedLogoBadge

            Text(L10n.string("paywall.title"))
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text(L10n.string("paywall.subtitle"))
                .font(.body)
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var animatedLogoBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(0.3),
                            Color.blue.opacity(0.4),
                            Color(red: 0.07, green: 0.14, blue: 0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let url = demoAnimationURL {
                LottieView(fileURL: url, playback: logoPlayback)
                    .padding(8)
            } else {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            }
        }
        .frame(width: 92, height: 92)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .cyan.opacity(0.25), radius: 16, y: 8)
    }

    // MARK: - Features

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow(icon: "square.and.arrow.down.on.square", text: L10n.string("paywall.feature.import"))
            featureRow(icon: "play.rectangle.on.rectangle", text: L10n.string("paywall.feature.library"))
            featureRow(icon: "arrow.up.circle", text: L10n.string("paywall.feature.updates"))
        }
        .padding(20)
        .background(cardBackground)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 30)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
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
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedProduct = product
            }
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
                    .foregroundStyle(.white)

                Text(product.displayPrice)
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                Text(isLifetime
                    ? L10n.string("paywall.lifetime.description")
                    : L10n.string("paywall.annual.description"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.14 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                isSelected ? Color.cyan : Color.white.opacity(0.18),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                    .shadow(
                        color: isSelected ? .cyan.opacity(0.2) : .black.opacity(0.06),
                        radius: 8,
                        y: 3
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
            .shadow(color: .cyan.opacity(0.28), radius: 10, y: 4)
        }
        .disabled(selectedProduct == nil || isPurchasing)
        .scaleEffect(selectedProduct != nil ? 1.0 : 0.97)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selectedProduct?.id)
    }

    // MARK: - Restore

    private var reassuranceNote: some View {
        Text(L10n.string("paywall.reassurance"))
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.58))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    private var restoreButton: some View {
        Button {
            Task {
                await purchaseStore.restorePurchases()
                if purchaseStore.isPro {
                    dismissPaywall()
                }
            }
        } label: {
            Text(L10n.string("paywall.restore"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
        }
        .buttonStyle(.plain)
    }

    private var continueForFreeButton: some View {
        Button {
            dismissPaywall()
        } label: {
            Text(L10n.string("onboarding.demo.cta.free"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.78))
        }
        .buttonStyle(.plain)
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
            .foregroundStyle(.white.opacity(0.72))

            Text(L10n.string("paywall.legal"))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.48))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Styles

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
    }

    private var paywallBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.12, blue: 0.22),
                Color(red: 0.02, green: 0.08, blue: 0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(Color.cyan.opacity(0.14))
                .frame(width: 300, height: 300)
                .blur(radius: 62)
                .offset(x: -34, y: -110)
        }
    }

    private var demoAnimationURL: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "demo_animation", withExtension: "json")
        #else
        Bundle.main.url(forResource: "demo_animation", withExtension: "json")
        #endif
    }

    // MARK: - Actions

    private func performPurchase() async {
        guard let product = selectedProduct else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await purchaseStore.purchase(product)
            if purchaseStore.isPro {
                dismissPaywall()
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func configureLogoPlayback() {
        logoPlayback.isPlaying = true
        logoPlayback.loopEnabled = true
        logoPlayback.speed = 0.9
        logoPlayback.fromProgress = 0
        logoPlayback.toProgress = 1
        logoPlayback.currentProgress = 0
    }

    private func dismissPaywall() {
        if let onDismissToLibrary {
            onDismissToLibrary()
        } else {
            dismiss()
        }
    }
}
