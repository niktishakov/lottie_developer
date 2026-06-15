import Foundation

@MainActor
final class AICostTracker {
    static let shared = AICostTracker()

    private(set) var totalCostUSD: Double = 0

    func add(cost: Double) {
        totalCostUSD += max(0, cost)
    }
}
