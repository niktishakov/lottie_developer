import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif os(iOS)
import WebKit
#endif

/// Минимальное DOM-дерево SVG: нужно, чтобы вырезать отдельный элемент (с его defs)
/// и отрисовать его в картинку, когда Lottie не умеет эффект (blur, маски, сложные градиенты).
final class SVGNode {
    let tag: String
    let attrs: [String: String]
    var children: [SVGNode] = []
    var text = ""
    weak var parent: SVGNode?

    init(tag: String, attrs: [String: String]) {
        self.tag = tag
        self.attrs = attrs
    }

    func serialize() -> String {
        let a = attrs.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(Self.escape($0.value))\"" }.joined()
        if children.isEmpty && text.isEmpty { return "<\(tag)\(a)/>" }
        return "<\(tag)\(a)>\(Self.escape(text))\(children.map { $0.serialize() }.joined())</\(tag)>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum SVGDocument {

    /// Теги, содержимое которых не рисуется напрямую.
    static let nonRendered: Set<String> = ["defs", "clippath", "mask", "symbol", "pattern", "marker", "lineargradient", "radialgradient", "filter"]

    static func parse(_ data: Data) -> SVGNode? {
        let b = Builder()
        let p = XMLParser(data: data)
        p.delegate = b
        guard p.parse() else { return nil }
        return b.root
    }

    /// Узлы, которые придётся растеризовать (по порядку документа, без вложенных друг в друга).
    static func rasterNodes(_ root: SVGNode, needsRaster: (SVGNode) -> Bool) -> [SVGNode] {
        var out: [SVGNode] = []
        func walk(_ n: SVGNode) {
            if nonRendered.contains(n.tag.lowercased()) { return }
            if n !== root, needsRaster(n) { out.append(n); return }
            n.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// SVG-документ, в котором видим только `node` (с цепочкой родительских <g> и всеми <defs>).
    static func isolate(_ node: SVGNode, root: SVGNode) -> Data {
        var chain: [SVGNode] = []
        var cur = node.parent
        while let c = cur, c !== root { chain.insert(c, at: 0); cur = c.parent }
        var inner = node.serialize()
        for g in chain.reversed() {
            let a = g.attrs.sorted { $0.key < $1.key }.map { " \($0.key)=\"\($0.value)\"" }.joined()
            inner = "<\(g.tag)\(a)>\(inner)</\(g.tag)>"
        }
        let defs = collectDefs(root).map { $0.serialize() }.joined()
        var rootAttrs = root.attrs
        if rootAttrs["xmlns"] == nil { rootAttrs["xmlns"] = "http://www.w3.org/2000/svg" }
        let a = rootAttrs.sorted { $0.key < $1.key }.map { " \($0.key)=\"\($0.value)\"" }.joined()
        return Data("<svg\(a)>\(defs)\(inner)</svg>".utf8)
    }

    private static func collectDefs(_ n: SVGNode) -> [SVGNode] {
        var out: [SVGNode] = []
        for c in n.children {
            let t = c.tag.lowercased()
            if t == "defs" || t == "lineargradient" || t == "radialgradient" || t == "filter" || t == "clippath" || t == "mask" {
                out.append(c)
            } else {
                out.append(contentsOf: collectDefs(c))
            }
        }
        return out
    }

    /// PNG через ImageIO (работает на macOS и iOS).
    static func pngData(_ img: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    #if os(iOS)
    /// iOS: системного SVG-рендерера нет — рисуем офскрин WKWebView и снимаем snapshot.
    /// - Returns: картинка размером canvas × scale.
    @MainActor
    static func rasterizeAsync(_ svg: Data, canvas: CGSize, scale: Double = 3) async -> CGImage? {
        let w = max(canvas.width, 1), h = max(canvas.height, 1)
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: w, height: h), configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        let b64 = svg.base64EncodedString()
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=\(w),initial-scale=1,user-scalable=no">\
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}\
        img{display:block;width:\(w)px;height:\(h)px}</style></head>\
        <body><img src="data:image/svg+xml;base64,\(b64)"></body></html>
        """
        let loader = WebLoader()
        web.navigationDelegate = loader
        // Без окна WebKit может не отрисовать — кладём вью в ключевое окно за пределами экрана.
        let host = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        web.frame.origin = CGPoint(x: -w - 100, y: 0)
        host?.addSubview(web)
        defer { web.removeFromSuperview() }
        let ok = await loader.load(web, html: html)
        guard ok else { return nil }
        // Дожидаемся декодирования <img>.
        _ = try? await web.evaluateJavaScript("new Promise(r => { const i = document.images[0]; if (!i || i.complete) r(1); else { i.onload = () => r(1); i.onerror = () => r(0); } })")
        let snap = WKSnapshotConfiguration()
        snap.rect = CGRect(x: 0, y: 0, width: w, height: h)
        snap.snapshotWidth = NSNumber(value: Double(w) * scale)
        snap.afterScreenUpdates = true
        guard let image = try? await web.takeSnapshot(configuration: snap), let cg = image.cgImage else { return nil }
        // snapshotWidth — в точках: на экране @3x пикселей втрое больше. Приводим к точному canvas × scale,
        // иначе обрезка (cropToContent делит на scale) ставит растровые слои не туда.
        let pw = max(Int((Double(w) * scale).rounded()), 1), ph = max(Int((Double(h) * scale).rounded()), 1)
        if cg.width == pw && cg.height == ph { return cg }
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        return ctx.makeImage() ?? cg
    }

    @MainActor
    private final class WebLoader: NSObject, WKNavigationDelegate {
        private var cont: CheckedContinuation<Bool, Never>?

        func load(_ web: WKWebView, html: String) async -> Bool {
            await withCheckedContinuation { c in
                cont = c
                web.loadHTMLString(html, baseURL: nil)
            }
        }

        private func finish(_ ok: Bool) { cont?.resume(returning: ok); cont = nil }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    }
    #endif

    #if os(macOS)
    /// Растеризовать SVG целиком (системный рендерер, понимает фильтры и градиенты).
    /// - Returns: картинка размером canvas × scale и её размер в пикселях.
    static func rasterize(_ svg: Data, canvas: CGSize, scale: Double = 3) -> CGImage? {
        guard let img = NSImage(data: svg) else { return nil }
        let w = max(Int(canvas.width * scale), 1), h = max(Int(canvas.height * scale), 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
    #endif

    /// Обрезать прозрачные поля. Возвращает PNG и прямоугольник в координатах холста.
    static func cropToContent(_ img: CGImage, scale: Double) -> (png: Data, rect: CGRect)? {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where buf[row + x * 4 + 3] > 2 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0, let cropped = img.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)),
              let png = encodeCropPNG(cropped) else { return nil }
        let rect = CGRect(x: Double(minX) / scale, y: Double(minY) / scale,
                          width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
        return (png, rect)
    }

    private static func encodeCropPNG(_ img: CGImage) -> Data? {
        #if os(macOS)
        // Как раньше: байт-в-байт тот же PNG, что и до порта на iOS.
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        #else
        return pngData(img)
        #endif
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: SVGNode?
        private var stack: [SVGNode] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            let n = SVGNode(tag: name, attrs: attributes)
            n.parent = stack.last
            stack.last?.children.append(n)
            if root == nil { root = n }
            stack.append(n)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { stack.last?.text += t }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}
