import Foundation

struct PublishHandoffService {
    private let checksumService = ChecksumService()

    func publish(run: inout PipelineRun, runDirectory: URL, sourceURL: URL) throws -> ReadyLottie {
        let readyRef = runDirectory.appendingPathComponent("ready-lottie.json")
        let manifestRef = runDirectory.appendingPathComponent("manifest.json")

        let data = try Data(contentsOf: sourceURL)
        let checksum = checksumService.sha256Hex(of: data)

        let manifest: [String: String] = [
            "run_id": run.id.uuidString,
            "revision_id": run.latestRevisionID?.uuidString ?? "",
            "source_ref": sourceURL.path,
            "created_at": ISO8601DateFormatter().string(from: .now),
            "checksum": checksum
        ]

        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: manifestRef, options: .atomic)
        try data.write(to: readyRef, options: .atomic)

        let ready = ReadyLottie(
            id: UUID(),
            artifactRef: readyRef.path,
            releaseManifestRef: manifestRef.path,
            checksum: checksum
        )
        run.readyLottie = ready
        return ready
    }
}
