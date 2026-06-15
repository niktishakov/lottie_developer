import Foundation

@MainActor
final class AIDegradedModePolicy {
    static let shared = AIDegradedModePolicy()

    var isDegradedModeEnabled: Bool {
        AISLOTracker.shared.isDegraded || !AIQuotaManager.shared.canExecute
    }

    var bannerMessage: String {
        if AISLOTracker.shared.isDegraded {
            return "AI is temporarily degraded. Continue via deterministic path."
        }
        if !AIQuotaManager.shared.canExecute {
            return "AI quota reached. Continue via deterministic path."
        }
        return ""
    }
}
