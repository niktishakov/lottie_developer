import Foundation
import ImageIO

/// Растровые ассеты как слои Lottie: картинка вшивается в `assets` (base64, `e: 1`),
/// слой `ty: 2` ссылается на неё. Компилятор анимирует такие слои по имени, как и векторные.
enum LottieImageLayers {

    struct ImageError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Пустая композиция под растровые ассеты.
    static func blank(width: Int, height: Int, fps: Int = 60, frames: Int = 120) -> Data {
        let root: [String: Any] = ["v": "5.7.4", "fr": fps, "ip": 0, "op": frames, "w": width, "h": height,
                                   "nm": "Composition", "ddd": 0, "assets": [], "layers": []]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    /// Размер картинки в пикселях (PNG/JPEG/WebP/HEIC — всё, что читает ImageIO).
    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// Добавить картинку новым верхним слоем.
    /// - frame: прямоугольник в координатах композиции (левый верх + размер). nil — по центру,
    ///   в натуральном размере, но не больше композиции.
    /// - Returns: обновлённый Lottie и итоговое имя слоя (уникальное).
    static func addImage(to lottie: Data, image: Data, name: String, frame: CGRect?) throws -> (data: Data, layerName: String) {
        guard var root = (try? JSONSerialization.jsonObject(with: lottie)) as? [String: Any] else {
            throw ImageError(message: "Base composition is not valid Lottie JSON")
        }
        guard let px = pixelSize(image) else { throw ImageError(message: "Unsupported image (\(name))") }
        var layers = root["layers"] as? [[String: Any]] ?? []
        var assets = root["assets"] as? [[String: Any]] ?? []
        let compW = (root["w"] as? NSNumber)?.doubleValue ?? Double(px.width)
        let compH = (root["h"] as? NSNumber)?.doubleValue ?? Double(px.height)
        let op = (root["op"] as? NSNumber)?.doubleValue ?? 120

        let existing = Set(layers.compactMap { $0["nm"] as? String })
        var layerName = name.isEmpty ? "image" : name
        if existing.contains(layerName) {
            var i = 2
            while existing.contains("\(layerName) \(i)") { i += 1 }
            layerName = "\(layerName) \(i)"
        }
        let assetIDs = Set(assets.compactMap { $0["id"] as? String })
        var n = assets.count + 1
        while assetIDs.contains("image_\(n)") { n += 1 }
        let assetID = "image_\(n)"

        assets.append(asset(id: assetID, image: image, px: px))
        let rect = frame ?? defaultFrame(px: px, compW: compW, compH: compH)
        let maxInd = layers.compactMap { ($0["ind"] as? NSNumber)?.intValue }.max() ?? 0
        layers.insert(layer(name: layerName, assetID: assetID, px: px, rect: rect, ind: maxInd + 1, op: op), at: 0)
        root["layers"] = layers
        root["assets"] = assets
        return (try JSONSerialization.data(withJSONObject: root), layerName)
    }

    static func asset(id: String, image: Data, px: (width: Int, height: Int)) -> [String: Any] {
        ["id": id, "w": px.width, "h": px.height, "u": "", "e": 1,
         "p": "data:\(mimeType(image));base64,\(image.base64EncodedString())"]
    }

    static func layer(name: String, assetID: String, px: (width: Int, height: Int), rect: CGRect, ind: Int, op: Double) -> [String: Any] {
        ["ddd": 0, "ind": ind, "ty": 2, "nm": name, "refId": assetID, "sr": 1,
         "ks": transform(px: px, rect: rect), "ao": 0, "ip": 0, "op": op, "st": 0, "bm": 0]
    }

    /// Переставить / растянуть слой-картинку (статичная раскладка до анимации).
    static func place(layer name: String, in lottie: Data, frame rect: CGRect) throws -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: lottie)) as? [String: Any],
              var layers = root["layers"] as? [[String: Any]] else { throw ImageError(message: "Not a Lottie JSON") }
        guard let i = layers.firstIndex(where: { $0["nm"] as? String == name }) else {
            throw ImageError(message: "Layer not found: \(name)")
        }
        guard (layers[i]["ty"] as? NSNumber)?.intValue == 2, let ref = layers[i]["refId"] as? String,
              let asset = (root["assets"] as? [[String: Any]])?.first(where: { $0["id"] as? String == ref }),
              let w = (asset["w"] as? NSNumber)?.intValue, let h = (asset["h"] as? NSNumber)?.intValue else {
            throw ImageError(message: "\(name) is not an image layer")
        }
        layers[i]["ks"] = transform(px: (w, h), rect: rect)
        root["layers"] = layers
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Раскладка слоёв-картинок: имя → прямоугольник в координатах композиции.
    static func imageFrames(in lottie: Data) -> [String: CGRect] {
        guard let root = (try? JSONSerialization.jsonObject(with: lottie)) as? [String: Any],
              let layers = root["layers"] as? [[String: Any]] else { return [:] }
        let assets = (root["assets"] as? [[String: Any]]) ?? []
        var out: [String: CGRect] = [:]
        for l in layers where (l["ty"] as? NSNumber)?.intValue == 2 {
            guard let name = l["nm"] as? String, let ref = l["refId"] as? String,
                  let a = assets.first(where: { $0["id"] as? String == ref }),
                  let w = (a["w"] as? NSNumber)?.doubleValue, let h = (a["h"] as? NSNumber)?.doubleValue,
                  let ks = l["ks"] as? [String: Any] else { continue }
            let p = staticVec(ks["p"]) ?? [w / 2, h / 2], s = staticVec(ks["s"]) ?? [100, 100]
            let rw = w * s[0] / 100, rh = h * (s.count > 1 ? s[1] : s[0]) / 100
            out[name] = CGRect(x: p[0] - rw / 2, y: p[1] - rh / 2, width: rw, height: rh)
        }
        return out
    }

    private static func defaultFrame(px: (width: Int, height: Int), compW: Double, compH: Double) -> CGRect {
        let k = min(1, compW / Double(px.width), compH / Double(px.height))
        let w = Double(px.width) * k, h = Double(px.height) * k
        return CGRect(x: (compW - w) / 2, y: (compH - h) / 2, width: w, height: h)
    }

    /// Якорь в центре картинки (чтобы scale/rotate крутились вокруг центра), позиция — центр rect.
    private static func transform(px: (width: Int, height: Int), rect: CGRect) -> [String: Any] {
        let sx = Double(rect.width) / Double(px.width) * 100, sy = Double(rect.height) / Double(px.height) * 100
        return [
            "o": ["a": 0, "k": 100, "ix": 11],
            "r": ["a": 0, "k": 0, "ix": 10],
            "p": ["a": 0, "k": [Double(rect.midX), Double(rect.midY), 0], "ix": 2],
            "a": ["a": 0, "k": [Double(px.width) / 2, Double(px.height) / 2, 0], "ix": 1],
            "s": ["a": 0, "k": [sx, sy, 100], "ix": 6],
        ]
    }

    private static func staticVec(_ v: Any?) -> [Double]? {
        guard let d = v as? [String: Any], (d["a"] as? NSNumber)?.intValue != 1,
              let k = d["k"] as? [NSNumber], k.count >= 2 else { return nil }
        return k.map(\.doubleValue)
    }

    private static func mimeType(_ data: Data) -> String {
        let b = [UInt8](data.prefix(4))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if b.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "image/webp" }
        return "image/png"
    }
}
