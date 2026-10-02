import Foundation

/// Сборка сцены из нескольких файлов: Lottie (в т.ч. из SVG) вставляется в композицию группой —
/// null-слоем с именем файла, к которому привязаны все его слои. Двигать/масштабировать/анимировать
/// группу можно по имени null-слоя, отдельные части — по их именам.
enum LottieMerge {

    struct MergeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// - origin: куда поставить левый верхний угол вставляемой композиции (координаты базы).
    /// - Returns: новый Lottie и имя группы.
    static func add(_ part: Data, to base: Data, group: String, origin: CGPoint = .zero) throws -> (data: Data, group: String) {
        guard var root = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any],
              let src = (try? JSONSerialization.jsonObject(with: part)) as? [String: Any],
              let srcLayers = src["layers"] as? [[String: Any]] else {
            throw MergeError(message: "Not a valid Lottie composition")
        }
        var layers = root["layers"] as? [[String: Any]] ?? []
        var assets = root["assets"] as? [[String: Any]] ?? []
        let op = (root["op"] as? NSNumber)?.doubleValue ?? 120

        // Уникальные имена: группа и все слои части (префикс не добавляем, только суффикс при конфликте).
        var used = Set(layers.compactMap { $0["nm"] as? String })
        func unique(_ n: String) -> String {
            var name = n, i = 2
            while used.contains(name) { name = "\(n) \(i)"; i += 1 }
            used.insert(name)
            return name
        }
        let groupName = unique(group)

        // Ассеты: новые id с префиксом, чтобы не пересечься.
        let tag = "m\(assets.count + layers.count + 1)_"
        var idMap: [String: String] = [:]
        for var a in src["assets"] as? [[String: Any]] ?? [] {
            guard let id = a["id"] as? String else { continue }
            idMap[id] = tag + id
            a["id"] = tag + id
            assets.append(a)
        }

        // Индексы: сдвигаем, сохраняя parent-связи внутри части.
        var nextInd = (layers.compactMap { ($0["ind"] as? NSNumber)?.intValue }.max() ?? 0) + 1
        let groupInd = nextInd; nextInd += 1
        var indMap: [Int: Int] = [:]
        for l in srcLayers { if let i = (l["ind"] as? NSNumber)?.intValue { indMap[i] = nextInd; nextInd += 1 } }

        var inserted: [[String: Any]] = []
        for var l in srcLayers {
            if let i = (l["ind"] as? NSNumber)?.intValue { l["ind"] = indMap[i] } else { l["ind"] = nextInd; nextInd += 1 }
            if let p = (l["parent"] as? NSNumber)?.intValue, let np = indMap[p] { l["parent"] = np } else { l["parent"] = groupInd }
            if let ref = l["refId"] as? String, let nr = idMap[ref] { l["refId"] = nr }
            l["nm"] = unique(l["nm"] as? String ?? "layer")
            // Статичные части (SVG → op = 1) должны жить весь таймлайн базы.
            if let lop = (l["op"] as? NSNumber)?.doubleValue, lop < op { l["op"] = op }
            inserted.append(l)
        }
        let groupLayer: [String: Any] = [
            "ddd": 0, "ind": groupInd, "ty": 3, "nm": groupName, "sr": 1, "ao": 0,
            "ip": 0, "op": op, "st": 0, "bm": 0,
            "ks": ["o": ["a": 0, "k": 100, "ix": 11], "r": ["a": 0, "k": 0, "ix": 10],
                   "p": ["a": 0, "k": [Double(origin.x), Double(origin.y), 0], "ix": 2],
                   "a": ["a": 0, "k": [0, 0, 0], "ix": 1], "s": ["a": 0, "k": [100, 100, 100], "ix": 6]],
        ]
        // Новая часть — поверх существующих; null-слой рядом с ней (порядок null не влияет на отрисовку).
        layers.insert(contentsOf: [groupLayer] + inserted, at: 0)
        root["layers"] = layers
        root["assets"] = assets
        return (try JSONSerialization.data(withJSONObject: root), groupName)
    }

    /// Размер композиции.
    static func size(_ lottie: Data) -> CGSize? {
        guard let root = (try? JSONSerialization.jsonObject(with: lottie)) as? [String: Any],
              let w = (root["w"] as? NSNumber)?.doubleValue, let h = (root["h"] as? NSNumber)?.doubleValue else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Переставить любой слой (группу, фигуру, картинку): позиция — левый верх его содержимого
    /// в координатах композиции, опционально масштаб в %. Для картинок есть точный `LottieImageLayers.place`.
    static func move(layer name: String, in lottie: Data, to origin: CGPoint?, scale: Double?) throws -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: lottie)) as? [String: Any],
              var layers = root["layers"] as? [[String: Any]],
              let i = layers.firstIndex(where: { $0["nm"] as? String == name }) else {
            throw MergeError(message: "Layer not found: \(name)")
        }
        var ks = layers[i]["ks"] as? [String: Any] ?? [:]
        if let origin {
            // p - a = левый верх для null-групп (a = 0) и сдвиг для остальных.
            let a = ((ks["a"] as? [String: Any])?["k"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0]
            let isGroup = (layers[i]["ty"] as? NSNumber)?.intValue == 3
            let p: [Double] = isGroup ? [Double(origin.x), Double(origin.y), 0]
                                      : [Double(origin.x) + a[0], Double(origin.y) + (a.count > 1 ? a[1] : 0), 0]
            ks["p"] = ["a": 0, "k": p, "ix": 2]
        }
        if let scale { ks["s"] = ["a": 0, "k": [scale, scale, 100], "ix": 6] }
        layers[i]["ks"] = ks
        root["layers"] = layers
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Порядок слоёв: поставить слой на позицию (0 — самый верх) или "top"/"bottom".
    static func reorder(layer name: String, in lottie: Data, to position: Int) throws -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: lottie)) as? [String: Any],
              var layers = root["layers"] as? [[String: Any]],
              let i = layers.firstIndex(where: { $0["nm"] as? String == name }) else {
            throw MergeError(message: "Layer not found: \(name)")
        }
        let l = layers.remove(at: i)
        layers.insert(l, at: max(0, min(position, layers.count)))
        root["layers"] = layers
        return try JSONSerialization.data(withJSONObject: root)
    }

    static func rename(layer name: String, to newName: String, in lottie: Data) throws -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: lottie)) as? [String: Any],
              var layers = root["layers"] as? [[String: Any]],
              let i = layers.firstIndex(where: { $0["nm"] as? String == name }) else {
            throw MergeError(message: "Layer not found: \(name)")
        }
        guard !layers.contains(where: { $0["nm"] as? String == newName }) else {
            throw MergeError(message: "Layer name already used: \(newName)")
        }
        layers[i]["nm"] = newName
        root["layers"] = layers
        return try JSONSerialization.data(withJSONObject: root)
    }
}
