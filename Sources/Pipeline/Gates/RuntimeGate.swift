import Foundation

struct RuntimeGate {
    func evaluate(jsonURL: URL) -> [QAFinding] {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            return [QAFinding(
                id: UUID(),
                stage: .runtimeGate,
                severity: .critical,
                code: "runtime.file_missing",
                message: "Animation file no longer exists on disk",
                fieldPath: nil
            )]
        }

        guard let data = try? Data(contentsOf: jsonURL) else {
            return [QAFinding(
                id: UUID(),
                stage: .runtimeGate,
                severity: .critical,
                code: "runtime.unreadable",
                message: "Unable to read animation file for runtime checks",
                fieldPath: nil
            )]
        }

        if data.isEmpty {
            return [QAFinding(
                id: UUID(),
                stage: .runtimeGate,
                severity: .critical,
                code: "runtime.empty_payload",
                message: "Animation payload is empty",
                fieldPath: nil
            )]
        }

        if (try? JSONSerialization.jsonObject(with: data)) == nil {
            return [QAFinding(
                id: UUID(),
                stage: .runtimeGate,
                severity: .critical,
                code: "runtime.invalid_json",
                message: "Runtime payload is not valid JSON",
                fieldPath: nil
            )]
        }

        if data.count > 10_000_000 {
            return [QAFinding(
                id: UUID(),
                stage: .runtimeGate,
                severity: .medium,
                code: "runtime.large_payload",
                message: "Payload is large and may reduce runtime stability",
                fieldPath: nil
            )]
        }

        return []
    }
}
