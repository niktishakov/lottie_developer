import Foundation
import StoreKit
import OSLog
import Observation

private let logger = Logger(subsystem: "com.nikapps.lottie.developer", category: "PurchaseStore")

@MainActor
@Observable
final class PurchaseStore {
    static let lifetimeID = "com.nikapps.lottie.developer.pro.lifetime"
    static let annualID = "com.nikapps.lottie.developer.pro.annual"

    private(set) var products: [Product] = []
    private(set) var purchasedProductIDs: Set<String> = []
    private(set) var isLoading = false

    var isPro: Bool {
        !purchasedProductIDs.isEmpty
    }

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = listenForTransactions()
        Task { await updatePurchasedProducts() }
    }

    // MARK: - Products

    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await Product.products(for: [
                Self.lifetimeID,
                Self.annualID
            ])
            // Lifetime first
            products = loaded.sorted { $0.type == .nonConsumable && $1.type != .nonConsumable }
            logger.info("Loaded \(loaded.count) products")
        } catch {
            logger.error("Failed to load products: \(error.localizedDescription)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async throws {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await updatePurchasedProducts()
            logger.info("Purchased \(product.id)")
        case .userCancelled:
            logger.info("User cancelled purchase")
        case .pending:
            logger.info("Purchase pending")
        @unknown default:
            break
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        try? await AppStore.sync()
        await updatePurchasedProducts()
        logger.info("Restored purchases, isPro: \(self.isPro)")
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached {
            for await result in Transaction.updates {
                if let transaction = try? await self.checkVerified(result) {
                    await transaction.finish()
                    await self.updatePurchasedProducts()
                }
            }
        }
    }

    private func updatePurchasedProducts() async {
        var purchased: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                purchased.insert(transaction.productID)
            }
        }
        purchasedProductIDs = purchased
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let value):
            return value
        }
    }

    enum StoreError: LocalizedError {
        case verificationFailed

        var errorDescription: String? {
            "Transaction verification failed"
        }
    }
}
