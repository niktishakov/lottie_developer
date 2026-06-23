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
        let compW = (root["w"] as? NSNumber)?.doubleValue ?? 100
        let compH = (root["h"] as? NSNumber)?.doubleValue ?? 100
        var warnings: [String] = []

        // Индекс слоёв по имени. При дублирующихся именах берём первый и предупреждаем.
        var indexByName: [String: Int] = [:]
        for (idx, layer) in layers.enumerated() {
            guard let name = layer["nm"] as? String else { continue }
            if indexByName[name] == nil {
                indexByName[name] = idx
            }
        }

        // Phase 0: Generate synthetic layers
        var nextInd = (layers.compactMap { $0["ind"] as? Int }.max() ?? 0) + 1
        if let generated = spec.generatedLayers {
            var newLayers: [[String: Any]] = []
            for gen in generated {
                if indexByName[gen.name] != nil {
                    warnings.append("Generated layer '\(gen.name)': name conflicts with existing layer — skipped")
                    continue
                }
                guard let anchorIdx = indexByName[gen.anchor] else {
                    warnings.append("Generated layer '\(gen.name)': anchor '\(gen.anchor)' not found — skipped")
                    continue
                }
                let anchorLayer = layers[anchorIdx]
                let newLayer = buildGeneratedLayer(gen, anchorLayer: anchorLayer, ind: nextInd, duration: duration)
                newLayers.append(newLayer)
                nextInd += 1
            }
            if !newLayers.isEmpty {
                layers.insert(contentsOf: newLayers, at: 0)
                indexByName.removeAll()
                for (idx, layer) in layers.enumerated() {
                    guard let name = layer["nm"] as? String else { continue }
                    if indexByName[name] == nil { indexByName[name] = idx }
                }
            }
        }

        var matteInserts: [(layerIdx: Int, matte: [String: Any])] = []
        var clipInserts: [(layerIdx: Int, matte: [String: Any])] = []
        let maxInd = nextInd

        for layerSpec in spec.layers {
            let matches: [(name: String, idx: Int)]
            if layerSpec.target.contains("*") {
                matches = matchWildcard(layerSpec.target, indexByName: indexByName)
            } else if let idx = indexByName[layerSpec.target] {
                matches = [(layerSpec.target, idx)]
            } else {
                matches = []
            }

            if matches.isEmpty {
                warnings.append("Layer '\(layerSpec.target)' not found — animations skipped")
                continue
            }

            let stagger = layerSpec.staggerDelay ?? 0

            for (matchIndex, match) in matches.enumerated() {
                let idx = match.idx
                let timeOffset = stagger * Double(matchIndex)

                var layer = layers[idx]
                var ks = layer["ks"] as? [String: Any] ?? [:]
                let originalKs = ks
                var needsClip = false

                for primitive in layerSpec.animations {
                    let p = timeOffset > 0
                        ? MotionPrimitive(kind: primitive.kind,
                                          start: primitive.start + timeOffset,
                                          end: primitive.end + timeOffset,
                                          easing: primitive.easing,
                                          params: primitive.params)
                        : primitive

                    if p.kind == .drawOn {
                        let startFrame = frame(p.start, fps: fps)
                        var endFrame = frame(p.end, fps: fps)
                        if endFrame <= startFrame { endFrame = startFrame + 1 }
                        let shapes = layer["shapes"] as? [[String: Any]] ?? []

                        if containsType(shapes, "st") {
                            var mutableShapes = shapes
                            injectTrimOnStrokes(&mutableShapes, startFrame: startFrame, endFrame: endFrame, easing: p.easing)
                            layer["shapes"] = mutableShapes
                        } else if let matte = buildDrawOnMatte(
                            targetLayer: layer, shapes: shapes,
                            startFrame: startFrame, endFrame: endFrame,
                            easing: p.easing, duration: duration,
                            matteInd: maxInd + 100 + matteInserts.count
                        ) {
                            matteInserts.append((layerIdx: idx, matte: matte))
                        }
                    } else {
                        applyPrimitive(
                            p,
                            ks: &ks,
                            originalKs: originalKs,
                            layer: &layer,
                            fps: fps,
                            warnings: &warnings,
                            targetName: match.name,
                            needsClip: &needsClip
                        )
                    }
                }

                layer["ks"] = ks
                layer["ip"] = 0
                layer["op"] = duration
                layers[idx] = layer

                let hasDrawOnMatte = matteInserts.contains { $0.layerIdx == idx }
                if needsClip && !hasDrawOnMatte {
                    let clip = buildClipMatte(
                        compW: compW, compH: compH,
                        duration: duration,
                        matteInd: maxInd + 300 + clipInserts.count
                    )
                    clipInserts.append((layerIdx: idx, matte: clip))
                }
            }
        }

        let allInserts = (matteInserts + clipInserts).sorted(by: { $0.layerIdx > $1.layerIdx })
        for insert in allInserts {
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
        originalKs: [String: Any],
        layer: inout [String: Any],
        fps: Int,
        warnings: inout [String],
        targetName: String,
        needsClip: inout Bool
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
            let base = vectorBase(originalKs, "p", fallback: [0, 0, 0])
            let from = offset(base, direction: p.direction, distance: p.distance ?? 100, reversed: false)
            setVector(&ks, "p", ix: 2, [
                kf(startFrame, from, easing), kf(endFrame, base)
            ])
            needsClip = true
        case .slideOut:
            let base = vectorBase(originalKs, "p", fallback: [0, 0, 0])
            let to = offset(base, direction: p.direction, distance: p.distance ?? 100, reversed: false)
            setVector(&ks, "p", ix: 2, [
                kf(startFrame, base, easing), kf(endFrame, to)
            ])
            needsClip = true
        case .scaleIn:
            let from = normalizeScale(p.from ?? 0)
            let to = normalizeScale(p.to ?? 100)
            setVector(&ks, "s", ix: 6, [
                kf(startFrame, [from, from, 100], easing), kf(endFrame, [to, to, 100])
            ])
        case .scaleOut:
            let from = normalizeScale(p.from ?? 100)
            let to = normalizeScale(p.to ?? 0)
            setVector(&ks, "s", ix: 6, [
                kf(startFrame, [from, from, 100], easing), kf(endFrame, [to, to, 100])
            ])
        case .rotate:
            let base = scalarBase(originalKs, "r", fallback: 0)
            let from = p.fromDeg ?? base
            let to = p.toDeg ?? (base + 360)
            setScalar(&ks, "r", ix: 10, [
                kf(startFrame, [from], easing), kf(endFrame, [to])
            ])
        case .pulse:
            let peak = normalizeScale(p.amount ?? 110)
            let repeats = max(1, p.repeatCount ?? 1)
            setVector(&ks, "s", ix: 6, pulseKeyframes(
                startFrame: startFrame, endFrame: endFrame, peak: peak, repeats: repeats, easing: easing
            ))
        case .bounce:
            let base = vectorBase(originalKs, "p", fallback: [0, 0, 0])
            let amount = p.amount ?? 20
            setVector(&ks, "p", ix: 2, bounceKeyframes(
                base: base, startFrame: startFrame, endFrame: endFrame, amount: amount
            ))
        case .wiggle:
            let base = vectorBase(originalKs, "p", fallback: [0, 0, 0])
            let amount = p.amount ?? 10
            let freq = max(1, Int((p.frequency ?? 4).rounded()))
            setVector(&ks, "p", ix: 2, wiggleKeyframes(
                base: base, startFrame: startFrame, endFrame: endFrame, amount: amount, frequency: freq
            ))
        case .drawOn:
            break // drawOn обрабатывается в compile() через track matte
        case .spin:
            let base = scalarBase(originalKs, "r", fallback: 0)
            let turns = Double(max(1, p.repeatCount ?? 1))
            setScalar(&ks, "r", ix: 10, [
                kf(startFrame, [base], .linear), kf(endFrame, [base + 360 * turns])
            ])
        case .float:
            let base = vectorBase(originalKs, "p", fallback: [0, 0, 0])
            let amount = p.amount ?? 12
            setVector(&ks, "p", ix: 2, floatKeyframes(base: base, startFrame: startFrame, endFrame: endFrame, amount: amount))
        case .breathe:
            let peak = normalizeScale(p.amount ?? 106)
            setVector(&ks, "s", ix: 6, pulseKeyframes(
                startFrame: startFrame, endFrame: endFrame, peak: peak,
                repeats: max(1, p.repeatCount ?? 1), easing: .easeInOut
            ))
        case .swing:
            let base = scalarBase(originalKs, "r", fallback: 0)
            let amount = p.amount ?? 10
            setScalar(&ks, "r", ix: 10, swingKeyframes(base: base, startFrame: startFrame, endFrame: endFrame, amount: amount))
        case .followPath:
            let base = vectorBase(originalKs, "p", fallback: [0, 0, 0])
            if let points = p.path, points.count >= 2 {
                setVector(&ks, "p", ix: 2, followPathKeyframes(
                    base: base, points: points, startFrame: startFrame, endFrame: endFrame, easing: easing
                ))
            } else {
                warnings.append("Layer '\(targetName)': followPath needs params.path with ≥2 points — skipped")
            }
        case .recolor:
            if let hex = p.color, let rgba = parseHex(hex) {
                applyRecolor(layer: &layer, rgba: rgba)
            } else {
                warnings.append("Layer '\(targetName)': recolor needs params.color (hex) — skipped")
            }
        case .squash:
            let amount = normalizeScale(p.amount ?? 130)
            let inverse = 10000.0 / amount
            let mid = startFrame + (endFrame - startFrame) / 2
            setVector(&ks, "s", ix: 6, [
                kf(startFrame, [100, 100, 100], easing),
                kf(mid, [amount, inverse, 100], easing),
                kf(endFrame, [100, 100, 100])
            ])
        case .stretch:
            let amount = normalizeScale(p.amount ?? 130)
            let inverse = 10000.0 / amount
            let mid = startFrame + (endFrame - startFrame) / 2
            setVector(&ks, "s", ix: 6, [
                kf(startFrame, [100, 100, 100], easing),
                kf(mid, [inverse, amount, 100], easing),
                kf(endFrame, [100, 100, 100])
            ])
        case .flash:
            let low = p.amount ?? 0
            let repeats = max(1, p.repeatCount ?? 1)
            setScalar(&ks, "o", ix: 11, flashKeyframes(
                startFrame: startFrame, endFrame: endFrame, low: low, repeats: repeats, easing: easing
            ))
        case .flip:
            layer["ddd"] = 1
            let flipAxis = (p.axis == "x") ? "rx" : "ry"
            let ixVal = (p.axis == "x") ? 8 : 9
            let from = p.fromDeg ?? 0
            let to = p.toDeg ?? 180
            setScalar(&ks, flipAxis, ix: ixVal, [
                kf(startFrame, [from], easing), kf(endFrame, [to])
            ])
        case .colorTransition:
            if let toHex = p.color, let toRGBA = parseHex(toHex) {
                let fromRGBA: [Double]
                if let fromHex = p.fromColor, let parsed = parseHex(fromHex) {
                    fromRGBA = parsed
                } else {
                    fromRGBA = readCurrentColor(layer: layer) ?? [0, 0, 0, 1]
                }
                applyColorTransition(
                    layer: &layer, from: fromRGBA, to: toRGBA,
                    startFrame: startFrame, endFrame: endFrame, easing: easing
                )
            } else {
                warnings.append("Layer '\(targetName)': colorTransition needs params.color — skipped")
            }
        case .blurIn:
            let amount = p.blurAmount ?? 20
            applyBlurEffect(layer: &layer, fromBlur: amount, toBlur: 0,
                            startFrame: startFrame, endFrame: endFrame, easing: easing)
        case .blurOut:
            let amount = p.blurAmount ?? 20
            applyBlurEffect(layer: &layer, fromBlur: 0, toBlur: amount,
                            startFrame: startFrame, endFrame: endFrame, easing: easing)
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

    private func buildClipMatte(compW: Double, compH: Double, duration: Int, matteInd: Int) -> [String: Any] {
        let rect: [String: Any] = [
            "ty": "rc",
            "d": 1,
            "s": ["a": 0, "k": [compW, compH]],
            "p": ["a": 0, "k": [0, 0]],
            "r": ["a": 0, "k": 0],
            "nm": "Clip Rect"
        ]
        let fill: [String: Any] = [
            "ty": "fl",
            "c": ["a": 0, "k": [1, 1, 1, 1]],
            "o": ["a": 0, "k": 100],
            "nm": "Clip Fill"
        ]
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
            "it": [rect, fill, tr],
            "nm": "Clip Group"
        ]
        return [
            "ty": 4,
            "nm": "clip-matte",
            "shapes": [group],
            "ip": 0,
            "op": duration,
            "st": 0,
            "sr": 1,
            "td": 1,
            "ks": [
                "o": ["a": 0, "k": 100, "ix": 11],
                "p": ["a": 0, "k": [compW / 2, compH / 2, 0], "ix": 2],
                "a": ["a": 0, "k": [0, 0, 0], "ix": 1],
                "s": ["a": 0, "k": [100, 100, 100], "ix": 6],
                "r": ["a": 0, "k": 0, "ix": 10]
            ],
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
        let merged = mergeKeyframes(existing: ks[key], new: keyframes)
        ks[key] = ["a": 1, "k": merged, "ix": resolvedIx]
    }

    private func setVector(_ ks: inout [String: Any], _ key: String, ix: Int, _ keyframes: [[String: Any]]) {
        let resolvedIx = existingIx(ks, key) ?? ix
        let merged = mergeKeyframes(existing: ks[key], new: keyframes)
        ks[key] = ["a": 1, "k": merged, "ix": resolvedIx]
    }

    private func mergeKeyframes(existing: Any?, new: [[String: Any]]) -> [[String: Any]] {
        guard let ch = existing as? [String: Any],
              (ch["a"] as? Int) == 1,
              let old = ch["k"] as? [[String: Any]] else {
            return new
        }
        guard let newStart = new.first?["t"] as? Int else { return new }
        var base = old.filter { ($0["t"] as? Int ?? 0) < newStart }
        if !base.isEmpty {
            var last = base[base.count - 1]
            last.removeValue(forKey: "o")
            last.removeValue(forKey: "i")
            last["h"] = 1
            base[base.count - 1] = last
        }
        return base + new
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
        case .elastic:      return (0.175, 0.885, 0.32, 1.275) // выраженный перелёт
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

    // MARK: - Wildcard matching

    private func matchWildcard(_ pattern: String, indexByName: [String: Int]) -> [(name: String, idx: Int)] {
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return indexByName
                .filter { $0.key.hasPrefix(prefix) }
                .sorted { $0.value < $1.value }
                .map { ($0.key, $0.value) }
        } else if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return indexByName
                .filter { $0.key.hasSuffix(suffix) }
                .sorted { $0.value < $1.value }
                .map { ($0.key, $0.value) }
        }
        return []
    }

    // MARK: - Animation Inspector

    static func inspectAnimations(lottieData: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: lottieData)) as? [String: Any],
              let layers = root["layers"] as? [[String: Any]] else { return nil }

        let fps = (root["fr"] as? NSNumber)?.intValue ?? 30
        let op = (root["op"] as? NSNumber)?.intValue ?? 0

        var lines: [String] = []
        lines.append("Composition: \(fps)fps, \(op) frames (\(String(format: "%.1f", Double(op) / Double(fps)))s)")

        for layer in layers {
            guard let name = layer["nm"] as? String else { continue }
            let ks = layer["ks"] as? [String: Any] ?? [:]

            var animated: [String] = []
            for (key, label) in [("o","opacity"),("p","position"),("s","scale"),("r","rotation"),("rx","rotationX"),("ry","rotationY")] {
                if let ch = ks[key] as? [String: Any], (ch["a"] as? Int) == 1,
                   let kfs = ch["k"] as? [[String: Any]] {
                    let times = kfs.compactMap { $0["t"] as? Int }
                    if let first = times.first, let last = times.last {
                        let values = kfs.compactMap { ($0["s"] as? [Any])?.first as? NSNumber }.map { $0.doubleValue }
                        let valStr = values.isEmpty ? "" : " [\(values.map { String(format: "%.0f", $0) }.joined(separator: "→"))]"
                        animated.append("\(label) \(first)→\(last)f\(valStr)")
                    }
                }
            }

            if let ef = layer["ef"] as? [[String: Any]], !ef.isEmpty {
                let names = ef.compactMap { $0["nm"] as? String }
                animated.append("effects: \(names.joined(separator: ", "))")
            }

            if let shapes = layer["shapes"] as? [[String: Any]] {
                if hasAnimatedProperty(shapes, types: ["fl", "st"], prop: "c") { animated.append("animated color") }
                if containsTrimPath(shapes) { animated.append("trim path") }
            }

            if animated.isEmpty {
                lines.append("  \(name): static")
            } else {
                lines.append("  \(name): \(animated.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func hasAnimatedProperty(_ shapes: [[String: Any]], types: [String], prop: String) -> Bool {
        for s in shapes {
            let ty = s["ty"] as? String ?? ""
            if types.contains(ty), let ch = s[prop] as? [String: Any], (ch["a"] as? Int) == 1 { return true }
            if ty == "gr", let items = s["it"] as? [[String: Any]], hasAnimatedProperty(items, types: types, prop: prop) { return true }
        }
        return false
    }

    private static func containsTrimPath(_ shapes: [[String: Any]]) -> Bool {
        for s in shapes {
            if (s["ty"] as? String) == "tm" { return true }
            if (s["ty"] as? String) == "gr", let items = s["it"] as? [[String: Any]], containsTrimPath(items) { return true }
        }
        return false
    }

    // MARK: - Generated Layers

    private func buildGeneratedLayer(
        _ gen: GeneratedLayer, anchorLayer: [String: Any], ind: Int, duration: Int
    ) -> [String: Any] {
        let anchorKs = anchorLayer["ks"] as? [String: Any] ?? [:]
        let pos = vectorBase(anchorKs, "p", fallback: [0, 0, 0])
        let w = gen.width ?? 100
        let h = gen.height ?? 100
        let opacity = gen.opacity ?? 0

        let shapeItem: [String: Any]
        switch gen.shape {
        case .ellipse:
            shapeItem = ["ty": "el", "p": ["a": 0, "k": [0, 0]], "s": ["a": 0, "k": [w, h]], "nm": "Ellipse"]
        case .rectangle:
            shapeItem = ["ty": "rc", "d": 1, "p": ["a": 0, "k": [0, 0]], "s": ["a": 0, "k": [w, h]], "r": ["a": 0, "k": 0], "nm": "Rect"]
        }

        var groupItems: [[String: Any]] = [shapeItem]

        if let fillHex = gen.fillColor, let rgba = parseHex(fillHex) {
            groupItems.append(["ty": "fl", "c": ["a": 0, "k": rgba], "o": ["a": 0, "k": 100], "nm": "Fill"])
        }
        if let strokeHex = gen.strokeColor, let rgba = parseHex(strokeHex) {
            groupItems.append([
                "ty": "st", "c": ["a": 0, "k": rgba], "o": ["a": 0, "k": 100],
                "w": ["a": 0, "k": gen.strokeWidth ?? 2], "lc": 2, "lj": 2, "nm": "Stroke"
            ])
        }
        if gen.fillColor == nil && gen.strokeColor == nil {
            groupItems.append(["ty": "fl", "c": ["a": 0, "k": [1, 1, 1, 1]], "o": ["a": 0, "k": 100], "nm": "Fill"])
        }

        groupItems.append([
            "ty": "tr",
            "p": ["a": 0, "k": [0, 0]], "a": ["a": 0, "k": [0, 0]],
            "s": ["a": 0, "k": [100, 100]], "r": ["a": 0, "k": 0], "o": ["a": 0, "k": 100]
        ])

        return [
            "ty": 4, "nm": gen.name, "ind": ind, "ip": 0, "op": duration, "st": 0, "sr": 1,
            "shapes": [["ty": "gr", "it": groupItems, "nm": "Generated Group"]],
            "ks": [
                "o": ["a": 0, "k": opacity, "ix": 11],
                "p": ["a": 0, "k": pos, "ix": 2],
                "a": ["a": 0, "k": [0, 0, 0], "ix": 1],
                "s": ["a": 0, "k": [100, 100, 100], "ix": 6],
                "r": ["a": 0, "k": 0, "ix": 10]
            ]
        ]
    }

    // MARK: - Utilities

    private func normalizeScale(_ v: Double) -> Double {
        v > 0 && v < 10 ? v * 100 : v
    }

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

    // MARK: - Flash

    private func flashKeyframes(startFrame: Int, endFrame: Int, low: Double, repeats: Int, easing: Easing) -> [[String: Any]] {
        var frames: [[String: Any]] = []
        let total = endFrame - startFrame
        let perCycle = max(2, total / repeats)
        var t = startFrame
        for _ in 0..<repeats {
            let mid = t + perCycle / 2
            let endCycle = t + perCycle
            frames.append(kf(t, [100], easing))
            frames.append(kf(mid, [low], easing))
            frames.append(kf(endCycle, [100]))
            t = endCycle
        }
        return normalizeTimes(frames, defaultValues: [100])
    }

    // MARK: - Blur

    private func applyBlurEffect(layer: inout [String: Any], fromBlur: Double, toBlur: Double,
                                 startFrame: Int, endFrame: Int, easing: Easing) {
        let blurriness: [String: Any] = [
            "ty": 0,
            "nm": "Blurriness",
            "mn": "ADBE Gaussian Blur 2-0001",
            "ix": 1,
            "v": ["a": 1, "k": [kf(startFrame, [fromBlur], easing), kf(endFrame, [toBlur])]]
        ]
        let dimensions: [String: Any] = [
            "ty": 7,
            "nm": "Blur Dimensions",
            "mn": "ADBE Gaussian Blur 2-0002",
            "ix": 2,
            "v": ["a": 0, "k": 1]
        ]
        let repeatEdge: [String: Any] = [
            "ty": 7,
            "nm": "Repeat Edge Pixels",
            "mn": "ADBE Gaussian Blur 2-0003",
            "ix": 3,
            "v": ["a": 0, "k": 1]
        ]
        let blur: [String: Any] = [
            "ty": 29,
            "nm": "Gaussian Blur",
            "np": 5,
            "mn": "ADBE Gaussian Blur 2",
            "ix": 1,
            "en": 1,
            "ef": [blurriness, dimensions, repeatEdge]
        ]
        var effects = layer["ef"] as? [[String: Any]] ?? []
        effects.append(blur)
        layer["ef"] = effects
    }

    // MARK: - Color Transition

    private func applyColorTransition(layer: inout [String: Any], from: [Double], to: [Double],
                                      startFrame: Int, endFrame: Int, easing: Easing) {
        if var shapes = layer["shapes"] as? [[String: Any]] {
            colorTransitionShapes(&shapes, from: from, to: to,
                                  startFrame: startFrame, endFrame: endFrame, easing: easing)
            layer["shapes"] = shapes
        }
    }

    private func colorTransitionShapes(_ shapes: inout [[String: Any]], from: [Double], to: [Double],
                                       startFrame: Int, endFrame: Int, easing: Easing) {
        for i in shapes.indices {
            let ty = shapes[i]["ty"] as? String
            if ty == "fl" || ty == "st" {
                if var c = shapes[i]["c"] as? [String: Any] {
                    c["a"] = 1
                    c["k"] = [kf(startFrame, from, easing), kf(endFrame, to)]
                    shapes[i]["c"] = c
                }
            } else if ty == "gr" {
                if var items = shapes[i]["it"] as? [[String: Any]] {
                    colorTransitionShapes(&items, from: from, to: to,
                                          startFrame: startFrame, endFrame: endFrame, easing: easing)
                    shapes[i]["it"] = items
                }
            }
        }
    }

    private func readCurrentColor(layer: [String: Any]) -> [Double]? {
        guard let shapes = layer["shapes"] as? [[String: Any]] else { return nil }
        return findFirstColor(shapes)
    }

    private func findFirstColor(_ shapes: [[String: Any]]) -> [Double]? {
        for s in shapes {
            let ty = s["ty"] as? String
            if ty == "fl" || ty == "st" {
                if let c = s["c"] as? [String: Any], let k = c["k"] as? [Any] {
                    let vals = k.compactMap { ($0 as? NSNumber)?.doubleValue }
                    if vals.count >= 3 { return vals }
                }
            } else if ty == "gr", let items = s["it"] as? [[String: Any]] {
                if let found = findFirstColor(items) { return found }
            }
        }
        return nil
    }

    // MARK: - Recolor

    private func parseHex(_ hex: String) -> [Double]? {
        var h = hex
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        let chars: [Character]
        switch h.count {
        case 3:
            chars = h.flatMap { [$0, $0] }
        case 6:
            chars = Array(h)
        default:
            return nil
        }
        guard chars.count == 6 else { return nil }
        let str = String(chars)
        guard let val = UInt32(str, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF) / 255.0
        let g = Double((val >> 8) & 0xFF) / 255.0
        let b = Double(val & 0xFF) / 255.0
        return [r, g, b, 1]
    }

    private func applyRecolor(layer: inout [String: Any], rgba: [Double]) {
        if var shapes = layer["shapes"] as? [[String: Any]] {
            recolorShapes(&shapes, rgba: rgba)
            layer["shapes"] = shapes
        }
    }

    private func recolorShapes(_ shapes: inout [[String: Any]], rgba: [Double]) {
        for i in shapes.indices {
            let ty = shapes[i]["ty"] as? String
            if ty == "fl" || ty == "st" {
                if var c = shapes[i]["c"] as? [String: Any] {
                    c["a"] = 0
                    c["k"] = rgba
                    shapes[i]["c"] = c
                }
            } else if ty == "gr" {
                if var items = shapes[i]["it"] as? [[String: Any]] {
                    recolorShapes(&items, rgba: rgba)
                    shapes[i]["it"] = items
                }
            }
        }
    }
}
