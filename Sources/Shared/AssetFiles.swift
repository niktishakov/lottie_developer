import Foundation
#if os(iOS)
import ZIPFoundation
#endif

/// Файлы-оригиналы ассетов проекта (папка `assets/`): их видят дизайнер (вкладка Assets, Finder) и Claude (MCP).
/// Рядом — скрытый `.usage.json`: какие слои сцены сделаны из какого файла.
enum AssetFiles {

    static let supported: Set<String> = ["svg", "png", "jpg", "jpeg", "webp", "heic", "json"]
    static let indexName = ".usage.json"

    struct Item: Identifiable, Hashable {
        let url: URL
        let bytes: Int
        let modified: Date
        var id: String { url.lastPathComponent }
        var name: String { url.lastPathComponent }
        var kind: String {
            switch url.pathExtension.lowercased() {
            case "svg": return "svg"
            case "json": return "lottie"
            default: return "image"
            }
        }
    }

    static func list(_ dir: URL) -> [Item] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { supported.contains($0.pathExtension.lowercased()) }.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return Item(url: u, bytes: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? Date())
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Скопировать файл в папку (без перезаписи: "name 2.png"). Возвращает итоговое имя.
    @discardableResult
    static func copy(_ src: URL, into dir: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
        var dst = dir.appendingPathComponent(src.lastPathComponent)
        // Тот же файл уже лежит — не плодим копии.
        if fm.fileExists(atPath: dst.path), fm.contentsEqual(atPath: dst.path, andPath: src.path) { return dst.lastPathComponent }
        var i = 2
        while fm.fileExists(atPath: dst.path) {
            dst = dir.appendingPathComponent("\(base) \(i)" + (ext.isEmpty ? "" : ".\(ext)")); i += 1
        }
        try fm.copyItem(at: src, to: dst)
        return dst.lastPathComponent
    }

    /// Добавить файлы и/или zip в папку. zip распаковывается (без __MACOSX). Возвращает имена добавленных файлов.
    static func add(_ urls: [URL], into dir: URL) throws -> [String] {
        let fm = FileManager.default
        var added: [String] = []
        for url in urls {
            if url.pathExtension.lowercased() == "zip" || url.hasDirectoryPath {
                var src = url
                var tmp: URL?
                if url.pathExtension.lowercased() == "zip" {
                    let t = fm.temporaryDirectory.appendingPathComponent("assets_\(UUID().uuidString)")
                    try fm.createDirectory(at: t, withIntermediateDirectories: true)
                    try unzip(url, to: t)
                    src = t; tmp = t
                }
                defer { if let tmp { try? fm.removeItem(at: tmp) } }
                let en = fm.enumerator(at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = en?.nextObject() as? URL {
                    if f.path.contains("__MACOSX") || !supported.contains(f.pathExtension.lowercased()) { continue }
                    added.append(try copy(f, into: dir))
                }
            } else if supported.contains(url.pathExtension.lowercased()) {
                added.append(try copy(url, into: dir))
            }
        }
        return added
    }

    struct ZipError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Распаковать zip в папку (macOS — ditto, iOS — ZIPFoundation).
    static func unzip(_ zip: URL, to dir: URL) throws {
        #if os(iOS)
        do { try FileManager.default.unzipItem(at: zip, to: dir) }
        catch { throw ZipError(message: "Cannot unzip \(zip.lastPathComponent): \(error.localizedDescription)") }
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ZipError(message: "Cannot unzip \(zip.lastPathComponent)") }
        #endif
    }

    // MARK: - Usage index

    static func usage(_ dir: URL) -> [String: [String]] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(indexName)),
              let u = try? JSONDecoder().decode([String: [String]].self, from: d) else { return [:] }
        return u
    }

    static func setUsage(_ u: [String: [String]], _ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(u.filter { !$0.value.isEmpty }) { try? d.write(to: dir.appendingPathComponent(indexName), options: .atomic) }
    }

    static func recordUsage(file: String, layer: String, _ dir: URL) {
        var u = usage(dir)
        if !(u[file] ?? []).contains(layer) { u[file, default: []].append(layer) }
        setUsage(u, dir)
    }
}
