#if os(macOS)
import Foundation
import Observation

/// Хранилище проектов на диске (Application Support/LottieDeveloperMac/projects/<id>/).
/// Layout: project.json (метаданные+версии), static.json (импорт SVG, опц.), versions/<vid>.json (скомпилированный Lottie).
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [AnimationProject] = []

    private let fm = FileManager.default
    /// Подпись состояния диска (mtime всех project.json) — для live-reload изменений из MCP.
    private var diskSignature = ""

    init() {
        load()
    }

    /// Перечитать с диска, если что-то поменялось извне (например, lottie-mcp). true — если перечитали.
    @discardableResult
    func reloadIfChanged() -> Bool {
        let sig = currentDiskSignature()
        guard sig != diskSignature else { return false }
        load()
        return true
    }

    private func currentDiskSignature() -> String {
        guard let entries = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil) else { return "" }
        return entries.filter(\.hasDirectoryPath).map { dir -> String in
            let f = dir.appendingPathComponent("project.json")
            let m = (try? fm.attributesOfItem(atPath: f.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(dir.lastPathComponent):\(m)"
        }.sorted().joined(separator: "|")
    }

    // MARK: - UI command (MCP → app)

    /// Файл-команда, через который lottie-mcp просит приложение открыть проект/версию.
    var uiCommandURL: URL { rootDir.deletingLastPathComponent().appendingPathComponent("ui_command.json") }

    struct UICommand: Codable, Equatable {
        var projectID: UUID?
        var versionID: UUID?
        var issuedAt: Date
        var frame: Double? = nil
        var layer: String? = nil
        /// Тап по точке [x, y] в координатах композиции (как клик по холсту).
        var tap: [Double]? = nil
    }

    /// Снимок UI, который приложение публикует для lottie-mcp (`get_app_state`).
    struct AppState: Codable, Equatable {
        var projectID: UUID?
        var projectName: String?
        var version: String?
        var frame: Double
        var playing: Bool
        var mode: String
        var engine: String
        var activeEngine: String
        var selectedLayer: String?
        var overrides: [String: LayerOverride]
        var updatedAt: Date
    }

    var appStateURL: URL { rootDir.deletingLastPathComponent().appendingPathComponent("ui_state.json") }

    func writeAppState(_ st: AppState) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(st) { try? data.write(to: appStateURL, options: .atomic) }
    }

    func readAppState() -> AppState? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: appStateURL) else { return nil }
        return try? dec.decode(AppState.self, from: data)
    }

    func writeUICommand(_ cmd: UICommand) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(cmd) { try? data.write(to: uiCommandURL, options: .atomic) }
    }

    func readUICommand() -> UICommand? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: uiCommandURL) else { return nil }
        return try? dec.decode(UICommand.self, from: data)
    }

    // MARK: - Paths

    var rootDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LottieDeveloperMac/projects", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func projectDir(_ id: UUID) -> URL {
        let dir = rootDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func staticURL(_ id: UUID) -> URL { projectDir(id).appendingPathComponent("static.json") }
    func versionsDir(_ id: UUID) -> URL {
        let dir = projectDir(id).appendingPathComponent("versions", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func versionURL(_ projectID: UUID, _ versionFile: String) -> URL {
        versionsDir(projectID).appendingPathComponent(versionFile)
    }

    // MARK: - Lookup

    func project(_ id: UUID) -> AnimationProject? { projects.first { $0.id == id } }

    // MARK: - Geometry

    func bundledStaticData() -> Data? {
        if let url = Bundle.main.url(forResource: "rocket_static_simplified", withExtension: "json") {
            return try? Data(contentsOf: url)
        }
        // CLI (lottie-mcp) без бандла: семпл, скопированный приложением при первом запуске.
        return try? Data(contentsOf: sampleCacheURL)
    }

    var sampleCacheURL: URL { rootDir.deletingLastPathComponent().appendingPathComponent("sample_static.json") }

    /// Приложение кладёт семпл рядом с проектами, чтобы lottie-mcp мог им пользоваться.
    func exportSampleForCLI() {
        guard !fm.fileExists(atPath: sampleCacheURL.path),
              let url = Bundle.main.url(forResource: "rocket_static_simplified", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return }
        try? data.write(to: sampleCacheURL, options: .atomic)
    }

    /// Статичная геометрия проекта (импорт или bundled).
    func geometryData(for project: AnimationProject) -> Data? {
        if project.hasImportedStatic {
            return try? Data(contentsOf: staticURL(project.id))
        }
        return bundledStaticData()
    }

    /// Превью-URL геометрии (для показа без анимации). Для импортированного — static.json,
    /// для bundled — пишем во временный файл.
    func geometryPreviewURL(for project: AnimationProject) -> URL? {
        if project.hasImportedStatic { return staticURL(project.id) }
        guard let data = bundledStaticData() else { return nil }
        let url = fm.temporaryDirectory.appendingPathComponent("geom_\(project.id.uuidString).json")
        try? data.write(to: url)
        return url
    }

    // MARK: - Mutations

    @discardableResult
    func createSampleProject(name: String = "Untitled") -> AnimationProject {
        let names = layerNames(from: bundledStaticData())
        var p = AnimationProject(name: name, hasImportedStatic: false, layerNames: names, sourceLabel: "Sample (rocket)")
        projects.insert(p, at: 0)
        save(p)
        p = projects[0]
        return p
    }

    @discardableResult
    func createProjectFromSVG(name: String, svgStaticData: Data, layerNames: [String], sourceLabel: String) -> AnimationProject {
        let p = AnimationProject(name: name, hasImportedStatic: true, layerNames: layerNames, sourceLabel: sourceLabel)
        try? svgStaticData.write(to: staticURL(p.id), options: .atomic)
        projects.insert(p, at: 0)
        save(p)
        return p
    }

    @discardableResult
    func createProjectFromLottie(name: String, lottieData: Data, sourceLabel: String) -> AnimationProject {
        let names = layerNames(from: lottieData)
        let p = AnimationProject(name: name, hasImportedStatic: true, layerNames: names, sourceLabel: sourceLabel)
        try? lottieData.write(to: staticURL(p.id), options: .atomic)
        projects.insert(p, at: 0)
        save(p)
        return p
    }

    /// Заменить геометрию проекта импортированным Lottie JSON.
    func setImportedLottie(projectID: UUID, data: Data, sourceLabel: String) {
        let names = layerNames(from: data)
        setImportedStatic(projectID: projectID, data: data, layerNames: names, sourceLabel: sourceLabel)
    }

    /// Заменить геометрию проекта импортированным SVG.
    func setImportedStatic(projectID: UUID, data: Data, layerNames: [String], sourceLabel: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        try? data.write(to: staticURL(projectID), options: .atomic)
        projects[idx].hasImportedStatic = true
        projects[idx].layerNames = layerNames
        projects[idx].sourceLabel = sourceLabel
        projects[idx].updatedAt = Date()
        save(projects[idx])
    }

    @discardableResult
    func addVersion(projectID: UUID, prompt: String, compiledData: Data, layerCount: Int,
                    compilerWarnings: Int, specJSON: String?, parentVersionID: UUID? = nil,
                    note: String = "", source: String = "mcp") -> AnimationVersion? {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let nextIndex = (projects[idx].versions.map { $0.index }.max() ?? 0) + 1
        let file = "v\(nextIndex)_\(UUID().uuidString).json"
        try? compiledData.write(to: versionURL(projectID, file), options: .atomic)
        let version = AnimationVersion(index: nextIndex, prompt: prompt, compiledFile: file,
                                       layerCount: layerCount, compilerWarnings: compilerWarnings, specJSON: specJSON,
                                       parentVersionID: parentVersionID, note: note, source: source)
        projects[idx].versions.append(version)
        projects[idx].updatedAt = Date()
        save(projects[idx])
        return version
    }

    func toggleFavourite(projectID: UUID, versionID: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard let vIdx = projects[idx].versions.firstIndex(where: { $0.id == versionID }) else { return }
        projects[idx].versions[vIdx].isFavourite.toggle()
        projects[idx].updatedAt = Date()
        save(projects[idx])
    }

    func setNote(projectID: UUID, versionID: UUID, note: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }),
              let vIdx = projects[idx].versions.firstIndex(where: { $0.id == versionID }) else { return }
        projects[idx].versions[vIdx].note = note
        projects[idx].updatedAt = Date()
        save(projects[idx])
    }

    func deleteVersion(projectID: UUID, versionID: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard let vIdx = projects[idx].versions.firstIndex(where: { $0.id == versionID }) else { return }
        let file = projects[idx].versions[vIdx].compiledFile
        try? fm.removeItem(at: versionURL(projectID, file))
        projects[idx].versions.remove(at: vIdx)
        projects[idx].updatedAt = Date()
        save(projects[idx])
    }

    /// Пустой проект под растровые ассеты (композиция w×h).
    @discardableResult
    func createBlankProject(name: String, width: Int, height: Int, fps: Int = 60, frames: Int = 120) -> AnimationProject {
        createProjectFromLottie(name: name, lottieData: LottieImageLayers.blank(width: width, height: height, fps: fps, frames: frames),
                                sourceLabel: "Images \(width)×\(height)")
    }

    /// Добавить картинку слоем в геометрию проекта. Возвращает итоговое имя слоя.
    @discardableResult
    func addImage(projectID: UUID, image: Data, name: String, frame: CGRect? = nil) throws -> String {
        guard let p = project(projectID), let geom = geometryData(for: p) else {
            throw LottieImageLayers.ImageError(message: "Project not found")
        }
        let (data, layer) = try LottieImageLayers.addImage(to: geom, image: image, name: name, frame: frame)
        setImportedLottie(projectID: projectID, data: data, sourceLabel: p.sourceLabel)
        return layer
    }

    /// Новый проект из zip/папки ассетов (SVG, картинки, Lottie) — одной композицией.
    func importBundle(_ url: URL, name: String? = nil) throws -> (AnimationProject, AssetBundle.Report) {
        let r = try AssetBundle.load(url)
        let base = name ?? url.deletingPathExtension().lastPathComponent
        let p = createProjectFromLottie(name: uniqueName(base), lottieData: r.data, sourceLabel: url.lastPathComponent)
        return (p, r)
    }

    /// Изменить геометрию проекта функцией над Lottie JSON.
    func editGeometry(projectID: UUID, _ edit: (Data) throws -> Data) throws {
        guard let p = project(projectID), let geom = geometryData(for: p) else {
            throw LottieImageLayers.ImageError(message: "Project not found")
        }
        setImportedLottie(projectID: projectID, data: try edit(geom), sourceLabel: p.sourceLabel)
    }

    /// Добавить к сцене SVG/Lottie группой. Возвращает имя группы и предупреждения импорта.
    @discardableResult
    func addPart(projectID: UUID, data: Data, isSVG: Bool, name: String, origin: CGPoint?) throws -> (group: String, warnings: [String]) {
        var part = data
        var warnings: [String] = []
        if isSVG {
            let r = try SVGToLottie.convert(svgData: data)
            part = r.data; warnings = r.warnings
        }
        var group = ""
        try editGeometry(projectID: projectID) { geom in
            let canvas = LottieMerge.size(geom) ?? .zero, size = LottieMerge.size(part) ?? .zero
            let o = origin ?? CGPoint(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2)
            let (d, g) = try LottieMerge.add(part, to: geom, group: name, origin: o)
            group = g
            return d
        }
        return (group, warnings)
    }

    /// Переставить слой-картинку в геометрии проекта.
    func placeImage(projectID: UUID, layer: String, frame: CGRect) throws {
        guard let p = project(projectID), let geom = geometryData(for: p) else {
            throw LottieImageLayers.ImageError(message: "Project not found")
        }
        setImportedLottie(projectID: projectID, data: try LottieImageLayers.place(layer: layer, in: geom, frame: frame),
                          sourceLabel: p.sourceLabel)
    }

    /// Имя без повторов: "Name", "Name 2", "Name 3"…
    func uniqueName(_ base: String) -> String {
        let names = Set(projects.map(\.name))
        guard names.contains(base) else { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Копия проекта со всеми версиями (новые id).
    @discardableResult
    func duplicate(projectID: UUID) -> AnimationProject? {
        guard let src = project(projectID) else { return nil }
        var copy = AnimationProject(name: uniqueName(src.name + " copy"), hasImportedStatic: src.hasImportedStatic,
                                    layerNames: src.layerNames, sourceLabel: src.sourceLabel)
        if src.hasImportedStatic { try? fm.copyItem(at: staticURL(src.id), to: staticURL(copy.id)) }
        copy.versions = src.versions.map { v in
            var nv = AnimationVersion(index: v.index, prompt: v.prompt, compiledFile: v.compiledFile,
                                      layerCount: v.layerCount, compilerWarnings: v.compilerWarnings, specJSON: v.specJSON,
                                      isFavourite: v.isFavourite, parentVersionID: nil, note: v.note, source: v.source)
            nv.createdAt = v.createdAt
            try? fm.copyItem(at: versionURL(src.id, v.compiledFile), to: versionURL(copy.id, v.compiledFile))
            return nv
        }
        projects.insert(copy, at: 0)
        save(copy)
        return copy
    }

    func rename(projectID: UUID, to newName: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].name = newName
        projects[idx].updatedAt = Date()
        save(projects[idx])
    }

    func delete(projectID: UUID) {
        try? fm.removeItem(at: rootDir.appendingPathComponent(projectID.uuidString, isDirectory: true))
        projects.removeAll { $0.id == projectID }
        diskSignature = currentDiskSignature()
    }

    // MARK: - Persistence

    private func save(_ project: AnimationProject) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(project) {
            try? data.write(to: projectDir(project.id).appendingPathComponent("project.json"), options: .atomic)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
        diskSignature = currentDiskSignature()
    }

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil) else { return }
        var loaded: [AnimationProject] = []
        for dir in entries where dir.hasDirectoryPath {
            let file = dir.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: file), let p = try? decoder.decode(AnimationProject.self, from: data) {
                loaded.append(p)
            }
        }
        projects = loaded.sorted { $0.updatedAt > $1.updatedAt }
        diskSignature = currentDiskSignature()
    }

    // MARK: - Helpers

    func layerNames(from lottieData: Data?) -> [String] {
        guard let lottieData,
              let obj = try? JSONSerialization.jsonObject(with: lottieData) as? [String: Any],
              let layers = obj["layers"] as? [[String: Any]] else { return [] }
        return layers.compactMap { $0["nm"] as? String }
    }
}
#endif
