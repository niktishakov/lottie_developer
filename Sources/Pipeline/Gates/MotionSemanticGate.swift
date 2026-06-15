import Foundation

struct MotionSemanticGate {
    func evaluate(jsonURL: URL) -> [QAFinding] {
        guard let data = try? Data(contentsOf: jsonURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [QAFinding(
                id: UUID(),
                stage: .motionSemanticGate,
                severity: .critical,
                code: "motion.unreadable",
                message: "Unable to evaluate motion semantics due to invalid payload",
                fieldPath: nil
            )]
        }

        var findings: [QAFinding] = []

        let ip = (object["ip"] as? Double) ?? 0
        let op = (object["op"] as? Double) ?? 0
        if op <= ip {
            findings.append(QAFinding(
                id: UUID(),
                stage: .motionSemanticGate,
                severity: .high,
                code: "motion.invalid_timing",
                message: "Out-point must be greater than in-point",
                fieldPath: "ip/op"
            ))
        }

        if let layers = object["layers"] as? [[String: Any]], layers.isEmpty {
            findings.append(QAFinding(
                id: UUID(),
                stage: .motionSemanticGate,
                severity: .high,
                code: "motion.empty_layers",
                message: "No layers found to animate",
                fieldPath: "layers"
            ))
        }

        let frameRate = (object["fr"] as? Double) ?? 0
        if frameRate <= 0 {
            findings.append(QAFinding(
                id: UUID(),
                stage: .motionSemanticGate,
                severity: .medium,
                code: "motion.invalid_frame_rate",
                message: "Frame rate should be greater than zero",
                fieldPath: "fr"
            ))
        }

        return findings
    }
}
