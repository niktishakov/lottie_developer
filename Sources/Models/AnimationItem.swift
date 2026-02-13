import Foundation

struct AnimationItem: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let fileName: String
    let dateAdded: Date
    var isFavorite: Bool

    init(name: String, fileName: String) {
        self.id = UUID()
        self.name = name
        self.fileName = fileName
        self.dateAdded = .now
        self.isFavorite = false
    }
}
