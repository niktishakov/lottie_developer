import Foundation

/// Импорт пачки ассетов (zip или папка): SVG, PNG/JPEG/WebP/HEIC, Lottie JSON → одна композиция.
/// Правила раскладки (дальше дизайнер/агент правит через place_layer):
/// - холст — по самому большому файлу;
/// - крупные снизу, мелкие сверху (обычно фон/экран снизу, оверлеи сверху);
/// - SVG и Lottie — группой (null-слой с именем файла) по центру холста;
/// - картинки — по центру в натуральном размере; «образцы цвета» ≤ 4 px растягиваются на весь холст и скрываются.
enum AssetBundle {

    struct Report {
        var data: Data
        var canvas: CGSize
        var parts: [String]        // имена групп/слоёв верхнего уровня, сверху вниз
        var warnings: [String]
        /// Какие слои/группы получились из какого файла (имя файла в `copyTo`).
        var usage: [String: [String]] = [:]
    }

    struct BundleError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic"]

    /// - copyTo: если задано, оригиналы использованных файлов копируются туда (папка ассетов проекта).
    static func load(_ url: URL, fps: Int = 60, frames: Int = 120, copyTo: URL? = nil) throws -> Report {
        let fm = FileManager.default
        var dir = url
        var tmp: URL?
        defer { if let tmp { try? fm.removeItem(at: tmp) } }
        if url.pathExtension.lowercased() == "zip" {
            let t = fm.temporaryDirectory.appendingPathComponent("bundle_\(UUID().uuidString)")
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, t.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw BundleError(message: "Cannot unzip \(url.lastPathComponent)") }
            dir = t; tmp = t
        }

        // Файлы и их размеры.
        struct Item { let url: URL; let kind: String; let size: CGSize }
        var items: [Item] = []
        var warnings: [String] = []
        let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let f = en?.nextObject() as? URL {
            if f.path.contains("__MACOSX") { continue }
            let ext = f.pathExtension.lowercased()
            guard let data = try? Data(contentsOf: f) else { continue }
            if ext == "svg" {
                let s = svgSize(data)
                items.append(Item(url: f, kind: "svg", size: s))
            } else if imageExts.contains(ext), let px = LottieImageLayers.pixelSize(data) {
                items.append(Item(url: f, kind: "image", size: CGSize(width: px.width, height: px.height)))
            } else if ext == "json", let s = LottieMerge.size(data) {
                items.append(Item(url: f, kind: "lottie", size: s))
            } else if !f.hasDirectoryPath {
                warnings.append("Skipped \(f.lastPathComponent) (unsupported type)")
            }
        }
        guard !items.isEmpty else { throw BundleError(message: "No SVG, images or Lottie JSON found") }

        let area: (Item) -> Double = { Double($0.size.width * $0.size.height) }
        let canvasItem = items.max { area($0) < area($1) }!
        let canvas = canvasItem.size
        var data = LottieImageLayers.blank(width: Int(canvas.width.rounded()), height: Int(canvas.height.rounded()),
                                           fps: fps, frames: frames)
        var parts: [String] = []
        var swatches: [String] = []
        var usage: [String: [String]] = [:]
        func keep(_ file: URL, _ part: String) {
            guard let copyTo else { return }
            if let name = try? AssetFiles.copy(file, into: copyTo) { usage[name, default: []].append(part) }
        }

        // От крупных к мелким: каждый следующий ложится сверху.
        for item in items.sorted(by: { area($0) > area($1) }) {
            let name = item.url.deletingPathExtension().lastPathComponent
            let raw = try Data(contentsOf: item.url)
            let origin = CGPoint(x: (canvas.width - item.size.width) / 2, y: (canvas.height - item.size.height) / 2)
            switch item.kind {
            case "svg":
                let r = try SVGToLottie.convert(svgData: raw)
                warnings += r.warnings.map { "\(item.url.lastPathComponent): \($0)" }
                let (d, g) = try LottieMerge.add(r.data, to: data, group: name, origin: origin)
                data = d; parts.insert(g, at: 0); keep(item.url, g)
            case "lottie":
                let (d, g) = try LottieMerge.add(raw, to: data, group: name, origin: origin)
                data = d; parts.insert(g, at: 0); keep(item.url, g)
            default:
                if item.size.width <= 4 && item.size.height <= 4 {
                    let (d, l) = try LottieImageLayers.addImage(to: data, image: raw, name: name,
                                                                frame: CGRect(origin: .zero, size: canvas))
                    data = try LottieMerge.reorder(layer: l, in: d, to: Int.max)
                    data = LottieOverrides.apply([l: LayerOverride(hidden: true)], to: data)
                    swatches.append(l)
                    parts.append(l); keep(item.url, l)
                } else {
                    let (d, l) = try LottieImageLayers.addImage(to: data, image: raw, name: name, frame: nil)
                    data = d; parts.insert(l, at: 0); keep(item.url, l)
                }
            }
        }
        if !swatches.isEmpty {
            warnings.append("Tiny images treated as color swatches: \(swatches.joined(separator: ", ")) — stretched to the canvas, at the bottom, hidden")
        }
        return Report(data: data, canvas: canvas, parts: parts, warnings: warnings, usage: usage)
    }

    private static func svgSize(_ data: Data) -> CGSize {
        guard let root = SVGDocument.parse(data) else { return CGSize(width: 512, height: 512) }
        if let vb = root.attrs["viewBox"]?.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap({ Double($0) }), vb.count == 4 {
            return CGSize(width: vb[2], height: vb[3])
        }
        let num: (String?) -> Double? = { $0.flatMap { Double($0.filter { "0123456789.".contains($0) }) } }
        return CGSize(width: num(root.attrs["width"]) ?? 512, height: num(root.attrs["height"]) ?? 512)
    }
}
