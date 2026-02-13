import Foundation
import Observation

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

    init() {
        loadMetadata()
    }

    func importAnimation(from sourceURL: URL, name: String? = nil) throws -> AnimationItem {
        let animationName = name ?? sourceURL.deletingPathExtension().lastPathComponent
        let fileName = "\(UUID().uuidString).json"
        let destination = storageDirectory.appendingPathComponent(fileName)

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        try fileManager.copyItem(at: sourceURL, to: destination)

        let item = AnimationItem(name: animationName, fileName: fileName)
        animations.append(item)
        saveMetadata()
        return item
    }

    func importAnimation(data: Data, name: String) throws -> AnimationItem {
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

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let items = try? JSONDecoder().decode([AnimationItem].self, from: data) else { return }
        animations = items
    }

    private func saveMetadata() {
        guard let data = try? JSONEncoder().encode(animations) else { return }
        try? data.write(to: metadataURL)
    }
}
