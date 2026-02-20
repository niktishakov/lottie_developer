import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.nikapps.lottie.developer", category: "AnimationStore")

private func decodeMetadataItems(from url: URL) -> [AnimationItem]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode([AnimationItem].self, from: data)
}

private func validateLottieJSONData(_ data: Data) throws {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["v"] != nil,
          json["w"] != nil,
          json["h"] != nil,
          json["layers"] != nil else {
        throw AnimationStore.ImportError.invalidLottieJSON
    }
}

private func writeAnimationData(
    _ data: Data,
    name: String,
    to storageDirectory: URL
) throws -> AnimationItem {
    try validateLottieJSONData(data)

    let fileName = "\(UUID().uuidString).json"
    let destination = storageDirectory.appendingPathComponent(fileName)
    try data.write(to: destination, options: .atomic)

    return AnimationItem(name: name, fileName: fileName)
}

@MainActor
@Observable
final class AnimationStore {
    private(set) var animations: [AnimationItem] = []
    private let fileManager = FileManager.default
    private var hasLoadedMetadata = false
    private var isLoadingMetadata = false

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

    init() {}

    // MARK: - Lottie Validation

    enum ImportError: LocalizedError {
        case invalidLottieJSON

        var errorDescription: String? {
            switch self {
            case .invalidLottieJSON:
                return L10n.string("library.error.invalidLottie")
            }
        }
    }

    // MARK: - Metadata Loading

    func loadMetadataIfNeeded() async {
        guard !hasLoadedMetadata, !isLoadingMetadata else { return }
        isLoadingMetadata = true

        let metadataURL = self.metadataURL
        let metadataBackupURL = self.metadataBackupURL

        let loadResult = await Task.detached(priority: .utility) { () -> ([AnimationItem], Bool)? in
            if let items = decodeMetadataItems(from: metadataURL) {
                return (items, false)
            }
            if let items = decodeMetadataItems(from: metadataBackupURL) {
                return (items, true)
            }
            return nil
        }.value

        isLoadingMetadata = false
        hasLoadedMetadata = true

        guard let (items, restoredFromBackup) = loadResult else {
            logger.info("No metadata found — starting with empty library")
            return
        }

        if animations.isEmpty {
            animations = items
        } else if !items.isEmpty {
            let existingIDs = Set(animations.map(\.id))
            let missing = items.filter { !existingIDs.contains($0.id) }
            if !missing.isEmpty {
                animations.append(contentsOf: missing)
            }
        }

        if restoredFromBackup {
            logger.warning("Primary metadata corrupted, restored \(items.count) animations from backup")
            saveMetadata()
        } else {
            logger.info("Loaded \(items.count) animations from metadata")
        }
    }

    // MARK: - Demo Animation

    func loadDemoAnimationIfNeeded() async {
        let demoKey = "demoAnimationLoaded"
        guard !UserDefaults.standard.bool(forKey: demoKey) else { return }

        guard let bundleURL = Bundle.main.url(forResource: "demo_animation", withExtension: "json") else {
            logger.error("Demo animation not found in bundle")
            return
        }

        do {
            let data = try Data(contentsOf: bundleURL)
            _ = try await importAnimation(data: data, name: "Demo Animation")
            UserDefaults.standard.set(true, forKey: demoKey)
            logger.info("Demo animation loaded successfully")
        } catch {
            logger.error("Failed to load demo animation: \(error.localizedDescription)")
        }
    }

    // MARK: - Import

    func importAnimation(from sourceURL: URL, name: String? = nil) async throws -> AnimationItem {
        let animationName = name ?? sourceURL.deletingPathExtension().lastPathComponent
        let storageDirectory = self.storageDirectory
        let item = try await Task.detached(priority: .userInitiated) {
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            return try writeAnimationData(data, name: animationName, to: storageDirectory)
        }.value

        animations.append(item)
        saveMetadata()
        hasLoadedMetadata = true
        return item
    }

    func importAnimation(data: Data, name: String) async throws -> AnimationItem {
        let storageDirectory = self.storageDirectory
        let item = try await Task.detached(priority: .userInitiated) {
            try writeAnimationData(data, name: name, to: storageDirectory)
        }.value

        animations.append(item)
        saveMetadata()
        hasLoadedMetadata = true
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
