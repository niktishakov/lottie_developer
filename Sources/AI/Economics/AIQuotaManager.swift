import Foundation

@MainActor
final class AIQuotaManager {
    static let shared = AIQuotaManager()

    var perUserCap: Int = 100
    var globalCap: Int = 10_000
    private(set) var perUserUsed: Int = 0
    private(set) var globalUsed: Int = 0

    var canExecute: Bool {
        perUserUsed < perUserCap && globalUsed < globalCap
    }

    func consume(units: Int = 1) {
        perUserUsed += units
        globalUsed += units
    }

    var usageRatio: Double {
        guard perUserCap > 0 else { return 1 }
        return Double(perUserUsed) / Double(perUserCap)
    }
}
