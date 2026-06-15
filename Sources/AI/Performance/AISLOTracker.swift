import Foundation

@MainActor
final class AISLOTracker {
    static let shared = AISLOTracker()

    private(set) var recentLatencies: [TimeInterval] = []
    let targetP95Seconds: TimeInterval = 12

    func record(latency: TimeInterval) {
        recentLatencies.append(latency)
        if recentLatencies.count > 200 {
            recentLatencies.removeFirst(recentLatencies.count - 200)
        }
    }

    var p95: TimeInterval {
        guard !recentLatencies.isEmpty else { return 0 }
        let sorted = recentLatencies.sorted()
        let index = Int(Double(sorted.count - 1) * 0.95)
        return sorted[index]
    }

    var isDegraded: Bool {
        p95 > targetP95Seconds
    }
}
