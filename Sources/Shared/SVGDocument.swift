import Foundation
import AppKit

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
              let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else { return nil }
        let rect = CGRect(x: Double(minX) / scale, y: Double(minY) / scale,
                          width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
        return (png, rect)
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
