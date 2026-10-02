#if os(macOS)
import Foundation

/// Проект = рабочее пространство одной анимации: геометрия-источник + история версий.
struct AnimationProject: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    /// Если true — геометрия из `static.json` в папке проекта (импортированный SVG);
    /// иначе используется bundled sample (ракета).
    var hasImportedStatic: Bool
    /// Имена слоёв геометрии (для контракта AI).
    var layerNames: [String]
    /// Источник геометрии (имя файла SVG/семпла) — для отображения.
    var sourceLabel: String
    var versions: [AnimationVersion]

    init(id: UUID = UUID(), name: String, hasImportedStatic: Bool, layerNames: [String], sourceLabel: String) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.hasImportedStatic = hasImportedStatic
        self.layerNames = layerNames
        self.sourceLabel = sourceLabel
        self.versions = []
    }
}

/// Версия = снапшот сгенерированной анимации (промпт + скомпилированный Lottie + спек).
struct AnimationVersion: Codable, Identifiable, Equatable {
    let id: UUID
    var index: Int          // порядковый (v1, v2, …)
    var prompt: String
    var createdAt: Date
    var compiledFile: String // имя файла в versions/ → скомпилированный Lottie JSON
    var layerCount: Int
    var compilerWarnings: Int
    var specJSON: String?    // исходный AnimationSpec (для повторного редактирования/диффа)
    var isFavourite: Bool
    /// Версия, от которой построена эта (nil — от статичной геометрии).
    var parentVersionID: UUID?
    /// Свободная заметка (комментарий автора/агента).
    var note: String
    /// Кто создал: "mcp", "import", "restore".
    var source: String

    init(id: UUID = UUID(), index: Int, prompt: String, compiledFile: String,
         layerCount: Int, compilerWarnings: Int, specJSON: String?, isFavourite: Bool = false,
         parentVersionID: UUID? = nil, note: String = "", source: String = "mcp") {
        self.id = id
        self.index = index
        self.prompt = prompt
        self.createdAt = Date()
        self.compiledFile = compiledFile
        self.layerCount = layerCount
        self.compilerWarnings = compilerWarnings
        self.specJSON = specJSON
        self.isFavourite = isFavourite
        self.parentVersionID = parentVersionID
        self.note = note
        self.source = source
    }

    var label: String { "v\(index)" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        index = try c.decode(Int.self, forKey: .index)
        prompt = try c.decode(String.self, forKey: .prompt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        compiledFile = try c.decode(String.self, forKey: .compiledFile)
        layerCount = try c.decode(Int.self, forKey: .layerCount)
        compilerWarnings = try c.decode(Int.self, forKey: .compilerWarnings)
        specJSON = try c.decodeIfPresent(String.self, forKey: .specJSON)
        isFavourite = try c.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
        parentVersionID = try c.decodeIfPresent(UUID.self, forKey: .parentVersionID)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "mcp"
    }
}
#endif
