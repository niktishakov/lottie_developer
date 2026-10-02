#if os(macOS) || os(iOS)
import Foundation
import CoreGraphics

/// Конвертер SVG → статичный Lottie (bodymovin) с ИМЕНОВАННЫМИ слоями.
/// Каждый рисуемый элемент → отдельный слой `ty:4` с `nm` = svg `id` (или сгенерированное имя),
/// якорь слоя в центре bbox (чтобы scale/rotate/spin крутились вокруг центра фигуры).
/// MVP: rect, circle, ellipse, line, polygon, polyline, path (M/L/H/V/C/S/Z, abs+rel).
/// Solid fill/stroke. Не поддержано: arcs(A), quadratic(Q), per-element transform, gradients — помечается как лимит.
enum SVGToLottie {

    enum SVGError: LocalizedError {
        case parseFailed
        case noDrawables
        var errorDescription: String? {
            switch self {
            case .parseFailed: return "Could not parse the SVG"
            case .noDrawables: return "No supported shapes found in the SVG (rect/circle/ellipse/line/polygon/polyline/path)"
            }
        }
    }

    struct Result {
        let data: Data
        let layerNames: [String]
        let warnings: [String]
    }

    /// Человекочитаемое имя из SVG: <title>, иначе id корневого <svg>.
    static func title(svgData: Data) -> String? {
        guard let text = String(data: svgData, encoding: .utf8) else { return nil }
        func first(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            let v = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : String(v.prefix(60))
        }
        return first("<title[^>]*>(.*?)</title>") ?? first("<svg[^>]*?\\sid=\"([^\"]+)\"")
    }

    /// Контекст конвертации: градиенты из defs и узлы, которые рисуем картинкой.
    struct Context {
        var gradients: [String: Gradient] = [:]
        var rasterNodes: [SVGNode] = []
        var root: SVGNode?
        var canvas = CGSize(width: 512, height: 512)
        var assets: [[String: Any]] = []
        /// Растеризатор узла: (индекс узла, изолированный SVG, холст, масштаб) → картинка.
        var rasterize: (Int, Data, CGSize, Double) -> CGImage? = { _, _, _, _ in nil }
    }

    /// Масштаб растеризации узлов, которые Lottie не нарисует.
    static let rasterScale = 3.0

    /// Синхронная конвертация. macOS: растеризация через CoreSVG. iOS: без WebKit узлы-картинки
    /// пропускаются — используйте `convertAsync`.
    static func convert(svgData: Data) throws -> Result {
        #if os(macOS)
        return try convert(svgData: svgData) { _, doc, canvas, scale in SVGDocument.rasterize(doc, canvas: canvas, scale: scale) }
        #else
        return try convert(svgData: svgData) { _, _, _, _ in nil }
        #endif
    }

    /// Асинхронная конвертация: на iOS сначала рисует растровые узлы через WKWebView, потом та же конвертация.
    @MainActor
    static func convertAsync(svgData: Data) async throws -> Result {
        #if os(iOS)
        let prep = try prepare(svgData)
        var images: [Int: CGImage] = [:]
        if let root = prep.ctx.root {
            for (i, node) in prep.ctx.rasterNodes.enumerated() {
                let doc = SVGDocument.isolate(node, root: root)
                images[i] = await SVGDocument.rasterizeAsync(doc, canvas: prep.ctx.canvas, scale: rasterScale)
            }
        }
        return try convert(svgData: svgData) { i, _, _, _ in images[i] }
        #else
        return try convert(svgData: svgData)
        #endif
    }

    private static func prepare(_ svgData: Data) throws -> (ctx: Context, collector: Collector) {
        guard let dom = SVGDocument.parse(svgData) else { throw SVGError.parseFailed }
        var ctx = Context()
        ctx.root = dom
        ctx.gradients = collectGradients(dom)
        let gradients = ctx.gradients
        let needsRaster: ([String: String]) -> Bool = { needsRasterization($0, gradients: gradients) }
        ctx.rasterNodes = SVGDocument.rasterNodes(dom) { needsRaster($0.attrs) }

        let parser = XMLParser(data: svgData)
        let collector = Collector(needsRaster: needsRaster)
        parser.delegate = collector
        guard parser.parse() else { throw SVGError.parseFailed }
        guard !collector.elements.isEmpty else { throw SVGError.noDrawables }

        let (w, h) = collector.size()
        ctx.canvas = CGSize(width: w, height: h)
        return (ctx, collector)
    }

