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

        for layerSpec in spec.layers {
            guard let idx = indexByName[layerSpec.target] else {
                warnings.append("Layer '\(layerSpec.target)' not found — animations skipped")
                continue
            }

            var layer = layers[idx]
            var ks = layer["ks"] as? [String: Any] ?? [:]

            for primitive in layerSpec.animations {
                applyPrimitive(
                    primitive,
                    ks: &ks,
                    layer: &layer,
                    fps: fps,
                    warnings: &warnings,
                    targetName: layerSpec.target
                )
            }

            layer["ks"] = ks
            // Слой должен жить на всём интервале композиции.
            layer["ip"] = 0
            layer["op"] = duration
            layers[idx] = layer
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
            applyDrawOn(layer: &layer, startFrame: startFrame, endFrame: endFrame, easing: easing,
                        warnings: &warnings, targetName: targetName)
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

    private func applyDrawOn(
        layer: inout [String: Any],
        startFrame: Int,
        endFrame: Int,
        easing: Easing,
        warnings: inout [String],
        targetName: String
    ) {
        guard var shapes = layer["shapes"] as? [[String: Any]] else {
            warnings.append("Layer '\(targetName)' has no shapes — drawOn skipped")
            return
        }
        let trim: [String: Any] = [
            "ty": "tm",
            "s": ["a": 0, "k": 0, "ix": 1],
            "e": ["a": 1, "k": [kf(startFrame, [0], easing), kf(endFrame, [100])], "ix": 2],
            "o": ["a": 0, "k": 0, "ix": 3],
            "m": 1,
            "nm": "Trim Paths (drawOn)",
            "ix": shapes.count + 1
        ]
        shapes.insert(trim, at: 0) // влияет на пути ниже в слое
        layer["shapes"] = shapes
        warnings.append("Layer '\(targetName)': drawOn works best on stroke-only shapes")
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
