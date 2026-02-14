import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.nikapps.lottie.developer", category: "AnimationStore")

@Observable
final class AnimationStore {
    private(set) var animations: [AnimationItem] = []
    private let fileManager = FileManager.default

    var storageDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("LottieAnimations", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var metadataURL: URL {
        storageDirectory.appendingPathComponent("metadata.json")
    }

    private var metadataBackupURL: URL {
        storageDirectory.appendingPathComponent("metadata.backup.json")
    }

    init() {
        loadMetadata()
    }

    // MARK: - Lottie Validation

    enum ImportError: LocalizedError {
        case invalidLottieJSON

        var errorDescription: String? {
            switch self {
            case .invalidLottieJSON:
                return String(localized: "library.error.invalidLottie")
            }
        }
    }

    /// Validates that the given data represents a Lottie animation JSON.
    /// Checks for required top-level keys: "v" (version), "w" (width), "h" (height), "layers".
    private func validateLottieJSON(_ data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["v"] != nil,
              json["w"] != nil,
              json["h"] != nil,
              json["layers"] != nil else {
            throw ImportError.invalidLottieJSON
        }
    }

    // MARK: - Import

    func importAnimation(from sourceURL: URL, name: String? = nil) throws -> AnimationItem {
        let animationName = name ?? sourceURL.deletingPathExtension().lastPathComponent
        let fileName = "\(UUID().uuidString).json"
        let destination = storageDirectory.appendingPathComponent(fileName)

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: sourceURL)
        try validateLottieJSON(data)

        try data.write(to: destination)

        let item = AnimationItem(name: animationName, fileName: fileName)
        animations.append(item)
        saveMetadata()
        return item
    }

    func importAnimation(data: Data, name: String) throws -> AnimationItem {
        try validateLottieJSON(data)

        let fileName = "\(UUID().uuidString).json"
        let destination = storageDirectory.appendingPathComponent(fileName)
        try data.write(to: destination)

        let item = AnimationItem(name: name, fileName: fileName)
        animations.append(item)
        saveMetadata()
        return item
    }

    func fileURL(for item: AnimationItem) -> URL {
        storageDirectory.appendingPathComponent(item.fileName)
    }

    func toggleFavorite(_ item: AnimationItem) {
        guard let index = animations.firstIndex(where: { $0.id == item.id }) else { return }
        animations[index].isFavorite.toggle()
        saveMetadata()
    }

    func rename(_ item: AnimationItem, to newName: String) {
        guard let index = animations.firstIndex(where: { $0.id == item.id }) else { return }
        animations[index].name = newName
        saveMetadata()
    }

    func delete(_ item: AnimationItem) {
        try? fileManager.removeItem(at: fileURL(for: item))
        animations.removeAll { $0.id == item.id }
        saveMetadata()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            let item = animations[index]
            try? fileManager.removeItem(at: fileURL(for: item))
        }
        animations.remove(atOffsets: offsets)
        saveMetadata()
    }

    // MARK: - Metadata Persistence

    private func loadMetadata() {
        // Try primary metadata file first
        if let items = decodeMetadata(from: metadataURL) {
            animations = items
            logger.info("Loaded \(items.count) animations from metadata")
            return
        }

        // Fall back to backup if primary is corrupted
        if let items = decodeMetadata(from: metadataBackupURL) {
            animations = items
            logger.warning("Primary metadata corrupted, restored \(items.count) animations from backup")
            // Restore primary from backup
            saveMetadata()
            return
        }

        logger.info("No metadata found — starting with empty library")
        animations = []
    }

    private func decodeMetadata(from url: URL) -> [AnimationItem]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode([AnimationItem].self, from: data)
        } catch {
            logger.error("Failed to decode metadata at \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private func saveMetadata() {
        do {
            let data = try JSONEncoder().encode(animations)

            // Write to a temporary file first, then atomically move
            let tempURL = storageDirectory.appendingPathComponent("metadata.tmp.json")
            try data.write(to: tempURL, options: .atomic)

            // Backup current metadata before overwriting
            if fileManager.fileExists(atPath: metadataURL.path) {
                try? fileManager.removeItem(at: metadataBackupURL)
                try? fileManager.copyItem(at: metadataURL, to: metadataBackupURL)
            }

            // Move temp to primary
            try? fileManager.removeItem(at: metadataURL)
            try fileManager.moveItem(at: tempURL, to: metadataURL)

            logger.debug("Saved metadata for \(self.animations.count) animations")
        } catch {
            logger.error("Failed to save metadata: \(error.localizedDescription)")
        }
    }
}