    static func convert(svgData: Data, rasterizer: @escaping (Int, Data, CGSize, Double) -> CGImage?) throws -> Result {
        let prep = try prepare(svgData)
        var ctx = prep.ctx
        let collector = prep.collector
        ctx.rasterize = rasterizer
        let (w, h) = (Double(ctx.canvas.width), Double(ctx.canvas.height))
        var warnings = collector.warnings
        if !ctx.rasterNodes.isEmpty {
            warnings.append("\(ctx.rasterNodes.count) element(s) with blur/mask/complex gradient imported as images (exact look, transform-only animation)")
        }

        // SVG рисует в порядке документа (последний — сверху). В Lottie layers[0] — сверху.
        // Реверсируем, чтобы z-порядок совпал.
        var layers: [[String: Any]] = []
        var names: [String] = []
        var ind = 1
        for element in collector.elements.reversed() {
            guard let layer = makeLayer(from: element, ind: ind, ctx: &ctx, warnings: &warnings) else { continue }
            layers.append(layer)
            names.append(element.name)
            ind += 1
        }
        // names в порядке слоёв (top→bottom); для AI вернём в исходном документ-порядке для читабельности
        names.reverse()

        guard !layers.isEmpty else { throw SVGError.noDrawables }

        let bbox = layersBoundingBox(layers)
        let compW = Int(ceil(max(w, bbox.maxX)))
        let compH = Int(ceil(max(h, bbox.maxY)))

        let root: [String: Any] = [
            "v": "5.7.0", "fr": 60, "ip": 0, "op": 1,
            "w": compW, "h": compH,
            "nm": "SVG Import", "ddd": 0, "assets": ctx.assets, "layers": layers,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return Result(data: data, layerNames: names, warnings: warnings)
    }

    // MARK: - Collected element

    struct Element {
        let tag: String
        let attrs: [String: String]
        let name: String
    }

    // MARK: - XML collector

    final class Collector: NSObject, XMLParserDelegate {
        private(set) var elements: [Element] = []
        private let needsRaster: ([String: String]) -> Bool
        private var rasterDepth = 0
        private var rasterCount = 0

        init(needsRaster: @escaping ([String: String]) -> Bool = { _ in false }) {
            self.needsRaster = needsRaster
        }
        private(set) var warnings: [String] = []
        private var svgAttrs: [String: String] = [:]
        private var groupIdStack: [String] = []
        private var counter = 0
        private let drawable: Set<String> = ["rect", "circle", "ellipse", "line", "polygon", "polyline", "path"]
        // Содержимое этих контейнеров не рисуется напрямую (определения для clip/mask/и т.п.).
        // Без пропуска <rect> внутри <clipPath> становится видимым прямоугольником во весь холст.
        private let nonRendered: Set<String> = SVGDocument.nonRendered
        private var skipDepth = 0
        private var sawUnsupportedTransform = false

        func size() -> (Double, Double) {
            if let vb = svgAttrs["viewBox"]?.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap({ Double($0) }),
               vb.count == 4 {
                return (vb[2], vb[3])
            }
            let w = svgAttrs["width"].flatMap { Double($0.filter { "0123456789.".contains($0) }) } ?? 512
            let h = svgAttrs["height"].flatMap { Double($0.filter { "0123456789.".contains($0) }) } ?? 512
            return (w, h)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let tag = elementName.lowercased()
            if tag == "svg" { svgAttrs = attributeDict }
            if nonRendered.contains(tag) { skipDepth += 1; return }
            if skipDepth > 0 { return } // внутри defs/clipPath/mask — ничего не собираем
            if rasterDepth > 0 { rasterDepth += 1; return } // внутри растеризуемого узла
            if tag != "svg", needsRaster(attributeDict) {
                // Порядок совпадает с SVGDocument.rasterNodes (тот же обход документа).
                counter += 1
                let name = layerName(forID: attributeDict["id"], tag: tag == "g" ? "group" : tag, ordinal: counter)
                elements.append(Element(tag: "__raster", attrs: ["index": String(rasterCount)], name: name))
                rasterCount += 1
                rasterDepth = 1
                return
            }
            if tag == "g" {
                groupIdStack.append(attributeDict["id"] ?? "")
                if attributeDict["transform"] != nil { sawUnsupportedTransform = true }
                return
            }
            guard drawable.contains(tag) else { return }
            if attributeDict["transform"] != nil { sawUnsupportedTransform = true }
            counter += 1
            let name = layerName(forID: attributeDict["id"], tag: tag, ordinal: counter)
            elements.append(Element(tag: tag, attrs: attributeDict, name: name))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let tag = elementName.lowercased()
            if nonRendered.contains(tag) { skipDepth = max(0, skipDepth - 1); return }
            if skipDepth > 0 { return }
            if rasterDepth > 0 { rasterDepth -= 1; return }
            if tag == "g", !groupIdStack.isEmpty { groupIdStack.removeLast() }
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            if sawUnsupportedTransform {
                warnings.append("Some elements use SVG transforms (not applied) — geometry may differ")
            }
        }

        private func layerName(forID id: String?, tag: String, ordinal: Int) -> String {
            if let id, !id.isEmpty { return id }
            if let group = groupIdStack.last(where: { !$0.isEmpty }) { return "\(group)-\(tag)-\(ordinal)" }
            return "\(tag)-\(ordinal)"
        }
    }

    // MARK: - Layer construction

    private static func makeLayer(from element: Element, ind: Int, ctx: inout Context, warnings: inout [String]) -> [String: Any]? {
        if element.tag == "__raster" { return rasterLayer(element, ind: ind, ctx: &ctx) }
        var shapeItems: [[String: Any]] = []
        var bbox: BBox? = nil

        switch element.tag {
        case "rect":
            let x = num(element.attrs["x"]) ?? 0, y = num(element.attrs["y"]) ?? 0
            let w = num(element.attrs["width"]) ?? 0, h = num(element.attrs["height"]) ?? 0
            guard w > 0, h > 0 else { return nil }
            let rx = num(element.attrs["rx"]) ?? 0
            let cx = x + w / 2, cy = y + h / 2
            shapeItems.append(["ty": "rc", "p": kStatic([cx, cy]), "s": kStatic([w, h]), "r": kScalar(rx), "nm": "rect", "hd": false])
            bbox = BBox(minX: x, minY: y, maxX: x + w, maxY: y + h)
        case "circle":
            let cx = num(element.attrs["cx"]) ?? 0, cy = num(element.attrs["cy"]) ?? 0, r = num(element.attrs["r"]) ?? 0
            guard r > 0 else { return nil }
            shapeItems.append(["ty": "el", "p": kStatic([cx, cy]), "s": kStatic([r * 2, r * 2]), "nm": "ellipse", "hd": false])
            bbox = BBox(minX: cx - r, minY: cy - r, maxX: cx + r, maxY: cy + r)
        case "ellipse":
            let cx = num(element.attrs["cx"]) ?? 0, cy = num(element.attrs["cy"]) ?? 0
            let rx = num(element.attrs["rx"]) ?? 0, ry = num(element.attrs["ry"]) ?? 0
            guard rx > 0, ry > 0 else { return nil }
            shapeItems.append(["ty": "el", "p": kStatic([cx, cy]), "s": kStatic([rx * 2, ry * 2]), "nm": "ellipse", "hd": false])
            bbox = BBox(minX: cx - rx, minY: cy - ry, maxX: cx + rx, maxY: cy + ry)
        case "line":
            let x1 = num(element.attrs["x1"]) ?? 0, y1 = num(element.attrs["y1"]) ?? 0
            let x2 = num(element.attrs["x2"]) ?? 0, y2 = num(element.attrs["y2"]) ?? 0
            shapeItems.append(shFromVertices([[x1, y1], [x2, y2]], closed: false))
            bbox = BBox.of([[x1, y1], [x2, y2]])
        case "polygon", "polyline":
            let pts = points(element.attrs["points"])
            guard pts.count >= 2 else { return nil }
            shapeItems.append(shFromVertices(pts, closed: element.tag == "polygon"))
            bbox = BBox.of(pts)
        case "path":
            let parsed = SVGPath.parse(element.attrs["d"] ?? "")
            guard !parsed.subpaths.isEmpty else { return nil }
            if parsed.approximated {
                let msg = "Some paths use arcs (A) — approximated with line segments"
                if !warnings.contains(msg) { warnings.append(msg) }
            }
            var allV: [[Double]] = []
            for sp in parsed.subpaths {
                shapeItems.append(shFromBezier(sp))
                allV.append(contentsOf: sp.v)
            }
            bbox = BBox.of(allV)
        default:
            return nil
        }

        guard let bbox else { return nil }

        // element-level opacity: opacity="0" → невидимый элемент. Частый артефакт SF Symbols /
        // Apple CoreSVG — прозрачный bounding-box <rect opacity="0">. Без этого он становится
        // сплошным чёрным прямоугольником во весь холст и перекрывает весь рисунок.
        let elementOpacity = num(element.attrs["opacity"]) ?? styleNum(element.attrs["style"], "opacity") ?? 1
        guard elementOpacity > 0.001 else { return nil }

        // fill / stroke (+ fill-opacity / stroke-opacity → альфа цвета)
        let fillOpacity = num(element.attrs["fill-opacity"]) ?? styleNum(element.attrs["style"], "fill-opacity") ?? 1
        let strokeOpacity = num(element.attrs["stroke-opacity"]) ?? styleNum(element.attrs["style"], "stroke-opacity") ?? 1
        var fill = color(element.attrs["fill"], style: element.attrs["style"], key: "fill")
        var stroke = color(element.attrs["stroke"], style: element.attrs["style"], key: "stroke")
        fill?[3] *= fillOpacity
        stroke?[3] *= strokeOpacity
        let strokeWidth = num(element.attrs["stroke-width"]) ?? styleNum(element.attrs["style"], "stroke-width") ?? 1

        let fillGradient = gradientRef(element.attrs["fill"] ?? styleValue(element.attrs["style"], "fill")).flatMap { ctx.gradients[$0] }
        let strokeGradient = gradientRef(element.attrs["stroke"] ?? styleValue(element.attrs["style"], "stroke")).flatMap { ctx.gradients[$0] }
        if fillGradient != nil { fill = nil }
        if strokeGradient != nil { stroke = nil }

        if let g = strokeGradient, let item = gradientItem(g, bbox: bbox, opacity: strokeOpacity, strokeWidth: strokeWidth) {
            shapeItems.append(item)
        } else if let stroke {
            shapeItems.append(strokeItem(color: stroke, width: strokeWidth))
        }
        if let g = fillGradient, let item = gradientItem(g, bbox: bbox, opacity: fillOpacity, strokeWidth: nil) {
            shapeItems.append(item)
        } else if let fill {
            shapeItems.append(fillItem(color: fill))
        } else if stroke == nil && strokeGradient == nil {
            // нет ни fill, ни stroke → дефолтный чёрный fill (как SVG)
            shapeItems.append(fillItem(color: [0, 0, 0, 1]))
        }
        shapeItems.append(groupTransform())

        let group: [String: Any] = [
            "ty": "gr", "it": shapeItems, "nm": "Group", "np": shapeItems.count,
            "cix": 2, "bm": 0, "ix": 1, "mn": "ADBE Vector Group", "hd": false,
        ]

        let center = bbox.center
        return [
            "ddd": 0, "ind": ind, "ty": 4, "nm": element.name, "sr": 1,
            "ks": [
                "o": kScalar(elementOpacity * 100, ix: 11),
                "r": kScalar(0, ix: 10),
                "p": kStatic([center.x, center.y, 0], ix: 2),
                "a": kStatic([center.x, center.y, 0], ix: 1),
                "s": kStatic([100, 100, 100], ix: 6),
            ],
            "ao": 0, "shapes": [group], "ip": 0, "op": 1, "st": 0, "bm": 0,
        ]
    }

    // MARK: - Raster fallback

    /// Элемент, который Lottie не нарисует (blur, маска, вытянутый radial gradient): рисуем системным
    /// SVG-рендерером в картинку ×3 и ставим слоем-картинкой на то же место.
    private static func rasterLayer(_ element: Element, ind: Int, ctx: inout Context) -> [String: Any]? {
        guard let i = Int(element.attrs["index"] ?? ""), i < ctx.rasterNodes.count, let root = ctx.root else { return nil }
        let scale = rasterScale
        let doc = SVGDocument.isolate(ctx.rasterNodes[i], root: root)
        guard let img = ctx.rasterize(i, doc, ctx.canvas, scale),
              let (png, rect) = SVGDocument.cropToContent(img, scale: scale),
              let px = LottieImageLayers.pixelSize(png) else { return nil }
        let id = "svg_raster_\(ctx.assets.count + 1)"
        ctx.assets.append(LottieImageLayers.asset(id: id, image: png, px: px))
        return LottieImageLayers.layer(name: element.name, assetID: id, px: px, rect: rect, ind: ind, op: 1)
    }

    // MARK: - Gradients

    struct Gradient {
        var radial: Bool
        var attrs: [String: String]
        var stops: [(offset: Double, color: [Double])]
    }

    static func collectGradients(_ root: SVGNode) -> [String: Gradient] {
        var raw: [String: SVGNode] = [:]
        func walk(_ n: SVGNode) {
            let t = n.tag.lowercased()
            if (t == "lineargradient" || t == "radialgradient"), let id = n.attrs["id"] { raw[id] = n }
            n.children.forEach(walk)
        }
        walk(root)
        var out: [String: Gradient] = [:]
        for (id, n) in raw {
            var attrs = n.attrs
            var stopsNode = n
            // xlink:href / href — наследование стопов и атрибутов
            var hops = 0
            while stopsNode.children.isEmpty, hops < 5,
                  let href = (stopsNode.attrs["xlink:href"] ?? stopsNode.attrs["href"])?.replacingOccurrences(of: "#", with: ""),
                  let parent = raw[href] {
                for (k, v) in parent.attrs where attrs[k] == nil { attrs[k] = v }
                stopsNode = parent; hops += 1
            }
            let stops: [(Double, [Double])] = stopsNode.children.filter { $0.tag.lowercased() == "stop" }.map { st in
                let offRaw = st.attrs["offset"] ?? styleValue(st.attrs["style"], "offset") ?? "0"
                var off = num(offRaw) ?? 0
                if offRaw.contains("%") { off /= 100 }
                var c = color(st.attrs["stop-color"], style: st.attrs["style"], key: "stop-color") ?? [0, 0, 0, 1]
                c[3] *= num(st.attrs["stop-opacity"]) ?? styleNum(st.attrs["style"], "stop-opacity") ?? 1
                return (min(max(off, 0), 1), c)
            }
            guard !stops.isEmpty else { continue }
            out[id] = Gradient(radial: n.tag.lowercased() == "radialgradient", attrs: attrs, stops: stops)
        }
        return out
    }

    private static func gradientRef(_ v: String?) -> String? {
        guard let v, let r = v.range(of: "url(#") else { return nil }
        let rest = v[r.upperBound...]
        guard let end = rest.firstIndex(of: ")") else { return nil }
        return String(rest[..<end])
    }

    /// blur / маска / вытянутый radial gradient (Lottie рисует только круглые) → картинка.
    static func needsRasterization(_ attrs: [String: String], gradients: [String: Gradient]) -> Bool {
        for key in ["filter", "mask"] {
            if let v = attrs[key] ?? styleValue(attrs["style"], key), v != "none", !v.isEmpty { return true }
        }
        for key in ["fill", "stroke"] {
            if let id = gradientRef(attrs[key] ?? styleValue(attrs["style"], key)), let g = gradients[id], g.radial,
               radialAnisotropy(g) > 1.5 { return true }
        }
        return false
    }

    private static func radialAnisotropy(_ g: Gradient) -> Double {
        let t = transform(g.attrs["gradientTransform"])
        let a = CGPoint(x: 1, y: 0).applying(t), b = CGPoint(x: 0, y: 1).applying(t), o = CGPoint.zero.applying(t)
        let rx = hypot(a.x - o.x, a.y - o.y), ry = hypot(b.x - o.x, b.y - o.y)
        return max(rx, ry) / max(min(rx, ry), 0.0001)
    }

    private static func gradientItem(_ g: Gradient, bbox: BBox, opacity: Double, strokeWidth: Double?) -> [String: Any]? {
        let objectBox = (g.attrs["gradientUnits"] ?? "objectBoundingBox") != "userSpaceOnUse"
        let t = transform(g.attrs["gradientTransform"])
        func coord(_ key: String, _ def: Double, horizontal: Bool) -> Double {
            guard let raw = g.attrs[key], var v = num(raw) else { return def }
            if raw.contains("%") { v /= 100 }
            return v
        }
        func map(_ p: CGPoint) -> [Double] {
            let q = p.applying(t)
            if objectBox {
                let w = bbox.maxX - bbox.minX, h = bbox.maxY - bbox.minY
                return [bbox.minX + Double(q.x) * w, bbox.minY + Double(q.y) * h]
            }
            return [Double(q.x), Double(q.y)]
        }
        let start: [Double], end: [Double]
        if g.radial {
            let cx = coord("cx", 0.5, horizontal: true), cy = coord("cy", 0.5, horizontal: false), r = coord("r", 0.5, horizontal: true)
            start = map(CGPoint(x: cx, y: cy)); end = map(CGPoint(x: cx + r, y: cy))
        } else {
            start = map(CGPoint(x: coord("x1", 0, horizontal: true), y: coord("y1", 0, horizontal: false)))
            end = map(CGPoint(x: coord("x2", 1, horizontal: true), y: coord("y2", 0, horizontal: false)))
        }
        let stops = g.stops.sorted { $0.offset < $1.offset }
        var k: [Double] = []
        for st in stops { k += [st.offset, st.color[0], st.color[1], st.color[2]] }
        for st in stops { k += [st.offset, st.color[3]] }
        var item: [String: Any] = [
            "ty": strokeWidth == nil ? "gf" : "gs", "o": kScalar(opacity * 100), "bm": 0, "r": 1,
            "g": ["p": stops.count, "k": ["a": 0, "k": k]],
            "s": kStatic(start), "e": kStatic(end), "t": g.radial ? 2 : 1,
            "nm": "Gradient", "hd": false,
        ]
        if g.radial { item["h"] = kScalar(0); item["a"] = kScalar(0) }
        if let w = strokeWidth { item["w"] = kScalar(w); item["lc"] = 2; item["lj"] = 2; item["ml"] = 4 }
        return item
    }

    /// SVG transform-лист → аффинная матрица (matrix, translate, scale, rotate).
    static func transform(_ s: String?) -> CGAffineTransform {
        guard let s else { return .identity }
        var total = CGAffineTransform.identity
        let re = try! NSRegularExpression(pattern: "(matrix|translate|scale|rotate)\\s*\\(([^)]*)\\)")
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let fr = Range(m.range(at: 1), in: s), let ar = Range(m.range(at: 2), in: s) else { continue }
            let args = s[ar].split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            var t = CGAffineTransform.identity
            switch s[fr] {
            case "matrix" where args.count == 6: t = CGAffineTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case "translate": t = CGAffineTransform(translationX: args.first ?? 0, y: args.count > 1 ? args[1] : 0)
            case "scale": t = CGAffineTransform(scaleX: args.first ?? 1, y: args.count > 1 ? args[1] : (args.first ?? 1))
            case "rotate":
                let a = (args.first ?? 0) * .pi / 180
                if args.count == 3 {
                    t = CGAffineTransform(translationX: args[1], y: args[2]).rotated(by: a).translatedBy(x: -args[1], y: -args[2])
                } else { t = CGAffineTransform(rotationAngle: a) }
            default: break
            }
            total = t.concatenating(total)
        }
        return total
    }

