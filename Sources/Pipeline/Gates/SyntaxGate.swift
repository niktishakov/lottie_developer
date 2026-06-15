import Foundation

struct SyntaxGate {
    func evaluate(jsonURL: URL) -> [QAFinding] {
        guard let data = try? Data(contentsOf: jsonURL) else {
            return [QAFinding(
                id: UUID(),
                stage: .syntaxGate,
                severity: .critical,
                code: "syntax.unreadable",
                message: "Unable to read JSON payload",
                fieldPath: nil
            )]
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [QAFinding(
                id: UUID(),
                stage: .syntaxGate,
                severity: .critical,
                code: "syntax.parse_error",
                message: "JSON parsing failed",
                fieldPath: nil
            )]
        }

        var findings: [QAFinding] = []
        let requiredFields = ["v", "w", "h", "layers"]

        for field in requiredFields where object[field] == nil {
            findings.append(QAFinding(
                id: UUID(),
                stage: .syntaxGate,
                severity: .critical,
                code: "syntax.missing_field",
                message: "Missing required field: \(field)",
                fieldPath: field
            ))
        }

        if let width = object["w"] as? Double, width <= 0 {
            findings.append(QAFinding(
                id: UUID(),
                stage: .syntaxGate,
                severity: .high,
                code: "syntax.invalid_width",
                message: "Width must be greater than zero",
                fieldPath: "w"
            ))
        }

        if let height = object["h"] as? Double, height <= 0 {
            findings.append(QAFinding(
                id: UUID(),
                stage: .syntaxGate,
                severity: .high,
                code: "syntax.invalid_height",
                message: "Height must be greater than zero",
                fieldPath: "h"
            ))
        }

        return findings
    }
}
