import Foundation

/// Правка слоя поверх готового Lottie: цвет, множитель прозрачности, скрытие.
/// Запекается прямо в JSON — так превью, раскадровка, экспорт и сохранённая версия совпадают 1:1.
struct LayerOverride: Codable, Equatable {
    /// Hex "#RRGGBB": перекрашивает все заливки и обводки слоя.
    var color: String?
    /// 0…100 — множитель к прозрачности слоя (анимированная прозрачность масштабируется по ключам).
    var opacity: Double?
    var hidden: Bool = false

    var isEmpty: Bool { color == nil && opacity == nil && !hidden }
}

/// Слой верхнего уровня композиции.
struct LottieLayerInfo: Identifiable, Hashable {
    let index: Int
    let name: String
    /// Lottie `ty`: 0 precomp, 1 solid, 2 image, 3 null, 4 shape, 5 text.
    let type: Int
    let isMatte: Bool
    var id: String { "\(index):\(name)" }

    var symbol: String {
        switch type {
        case 0: return "square.stack.3d.up"
        case 1: return "square.fill"
        case 2: return "photo"
        case 3: return "scope"
        case 5: return "textformat"
        default: return isMatte ? "circle.lefthalf.filled" : "scribble.variable"
        }
    }
}

enum LottieOverrides {

    static func layers(in data: Data) -> [LottieLayerInfo] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let layers = root["layers"] as? [[String: Any]] else { return [] }
        return layers.enumerated().map { i, l in
            LottieLayerInfo(index: i, name: l["nm"] as? String ?? "Layer \(i + 1)",
                            type: (l["ty"] as? NSNumber)?.intValue ?? 4,
                            isMatte: (l["td"] as? NSNumber)?.intValue == 1)
        }
    }

    /// Применить правки (ключ — имя слоя). Возвращает исходные данные, если править нечего.
    static func apply(_ overrides: [String: LayerOverride], to data: Data) -> Data {
        let active = overrides.filter { !$0.value.isEmpty }
        guard !active.isEmpty,
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var layers = root["layers"] as? [[String: Any]] else { return data }
        for i in layers.indices {
            guard let name = layers[i]["nm"] as? String, let o = active[name] else { continue }
            if o.hidden { layers[i]["hd"] = true }
            if let hex = o.color, let rgb = rgb(hex: hex), var shapes = layers[i]["shapes"] as? [[String: Any]] {
                recolor(&shapes, rgb)
                layers[i]["shapes"] = shapes
            }
            if let op = o.opacity, var ks = layers[i]["ks"] as? [String: Any] {
                ks["o"] = scaleOpacity(ks["o"], by: max(0, min(op, 100)) / 100)
                layers[i]["ks"] = ks
            }
        }
        root["layers"] = layers
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    /// Оставить видимым только один слой (+ его матте и null-родителей) — для выбора кликом и рамки.
    static func isolate(layerIndex: Int, in data: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var layers = root["layers"] as? [[String: Any]] else { return data }
        for i in layers.indices where i != layerIndex {
            let ty = (layers[i]["ty"] as? NSNumber)?.intValue
            let isMatteForTarget = i == layerIndex - 1 && (layers[i]["td"] as? NSNumber)?.intValue == 1
            if ty == 3 || isMatteForTarget { continue }
            layers[i]["hd"] = true
        }
        root["layers"] = layers
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    static func rgb(hex: String?) -> [Double]? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return [Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255]
    }

    /// Первый статичный цвет заливки/обводки слоя — для инспектора.
    static func firstColor(layerName: String, in data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let layers = root["layers"] as? [[String: Any]],
              let layer = layers.first(where: { $0["nm"] as? String == layerName }),
              let shapes = layer["shapes"] as? [[String: Any]] else { return nil }
        func find(_ items: [[String: Any]]) -> [Double]? {
            for it in items {
                let ty = it["ty"] as? String
                if ty == "fl" || ty == "st", let c = (it["c"] as? [String: Any])?["k"] as? [NSNumber], c.count >= 3 {
                    return c.prefix(3).map(\.doubleValue)
                }
                if let sub = it["it"] as? [[String: Any]], let c = find(sub) { return c }
            }
            return nil
        }
        guard let c = find(shapes) else { return nil }
        return String(format: "#%02X%02X%02X", Int(c[0] * 255), Int(c[1] * 255), Int(c[2] * 255))
    }

    private static func recolor(_ items: inout [[String: Any]], _ rgb: [Double]) {
        for i in items.indices {
            let ty = items[i]["ty"] as? String
            if ty == "fl" || ty == "st" {
                items[i]["c"] = ["a": 0, "k": rgb + [1]]
            }
            if var sub = items[i]["it"] as? [[String: Any]] {
                recolor(&sub, rgb)
                items[i]["it"] = sub
            }
        }
    }

    private static func scaleOpacity(_ value: Any?, by f: Double) -> Any {
        guard var o = value as? [String: Any] else { return ["a": 0, "k": 100 * f] }
        if (o["a"] as? NSNumber)?.intValue == 1, var kfs = o["k"] as? [[String: Any]] {
            for i in kfs.indices {
                for key in ["s", "e"] {
                    if let arr = kfs[i][key] as? [NSNumber] { kfs[i][key] = arr.map { $0.doubleValue * f } }
                }
            }
            o["k"] = kfs
        } else if let n = o["k"] as? NSNumber {
            o["k"] = n.doubleValue * f
        } else if let arr = o["k"] as? [NSNumber], let first = arr.first {
            o["k"] = first.doubleValue * f
        }
        return o
    }
}