    // MARK: - Lottie shape helpers

    private static func kStatic(_ v: [Double], ix: Int? = nil) -> [String: Any] {
        var d: [String: Any] = ["a": 0, "k": v]; if let ix { d["ix"] = ix }; return d
    }
    private static func kScalar(_ v: Double, ix: Int? = nil) -> [String: Any] {
        var d: [String: Any] = ["a": 0, "k": v]; if let ix { d["ix"] = ix }; return d
    }

    private static func shFromVertices(_ verts: [[Double]], closed: Bool) -> [String: Any] {
        let zeros = verts.map { _ in [0.0, 0.0] }
        return ["ty": "sh", "ix": 1, "nm": "Path",
                "ks": ["a": 0, "k": ["i": zeros, "o": zeros, "v": verts, "c": closed]],
                "mn": "ADBE Vector Shape - Group", "hd": false]
    }

    private static func shFromBezier(_ sp: SVGPath.Subpath) -> [String: Any] {
        return ["ty": "sh", "ix": 1, "nm": "Path",
                "ks": ["a": 0, "k": ["i": sp.i, "o": sp.o, "v": sp.v, "c": sp.closed]],
                "mn": "ADBE Vector Shape - Group", "hd": false]
    }

    private static func fillItem(color: [Double]) -> [String: Any] {
        ["ty": "fl", "c": kStatic([color[0], color[1], color[2]]), "o": kScalar(color[3] * 100),
         "r": 1, "bm": 0, "nm": "Fill", "mn": "ADBE Vector Graphic - Fill", "hd": false]
    }

