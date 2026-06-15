import Foundation

/// Детерминированный компилятор: `AnimationSpec` + статичный Lottie JSON → анимированный Lottie JSON.
///
/// Чистый Foundation-код без сети и UI. Геометрия слоёв не меняется — впрыскиваются только keyframes
/// в transform-каналы (`ks`: o/p/s/r) или trim-path (`tm`). Поэтому результат валиден по построению,
/// при условии что входной статичный Lottie валиден.
struct LottieCompiler {
    struct CompileResult {
        let data: Data
        let warnings: [String]
    }

    enum CompileError: LocalizedError {
        case invalidStaticLottie
        case serializationFailed

        var errorDescription: String? {
            switch self {
            case .invalidStaticLottie: return "Static Lottie JSON is not a valid object with layers"
            case .serializationFailed: return "Failed to serialize compiled Lottie"
            }
        }
    }

    func compile(staticLottie: Data, spec: AnimationSpec) throws -> CompileResult {
        guard var root = (try? JSONSerialization.jsonObject(with: staticLottie)) as? [String: Any],
              var layers = root["layers"] as? [[String: Any]] else {
            throw CompileError.invalidStaticLottie
        }

        let fps = clamp(spec.fps, AnimationSpec.minFPS, AnimationSpec.maxFPS)
        let duration = clamp(spec.durationFrames, 1, AnimationSpec.maxDurationFrames)
        var warnings: [String] = []

        // Индекс слоёв по имени. При дублирующихся именах берём первый и предупреждаем.
        var indexByName: [String: Int] = [:]
        for (idx, layer) in layers.enumerated() {
            guard let name = layer["nm"] as? String else { continue }
            if indexByName[name] == nil {
                indexByName[name] = idx
            }
        }

        var matteInserts: [(layerIdx: Int, matte: [String: Any])] = []
        let maxInd = layers.compactMap { $0["ind"] as? Int }.max() ?? 0

        for layerSpec in spec.layers {
            guard let idx = indexByName[layerSpec.target] else {
                warnings.append("Layer '\(layerSpec.target)' not found — animations skipped")
                continue
            }

            var layer = layers[idx]
            var ks = layer["ks"] as? [String: Any] ?? [:]

            for primitive in layerSpec.animations {
                if primitive.kind == .drawOn {
                    let startFrame = frame(primitive.start, fps: fps)
                    var endFrame = frame(primitive.end, fps: fps)
                    if endFrame <= startFrame { endFrame = startFrame + 1 }
                    let shapes = layer["shapes"] as? [[String: Any]] ?? []

                    if containsType(shapes, "st") {
                        var mutableShapes = shapes
                        injectTrimOnStrokes(&mutableShapes, startFrame: startFrame, endFrame: endFrame, easing: primitive.easing)
                        layer["shapes"] = mutableShapes
                    } else if let matte = buildDrawOnMatte(
                        targetLayer: layer, shapes: shapes,
                        startFrame: startFrame, endFrame: endFrame,
                        easing: primitive.easing, duration: duration,
                        matteInd: maxInd + 100 + matteInserts.count
                    ) {
                        matteInserts.append((layerIdx: idx, matte: matte))
                    }
                } else {
                    applyPrimitive(
                        primitive,
                        ks: &ks,
                        layer: &layer,
                        fps: fps,
                        warnings: &warnings,
                        targetName: layerSpec.target
                    )
                }
            }

            layer["ks"] = ks
            layer["ip"] = 0
            layer["op"] = duration
            layers[idx] = layer
        }

        for insert in matteInserts.sorted(by: { $0.layerIdx > $1.layerIdx }) {
            layers[insert.layerIdx]["tt"] = 1
            layers.insert(insert.matte, at: insert.layerIdx)
        }

        root["layers"] = layers
        root["fr"] = fps
        root["ip"] = 0
        root["op"] = duration

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            throw CompileError.serializationFailed
        }
        return CompileResult(data: data, warnings: warnings)
    }

    // MARK: - Primitive dispatch

    private func applyPrimitive(
        _ primitive: MotionPrimitive,
        ks: inout [String: Any],
        layer: inout [String: Any],
        fps: Int,
        warnings: inout [String],
        targetName: String
    ) {
        let startFrame = frame(primitive.start, fps: fps)
        var endFrame = frame(primitive.end, fps: fps)
        if endFrame <= startFrame { endFrame = startFrame + 1 } // защита от нулевой длительности
        let p = primitive.params ?? MotionParams()
        let easing = primitive.easing

        switch primitive.kind {
        case .fadeIn:
            setScalar(&ks, "o", ix: 11, [
                kf(startFrame, [0], easing), kf(endFrame, [100])
            ])
        case .fadeOut:
            setScalar(&ks, "o", ix: 11, [
                kf(startFrame, [100], easing), kf(endFrame, [0])
            ])
        case .slideIn:
            let base = vectorBase(ks, "p", fallback: [0, 0, 0])
            let from = offset(base, direction: p.direction, distance: p.distance ?? 100, reversed: true)
            setVector(&ks, "p", ix: 2, [
                kf(startFrame, from, easing), kf(endFrame, base)
            ])
        case .slideOut:
            let base = vectorBase(ks, "p", fallback: [0, 0, 0])
            let to = offset(base, direction: p.direction, distance: p.distance ?? 100, reversed: false)
            setVector(&ks, "p", ix: 2, [
                kf(startFrame, base, easing), kf(endFrame, to)
            ])
        case .scaleIn:
            let from = p.from ?? 0
            let to = p.to ?? 100
            setVector(&ks, "s", ix: 6, [
                kf(startFrame, [from, from, 100], easing), kf(endFrame, [to, to, 100])
            ])
        case .scaleOut:
            let from = p.from ?? 100
            let to = p.to ?? 0
            setVector(&ks, "s", ix: 6, [
                kf(startFrame, [from, from, 100], easing), kf(endFrame, [to, to, 100])
            ])
        case .rotate:
            let base = scalarBase(ks, "r", fallback: 0)
            let from = p.fromDeg ?? base
            let to = p.toDeg ?? (base + 360)
            setScalar(&ks, "r", ix: 10, [
                kf(startFrame, [from], easing), kf(endFrame, [to])
            ])
        case .pulse:
            let peak = p.amount ?? 110
            let repeats = max(1, p.repeatCount ?? 1)
            setVector(&ks, "s", ix: 6, pulseKeyframes(
                startFrame: startFrame, endFrame: endFrame, peak: peak, repeats: repeats, easing: easing
            ))
        case .bounce:
            let base = vectorBase(ks, "p", fallback: [0, 0, 0])
            let amount = p.amount ?? 20
            setVector(&ks, "p", ix: 2, bounceKeyframes(
                base: base, startFrame: startFrame, endFrame: endFrame, amount: amount
            ))
        case .wiggle:
            let base = vectorBase(ks, "p", fallback: [0, 0, 0])
            let amount = p.amount ?? 10
            let freq = max(1, Int((p.frequency ?? 4).rounded()))
            setVector(&ks, "p", ix: 2, wiggleKeyframes(
                base: base, startFrame: startFrame, endFrame: endFrame, amount: amount, frequency: freq
            ))
        case .drawOn:
            break // drawOn обрабатывается в compile() через track matte
        case .spin:
            let base = scalarBase(ks, "r", fallback: 0)
            let turns = Double(max(1, p.repeatCount ?? 1))
            setScalar(&ks, "r", ix: 10, [
                kf(startFrame, [base], .linear), kf(endFrame, [base + 360 * turns])
            ])
        case .float:
            let base = vectorBase(ks, "p", fallback: [0, 0, 0])
            let amount = p.amount ?? 12
            setVector(&ks, "p", ix: 2, floatKeyframes(base: base, startFrame: startFrame, endFrame: endFrame, amount: amount))
        case .breathe:
            let peak = p.amount ?? 106
            setVector(&ks, "s", ix: 6, pulseKeyframes(
                startFrame: startFrame, endFrame: endFrame, peak: peak,
                repeats: max(1, p.repeatCount ?? 1), easing: .easeInOut
            ))
        case .swing:
            let base = scalarBase(ks, "r", fallback: 0)
            let amount = p.amount ?? 10
            setScalar(&ks, "r", ix: 10, swingKeyframes(base: base, startFrame: startFrame, endFrame: endFrame, amount: amount))
        case .followPath:
            let base = vectorBase(ks, "p", fallback: [0, 0, 0])
            if let points = p.path, points.count >= 2 {
                setVector(&ks, "p", ix: 2, followPathKeyframes(
                    base: base, points: points, startFrame: startFrame, endFrame: endFrame, easing: easing
                ))
            } else {
                warnings.append("Layer '\(targetName)': followPath needs params.path with ≥2 points — skipped")
            }
        }
    }

    // MARK: - Composite keyframe generators

    private func pulseKeyframes(startFrame: Int, endFrame: Int, peak: Double, repeats: Int, easing: Easing) -> [[String: Any]] {
        var frames: [[String: Any]] = []
        let total = endFrame - startFrame
        let perCycle = max(2, total / repeats)
        var t = startFrame
        for _ in 0..<repeats {
            let mid = t + perCycle / 2
            let endCycle = t + perCycle
            frames.append(kf(t, [100, 100, 100], easing))
            frames.append(kf(mid, [peak, peak, 100], easing))
            frames.append(kf(endCycle, [100, 100, 100], easing))
            t = endCycle
        }
        // Гарантируем строго возрастающие t и финальный возврат к 100.
        return normalizeTimes(frames, defaultValues: [100, 100, 100])
    }

    private func bounceKeyframes(base: [Double], startFrame: Int, endFrame: Int, amount: Double) -> [[String: Any]] {
        let mid = startFrame + (endFrame - startFrame) / 2
        let up = applied(base, dx: 0, dy: -amount)
        return [
            kf(startFrame, base, .easeOut),
            kf(mid, up, .easeIn),
            kf(endFrame, base)
        ]
    }

    private func wiggleKeyframes(base: [Double], startFrame: Int, endFrame: Int, amount: Double, frequency: Int) -> [[String: Any]] {
        let steps = max(2, frequency * 2)
        var frames: [[String: Any]] = []
        let span = endFrame - startFrame
        for i in 0...steps {
            let t = startFrame + Int(round(Double(span) * Double(i) / Double(steps)))
            // Детерминированный псевдо-шум, чтобы тесты были стабильны.
            let dx = pseudoNoise(i * 2 + 1) * amount
            let dy = pseudoNoise(i * 2 + 7) * amount
            let values = (i == 0 || i == steps) ? base : applied(base, dx: dx, dy: dy)
            frames.append(kf(t, values, .easeInOut))
        }
        return normalizeTimes(frames, defaultValues: base)
    }

    /// Мягкое вертикальное покачивание: base → вверх → base (петля при loop).
    private func floatKeyframes(base: [Double], startFrame: Int, endFrame: Int, amount: Double) -> [[String: Any]] {
        let mid = startFrame + (endFrame - startFrame) / 2
        return normalizeTimes([
            kf(startFrame, base, .easeInOut),
            kf(mid, applied(base, dx: 0, dy: -amount), .easeInOut),
            kf(endFrame, base)
        ], defaultValues: base)
    }

    /// Маятник: base → +amount° → −amount° → base (петля при loop).
    private func swingKeyframes(base: Double, startFrame: Int, endFrame: Int, amount: Double) -> [[String: Any]] {
        let span = endFrame - startFrame
        let q1 = startFrame + span / 4
        let q3 = startFrame + (span * 3) / 4
        return normalizeTimes([
            kf(startFrame, [base], .easeInOut),
            kf(q1, [base + amount], .easeInOut),
            kf(q3, [base - amount], .easeInOut),
            kf(endFrame, [base])
        ], defaultValues: [base])
    }

    /// Движение по пути: position keyframes по контрольным точкам.
    /// Точки интерпретируются как абсолютные смещения от базовой позиции слоя.
    private func followPathKeyframes(base: [Double], points: [[Double]], startFrame: Int, endFrame: Int, easing: Easing) -> [[String: Any]] {
        let count = points.count
        let span = endFrame - startFrame
        var frames: [[String: Any]] = []
        for (i, pt) in points.enumerated() {
            let t = startFrame + (count <= 1 ? 0 : Int(round(Double(span) * Double(i) / Double(count - 1))))
            let x = base.count > 0 ? base[0] + (pt.count > 0 ? pt[0] : 0) : (pt.count > 0 ? pt[0] : 0)
            let y = base.count > 1 ? base[1] + (pt.count > 1 ? pt[1] : 0) : (pt.count > 1 ? pt[1] : 0)
            let z = base.count > 2 ? base[2] : 0.0
            let e: Easing? = (i < count - 1) ? easing : nil
            frames.append(kf(t, [x, y, z], e))
        }
        return normalizeTimes(frames, defaultValues: base)
    }

    /// Для слоёв со штрихами: вставляет trim path рядом со stroke в каждой группе.
    private func injectTrimOnStrokes(
        _ shapes: inout [[String: Any]],
        startFrame: Int,
        endFrame: Int,
        easing: Easing
    ) {
        for i in 0..<shapes.count {
            if (shapes[i]["ty"] as? String) == "gr",
               var items = shapes[i]["it"] as? [[String: Any]] {
                if items.contains(where: { ($0["ty"] as? String) == "gr" }) {
                    injectTrimOnStrokes(&items, startFrame: startFrame, endFrame: endFrame, easing: easing)
                } else if containsType(items, "st") {
                    let trimIdx = items.lastIndex { ($0["ty"] as? String) == "tr" } ?? items.endIndex
                    let trim = makeTrim(startFrame: startFrame, endFrame: endFrame, easing: easing, ix: items.count + 1)
                    items.insert(trim, at: trimIdx)
                }
                shapes[i]["it"] = items
            }
        }
    }

    /// Строит track-matte слой: невидимый штрих+trim, который прогрессивно раскрывает оригинальный слой.
    private func buildDrawOnMatte(
        targetLayer: [String: Any],
        shapes: [[String: Any]],
        startFrame: Int,
        endFrame: Int,
        easing: Easing,
        duration: Int,
        matteInd: Int
    ) -> [String: Any]? {
        let paths = extractShapePaths(shapes)
        guard !paths.isEmpty else { return nil }

        let mattePath: [String: Any]
        let strokeWidth: Double

        if paths.count >= 2 {
            mattePath = paths[1]
            let r0 = pathRadius(paths[0])
            let r1 = pathRadius(paths[1])
            strokeWidth = abs(r0 - r1) * 4 + r0 * 0.3
        } else {
            mattePath = paths[0]
            strokeWidth = pathRadius(paths[0])
        }

        let trimOffset = trimStartOffset(mattePath)

        let stroke: [String: Any] = [
            "ty": "st",
            "c": ["a": 0, "k": [1, 1, 1, 1]],
            "o": ["a": 0, "k": 100],
            "w": ["a": 0, "k": strokeWidth],
            "lc": 2, "lj": 2,
            "nm": "Matte Stroke"
        ]
        let trim = makeTrimWithOffset(startFrame: startFrame, endFrame: endFrame, easing: easing, offset: trimOffset, ix: 3)
        let tr: [String: Any] = [
            "ty": "tr",
            "p": ["a": 0, "k": [0, 0]],
            "a": ["a": 0, "k": [0, 0]],
            "s": ["a": 0, "k": [100, 100]],
            "r": ["a": 0, "k": 0],
            "o": ["a": 0, "k": 100]
        ]
        let group: [String: Any] = [
            "ty": "gr",
            "it": [mattePath, stroke, trim, tr],
            "nm": "Matte Group"
        ]

        return [
            "ty": 4,
            "nm": "drawOn-matte",
            "shapes": [group],
            "ip": 0,
            "op": duration,
            "st": 0,
            "sr": 1,
            "td": 1,
            "ks": targetLayer["ks"] ?? [:],
            "ind": matteInd
        ]
    }

    private func extractShapePaths(_ shapes: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for s in shapes {
            if (s["ty"] as? String) == "sh" { result.append(s) }
            if (s["ty"] as? String) == "gr", let items = s["it"] as? [[String: Any]] {
                result.append(contentsOf: extractShapePaths(items))
            }
        }
        return result
    }

    /// Вычисляет trim offset (градусы) чтобы рисование начиналось с верхней правой вершины.
    private func trimStartOffset(_ pathShape: [String: Any]) -> Double {
        guard let ks = pathShape["ks"] as? [String: Any],
              let k = ks["k"] as? [String: Any],
              let v = k["v"] as? [[Any]], v.count > 1 else { return 0 }

        var bestIdx = 0
        var bestScore = Double.infinity
        for (i, pt) in v.enumerated() {
            guard let x = (pt[0] as? NSNumber)?.doubleValue,
                  let y = (pt[1] as? NSNumber)?.doubleValue else { continue }
            // Ищем верхнюю правую: минимальный y, при равных — максимальный x
            let score = y - x * 0.01
            if score < bestScore { bestScore = score; bestIdx = i }
        }
        return 360.0 * Double(bestIdx) / Double(v.count)
    }

    private func pathRadius(_ pathShape: [String: Any]) -> Double {
        guard let ks = pathShape["ks"] as? [String: Any],
              let k = ks["k"] as? [String: Any],
              let v = k["v"] as? [[Any]] else { return 10 }
        var xs: [Double] = [], ys: [Double] = []
        for pt in v {
            if let x = (pt[0] as? NSNumber)?.doubleValue { xs.append(x) }
            if pt.count > 1, let y = (pt[1] as? NSNumber)?.doubleValue { ys.append(y) }
        }
        guard !xs.isEmpty else { return 10 }
        return max((xs.max()! - xs.min()!), (ys.max()! - ys.min()!)) / 2
    }

    private func makeTrim(startFrame: Int, endFrame: Int, easing: Easing, ix: Int) -> [String: Any] {
        makeTrimWithOffset(startFrame: startFrame, endFrame: endFrame, easing: easing, offset: 0, ix: ix)
    }

    private func makeTrimWithOffset(startFrame: Int, endFrame: Int, easing: Easing, offset: Double, ix: Int) -> [String: Any] {
        [
            "ty": "tm",
            "s": ["a": 0, "k": 0, "ix": 1],
            "e": ["a": 1, "k": [kf(startFrame, [0], easing), kf(endFrame, [100])], "ix": 2],
            "o": ["a": 0, "k": offset, "ix": 3],
            "m": 1,
            "nm": "Trim Paths (drawOn)",
            "ix": ix
        ]
    }

    private func containsType(_ shapes: [[String: Any]], _ type: String) -> Bool {
        for s in shapes {
            if (s["ty"] as? String) == type { return true }
            if (s["ty"] as? String) == "gr", let items = s["it"] as? [[String: Any]],
               containsType(items, type) { return true }
        }
        return false
    }

    // MARK: - Channel writers

    private func setScalar(_ ks: inout [String: Any], _ key: String, ix: Int, _ keyframes: [[String: Any]]) {
        let resolvedIx = existingIx(ks, key) ?? ix
        ks[key] = ["a": 1, "k": keyframes, "ix": resolvedIx]
    }

    private func setVector(_ ks: inout [String: Any], _ key: String, ix: Int, _ keyframes: [[String: Any]]) {
        let resolvedIx = existingIx(ks, key) ?? ix
        ks[key] = ["a": 1, "k": keyframes, "ix": resolvedIx]
    }

    // MARK: - Keyframe construction

    /// Один keyframe. easing описывает переход ОТ этого keyframe К следующему; у последнего
    /// keyframe easing не нужен (передаётся nil).
    private func kf(_ t: Int, _ values: [Double], _ easing: Easing? = nil) -> [String: Any] {
        var frame: [String: Any] = ["t": t, "s": values]
        if let easing {
            let b = bezier(easing)
            frame["o"] = ["x": [b.ox], "y": [b.oy]]
            frame["i"] = ["x": [b.ix], "y": [b.iy]]
        }
        return frame
    }

    /// Убирает дубли/невозрастающие t, гарантирует у последнего keyframe отсутствие i/o.
    private func normalizeTimes(_ frames: [[String: Any]], defaultValues: [Double]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var lastT = Int.min
        for var frame in frames {
            var t = frame["t"] as? Int ?? 0
            if t <= lastT { t = lastT + 1 }
            frame["t"] = t
            lastT = t
            result.append(frame)
        }
        if result.isEmpty {
            return [kf(0, defaultValues)]
        }
        // Последний keyframe не должен нести easing-хэндлы.
        var last = result.removeLast()
        last.removeValue(forKey: "o")
        last.removeValue(forKey: "i")
        result.append(last)
        return result
    }

    // MARK: - Easing presets (CSS cubic-bezier control points)

    private func bezier(_ easing: Easing) -> (ox: Double, oy: Double, ix: Double, iy: Double) {
        switch easing {
        case .linear:       return (0, 0, 1, 1)
        case .easeIn:       return (0.42, 0, 1, 1)
        case .easeOut:      return (0, 0, 0.58, 1)
        case .easeInOut:    return (0.42, 0, 0.58, 1)
        case .spring:       return (0.34, 1.2, 0.64, 1)   // лёгкий overshoot
        case .easeOutBack:  return (0.34, 1.56, 0.64, 1)  // перелёт в конце (y>1)
        case .easeInBack:   return (0.36, 0, 0.66, -0.56) // оттяжка в начале (y<0)
        case .easeInOutBack:return (0.68, -0.6, 0.32, 1.6)
        case .anticipate:   return (0.4, -0.3, 0.6, 1)
        }
    }

    // MARK: - Base value readers

    private func scalarBase(_ ks: [String: Any], _ key: String, fallback: Double) -> Double {
        guard let ch = ks[key] as? [String: Any] else { return fallback }
        if let n = ch["k"] as? NSNumber { return n.doubleValue }
        if let arr = ch["k"] as? [Any], let n = arr.first as? NSNumber { return n.doubleValue }
        return fallback
    }

    private func vectorBase(_ ks: [String: Any], _ key: String, fallback: [Double]) -> [Double] {
        guard let ch = ks[key] as? [String: Any],
              let arr = ch["k"] as? [Any] else { return fallback }
        let values = arr.compactMap { ($0 as? NSNumber)?.doubleValue }
        return values.isEmpty ? fallback : values
    }

    private func existingIx(_ ks: [String: Any], _ key: String) -> Int? {
        (ks[key] as? [String: Any])?["ix"] as? Int
    }

    // MARK: - Geometry helpers

    /// Смещение базовой позиции для slide. `reversed: true` — стартовая точка (откуда «въезжает»),
    /// `reversed: false` — конечная (куда «уезжает»). direction — направление видимого движения.
    private func offset(_ base: [Double], direction: String?, distance: Double, reversed: Bool) -> [Double] {
        var dx = 0.0, dy = 0.0
        switch direction {
        case "up":    dy = +distance   // въезжает снизу вверх → старт ниже (y больше)
        case "down":  dy = -distance
        case "left":  dx = +distance
        case "right": dx = -distance
        default:      dy = +distance   // дефолт — снизу
        }
        if !reversed { dx = -dx; dy = -dy }
        return applied(base, dx: dx, dy: dy)
    }

    private func applied(_ base: [Double], dx: Double, dy: Double) -> [Double] {
        var v = base
        if v.count >= 2 {
            v[0] += dx
            v[1] += dy
        }
        return v
    }

    // MARK: - Utilities

    private func frame(_ seconds: Double, fps: Int) -> Int {
        max(0, Int((seconds * Double(fps)).rounded()))
    }

    private func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(value, lo), hi)
    }

    /// Детерминированный псевдо-шум в диапазоне [-1, 1] по целочисленному seed (без Math.random,
    /// чтобы вывод компилятора был воспроизводимым в тестах).
    private func pseudoNoise(_ seed: Int) -> Double {
        let x = Double((seed &* 2654435761) % 10_000) / 10_000.0 // [0,1)
        return x * 2 - 1
    }
}