    private static func strokeItem(color: [Double], width: Double) -> [String: Any] {
        ["ty": "st", "c": kStatic([color[0], color[1], color[2]]), "o": kScalar(color[3] * 100),
         "w": kScalar(width), "lc": 2, "lj": 2, "ml": 4, "bm": 0,
         "nm": "Stroke", "mn": "ADBE Vector Graphic - Stroke", "hd": false]
    }

    private static func groupTransform() -> [String: Any] {
        ["ty": "tr", "p": kStatic([0, 0]), "a": kStatic([0, 0]), "s": kStatic([100, 100]),
         "r": kScalar(0), "o": kScalar(100), "sk": kScalar(0), "sa": kScalar(0), "nm": "Transform"]
    }

    // MARK: - parsing utils

    private static func num(_ s: String?) -> Double? {
        guard let s else { return nil }
        return Double(s.trimmingCharacters(in: .whitespaces).filter { "0123456789.eE+-".contains($0) })
    }

    private static func points(_ s: String?) -> [[Double]] {
        guard let s else { return [] }
        let nums = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).compactMap { Double($0) }
        var pts: [[Double]] = []
        var i = 0
        while i + 1 < nums.count { pts.append([nums[i], nums[i + 1]]); i += 2 }
        return pts
    }

    private static func styleNum(_ style: String?, _ key: String) -> Double? {
        guard let v = styleValue(style, key) else { return nil }
        return num(v)
    }

    private static func styleValue(_ style: String?, _ key: String) -> String? {
        guard let style else { return nil }
        for pair in style.split(separator: ";") {
            let kv = pair.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == key {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// → [r,g,b,a] 0..1, или nil если none/отсутствует.
    private static func color(_ attr: String?, style: String?, key: String) -> [Double]? {
        let raw = (attr ?? styleValue(style, key))?.trimmingCharacters(in: .whitespaces).lowercased()
        guard let raw, raw != "none", !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") { return hexColor(raw) }
        switch raw {
        case "black": return [0, 0, 0, 1]
        case "white": return [1, 1, 1, 1]
        case "red": return [1, 0, 0, 1]
        case "green": return [0, 0.5, 0, 1]
        case "blue": return [0, 0, 1, 1]
        case "gray", "grey": return [0.5, 0.5, 0.5, 1]
        case "yellow": return [1, 1, 0, 1]
        case "orange": return [1, 0.65, 0, 1]
        default:
            if raw.hasPrefix("rgb") { return rgbColor(raw) }
            return [0, 0, 0, 1] // неизвестный цвет → чёрный
        }
    }

    private static func hexColor(_ hex: String) -> [Double] {
        var h = hex.replacingOccurrences(of: "#", with: "")
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return [0, 0, 0, 1] }
        return [Double((v >> 16) & 0xFF) / 255.0, Double((v >> 8) & 0xFF) / 255.0, Double(v & 0xFF) / 255.0, 1]
    }

    private static func rgbColor(_ s: String) -> [Double] {
        let nums = s.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard nums.count >= 3 else { return [0, 0, 0, 1] }
        return [nums[0] / 255.0, nums[1] / 255.0, nums[2] / 255.0, nums.count >= 4 ? nums[3] : 1]
    }

    // MARK: - bbox

    struct BBox {
        var minX, minY, maxX, maxY: Double
        var center: (x: Double, y: Double) { ((minX + maxX) / 2, (minY + maxY) / 2) }
        static func of(_ verts: [[Double]]) -> BBox? {
            guard let first = verts.first, first.count >= 2 else { return nil }
            var b = BBox(minX: first[0], minY: first[1], maxX: first[0], maxY: first[1])
            for v in verts where v.count >= 2 {
                b.minX = Swift.min(b.minX, v[0]); b.minY = Swift.min(b.minY, v[1])
                b.maxX = Swift.max(b.maxX, v[0]); b.maxY = Swift.max(b.maxY, v[1])
            }
            return b
        }
    }

    private static func layersBoundingBox(_ layers: [[String: Any]]) -> BBox {
        var result = BBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
        for layer in layers {
            let ks = layer["ks"] as? [String: Any] ?? [:]
            let pos = (ks["p"] as? [String: Any])?["k"] as? [Any] ?? []
            let anc = (ks["a"] as? [String: Any])?["k"] as? [Any] ?? []
            let px = (pos.count > 0 ? (pos[0] as? NSNumber)?.doubleValue : nil) ?? 0
            let py = (pos.count > 1 ? (pos[1] as? NSNumber)?.doubleValue : nil) ?? 0
            let ax = (anc.count > 0 ? (anc[0] as? NSNumber)?.doubleValue : nil) ?? 0
            let ay = (anc.count > 1 ? (anc[1] as? NSNumber)?.doubleValue : nil) ?? 0
            let ox = px - ax
            let oy = py - ay
            for shape in layer["shapes"] as? [[String: Any]] ?? [] {
                collectBounds(shape, ox: ox, oy: oy, bbox: &result)
            }
        }
        return result
    }

    private static func collectBounds(_ shape: [String: Any], ox: Double, oy: Double, bbox: inout BBox) {
        let ty = shape["ty"] as? String
        if ty == "sh" {
            if let ks = shape["ks"] as? [String: Any],
               let k = ks["k"] as? [String: Any],
               let verts = k["v"] as? [[Any]] {
                for v in verts where v.count >= 2 {
                    let x = ox + ((v[0] as? NSNumber)?.doubleValue ?? 0)
                    let y = oy + ((v[1] as? NSNumber)?.doubleValue ?? 0)
                    bbox.maxX = Swift.max(bbox.maxX, x)
                    bbox.maxY = Swift.max(bbox.maxY, y)
                }
            }
        } else if ty == "gr" {
            for item in shape["it"] as? [[String: Any]] ?? [] {
                collectBounds(item, ox: ox, oy: oy, bbox: &bbox)
            }
        }
    }
}

// MARK: - SVG path parser (port of bin/convert_svg_to_lottie.js)

enum SVGPath {
    struct Subpath { var v: [[Double]]; var i: [[Double]]; var o: [[Double]]; var closed: Bool }
    struct ParseResult { var subpaths: [Subpath]; var approximated: Bool }

    static func parse(_ d: String) -> ParseResult {
        let tokens = tokenize(d)
        var subpaths: [Subpath] = []
        var cur: Subpath? = nil
        var x = 0.0, y = 0.0
        var idx = 0
        var lastCmd: Character = " "
        var prevUpper: Character = " "          // команда предыдущего сегмента (для отражения S/T)
        var prevCtrlX = 0.0, prevCtrlY = 0.0   // последняя control-точка кубической (для S)
        var prevQuadX = 0.0, prevQuadY = 0.0   // последняя control-точка квадратичной (для T)
        var approximated = false

        // Bounds-safe: не выходим за пределы массива токенов (иначе trap → краш приложения).
        func num() -> Double { guard idx < tokens.count else { return 0 }; let v = Double(tokens[idx]) ?? 0; idx += 1; return v }
        func isNum() -> Bool { idx < tokens.count && Double(tokens[idx]) != nil }

        func newSub(_ px: Double, _ py: Double) {
            if let c = cur { subpaths.append(c) }
            cur = Subpath(v: [[px, py]], i: [[0, 0]], o: [[0, 0]], closed: false)
        }
        func addCurve(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double, _ ex: Double, _ ey: Double) {
            guard cur != nil else { return }
            cur!.o[cur!.o.count - 1] = [c1x - x, c1y - y]
            x = ex; y = ey
            cur!.v.append([x, y]); cur!.i.append([c2x - x, c2y - y]); cur!.o.append([0, 0])
            prevCtrlX = c2x; prevCtrlY = c2y
        }
        // Квадратичная (control Q, конец E) → кубическая (точная конверсия).
        func addQuad(_ qx: Double, _ qy: Double, _ ex: Double, _ ey: Double) {
            let c1x = x + 2.0 / 3.0 * (qx - x), c1y = y + 2.0 / 3.0 * (qy - y)
            let c2x = ex + 2.0 / 3.0 * (qx - ex), c2y = ey + 2.0 / 3.0 * (qy - ey)
            prevQuadX = qx; prevQuadY = qy
            addCurve(c1x, c1y, c2x, c2y, ex, ey)
        }
        func addLine(_ ex: Double, _ ey: Double) {
            guard cur != nil else { return }
            cur!.o[cur!.o.count - 1] = [0, 0]
            x = ex; y = ey
            cur!.v.append([x, y]); cur!.i.append([0, 0]); cur!.o.append([0, 0])
        }

        while idx < tokens.count {
            let tok = tokens[idx]
            let cmdChar = tok.first.map { Character(String($0)) } ?? " "
            let isCmd = "MmLlHhVvCcSsQqTtAaZz".contains(cmdChar) && Double(tok) == nil
            let cmd: Character
            if isCmd { cmd = cmdChar; idx += 1 } else { cmd = implicitCmd(lastCmd) }
            lastCmd = cmd
            let rel = cmd.isLowercase
            let upper = Character(cmd.uppercased())

            switch upper {
            case "M":
                let px = num() + (rel ? x : 0), py = num() + (rel ? y : 0)
                x = px; y = py; newSub(px, py); lastCmd = rel ? "l" : "L"
            case "L":
                addLine(num() + (rel ? x : 0), num() + (rel ? y : 0))
            case "H":
                addLine(num() + (rel ? x : 0), y)
            case "V":
                addLine(x, num() + (rel ? y : 0))
            case "C":
                let c1x = num() + (rel ? x : 0), c1y = num() + (rel ? y : 0)
                let c2x = num() + (rel ? x : 0), c2y = num() + (rel ? y : 0)
                let ex = num() + (rel ? x : 0), ey = num() + (rel ? y : 0)
                addCurve(c1x, c1y, c2x, c2y, ex, ey)
            case "S":
                let reflect = prevUpper == "C" || prevUpper == "S"
                let c1x = reflect ? 2 * x - prevCtrlX : x, c1y = reflect ? 2 * y - prevCtrlY : y
                let c2x = num() + (rel ? x : 0), c2y = num() + (rel ? y : 0)
                let ex = num() + (rel ? x : 0), ey = num() + (rel ? y : 0)
                addCurve(c1x, c1y, c2x, c2y, ex, ey)
            case "Q":
                let qx = num() + (rel ? x : 0), qy = num() + (rel ? y : 0)
                let ex = num() + (rel ? x : 0), ey = num() + (rel ? y : 0)
                addQuad(qx, qy, ex, ey)
            case "T":
                let reflect = prevUpper == "Q" || prevUpper == "T"
                let qx = reflect ? 2 * x - prevQuadX : x, qy = reflect ? 2 * y - prevQuadY : y
                let ex = num() + (rel ? x : 0), ey = num() + (rel ? y : 0)
                addQuad(qx, qy, ex, ey)
            case "A":
                // rx ry x-rot large-arc sweep x y — дугу не строим, аппроксимируем отрезком до конца.
                _ = num(); _ = num(); _ = num(); _ = num(); _ = num()
                let ex = num() + (rel ? x : 0), ey = num() + (rel ? y : 0)
                addLine(ex, ey); approximated = true
            case "Z":
                cur?.closed = true
            default:
                idx += 1 // неизвестная команда — съедаем токен, чтобы не зациклиться
            }
            prevUpper = upper
        }
        if let c = cur { subpaths.append(c) }
        return ParseResult(subpaths: subpaths.filter { $0.v.count >= 2 }, approximated: approximated)
    }

    private static func implicitCmd(_ last: Character) -> Character { last == " " ? "L" : last }

    private static func tokenize(_ d: String) -> [String] {
        var tokens: [String] = []
        let scalars = Array(d)
        var i = 0
        func isNumStart(_ c: Character) -> Bool { c.isNumber || c == "." || c == "-" || c == "+" }
        while i < scalars.count {
            let c = scalars[i]
            if c.isLetter { tokens.append(String(c)); i += 1; continue }
            if c == " " || c == "," || c == "\n" || c == "\t" { i += 1; continue }
            if isNumStart(c) {
                var s = ""
                if c == "-" || c == "+" { s.append(c); i += 1 }
                var seenDot = false, seenE = false
                while i < scalars.count {
                    let ch = scalars[i]
                    if ch.isNumber { s.append(ch); i += 1 }
                    else if ch == "." && !seenDot { seenDot = true; s.append(ch); i += 1 }
                    else if (ch == "e" || ch == "E") && !seenE { seenE = true; s.append(ch); i += 1; if i < scalars.count, scalars[i] == "-" || scalars[i] == "+" { s.append(scalars[i]); i += 1 } }
                    else { break }
                }
                if !s.isEmpty { tokens.append(s) }
                continue
            }
            i += 1
        }
        return tokens
    }
}
#endif
