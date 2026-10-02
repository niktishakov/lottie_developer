import XCTest
@testable import LottieDeveloperMac

final class LottieCompilerTests: XCTestCase {

    private let compiler = LottieCompiler()

    // MARK: - Helpers

    private func minimalLottie(layerNames: [String] = ["test"]) -> Data {
        let layers: [[String: Any]] = layerNames.enumerated().map { idx, name in
            [
                "ty": 4,
                "nm": name,
                "ind": idx,
                "ip": 0,
                "op": 60,
                "ks": [
                    "o": ["a": 0, "k": 100, "ix": 11],
                    "p": ["a": 0, "k": [50, 50, 0], "ix": 2],
                    "s": ["a": 0, "k": [100, 100, 100], "ix": 6],
                    "r": ["a": 0, "k": 0, "ix": 10],
                    "a": ["a": 0, "k": [0, 0, 0], "ix": 1]
                ],
                "shapes": [
                    [
                        "ty": "gr",
                        "it": [
                            [
                                "ty": "sh",
                                "ks": ["a": 0, "k": [
                                    "v": [[0, -10], [10, 0], [0, 10], [-10, 0]],
                                    "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
                                    "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
                                    "c": true
                                ]]
                            ],
                            [
                                "ty": "fl",
                                "c": ["a": 0, "k": [0.08, 0.53, 0.39, 1]],
                                "o": ["a": 0, "k": 100],
                                "nm": "Fill"
                            ],
                            [
                                "ty": "tr",
                                "p": ["a": 0, "k": [0, 0]],
                                "a": ["a": 0, "k": [0, 0]],
                                "s": ["a": 0, "k": [100, 100]],
                                "r": ["a": 0, "k": 0],
                                "o": ["a": 0, "k": 100]
                            ]
                        ],
                        "nm": "Group"
                    ]
                ]
            ] as [String: Any]
        }
        let root: [String: Any] = [
            "v": "5.7.1", "fr": 30, "ip": 0, "op": 60,
            "w": 100, "h": 100,
            "layers": layers
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func compiled(_ spec: AnimationSpec, layerNames: [String] = ["test"]) throws -> [String: Any] {
        let staticData = minimalLottie(layerNames: layerNames)
        let result = try compiler.compile(staticLottie: staticData, spec: spec)

        let originAttachment = XCTAttachment(data: pretty(staticData), uniformTypeIdentifier: "public.json")
        originAttachment.name = "static_origin.json"
        originAttachment.lifetime = .keepAlways
        add(originAttachment)

        let resultAttachment = XCTAttachment(data: result.data, uniformTypeIdentifier: "public.json")
        resultAttachment.name = "compiled_result.json"
        resultAttachment.lifetime = .keepAlways
        add(resultAttachment)

        if !result.warnings.isEmpty {
            let warningsText = result.warnings.joined(separator: "\n").data(using: .utf8)!
            let warningsAttachment = XCTAttachment(data: warningsText, uniformTypeIdentifier: "public.plain-text")
            warningsAttachment.name = "warnings.txt"
            warningsAttachment.lifetime = .keepAlways
            add(warningsAttachment)
        }

        return try JSONSerialization.jsonObject(with: result.data) as! [String: Any]
    }

    private func pretty(_ data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return data }
        return formatted
    }

    private func layerKS(_ root: [String: Any], at index: Int = 0) -> [String: Any] {
        let layers = root["layers"] as! [[String: Any]]
        let matchingLayers = layers.filter { ($0["td"] as? Int) != 1 }
        return matchingLayers[index]["ks"] as! [String: Any]
    }

    private func keyframes(_ channel: [String: Any]) -> [[String: Any]] {
        channel["k"] as! [[String: Any]]
    }

    private func isAnimated(_ channel: [String: Any]) -> Bool {
        (channel["a"] as? Int) == 1
    }

    // MARK: - Basic Primitives

    func testUnanimatedLayersLiveForWholeDuration() throws {
        // Статичный источник с op=1 (как из SVG-импорта): слой без анимации не должен пропадать после 1-го кадра.
        var root = try JSONSerialization.jsonObject(with: minimalLottie(layerNames: ["a", "b"])) as! [String: Any]
        root["op"] = 1
        root["layers"] = (root["layers"] as! [[String: Any]]).map { var l = $0; l["op"] = 1; return l }
        let src = try JSONSerialization.data(withJSONObject: root)
        let spec = AnimationSpec(fps: 60, durationFrames: 120, layers: [
            LayerAnimationSpec(target: "a", animations: [
                MotionPrimitive(kind: .fadeIn, start: 0, end: 0.5, easing: .easeOut)
            ])
        ])
        let out = try JSONSerialization.jsonObject(with: compiler.compile(staticLottie: src, spec: spec).data) as! [String: Any]
        for layer in out["layers"] as! [[String: Any]] {
            XCTAssertEqual((layer["op"] as! NSNumber).intValue, 120, "layer \(layer["nm"] ?? "")")
        }
    }

    func testFadeIn() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .fadeIn, start: 0, end: 0.5, easing: .easeOut)
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)
        let opacity = ks["o"] as! [String: Any]

        XCTAssertTrue(isAnimated(opacity))
        let kfs = keyframes(opacity)
        XCTAssertEqual(kfs.count, 2)
        XCTAssertEqual((kfs[0]["s"] as! [Double])[0], 0, accuracy: 0.01)
        XCTAssertEqual((kfs[1]["s"] as! [Double])[0], 100, accuracy: 0.01)
    }

    func testFadeOut() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .fadeOut, start: 0, end: 0.5, easing: .easeIn)
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)
        let opacity = ks["o"] as! [String: Any]
        let kfs = keyframes(opacity)

        XCTAssertEqual((kfs[0]["s"] as! [Double])[0], 100, accuracy: 0.01)
        XCTAssertEqual((kfs[1]["s"] as! [Double])[0], 0, accuracy: 0.01)
    }

    func testPulse() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .pulse, start: 0, end: 1, easing: .spring,
                                params: MotionParams(amount: 120))
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)
        let scale = ks["s"] as! [String: Any]

        XCTAssertTrue(isAnimated(scale))
        let kfs = keyframes(scale)
        XCTAssertGreaterThanOrEqual(kfs.count, 3)
        XCTAssertEqual((kfs[0]["s"] as! [Double])[0], 100, accuracy: 0.01)
        XCTAssertEqual((kfs[1]["s"] as! [Double])[0], 120, accuracy: 0.01)
    }

    func testBounce() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .bounce, start: 0, end: 0.5, easing: .easeOut,
                                params: MotionParams(amount: 20))
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)
        let position = ks["p"] as! [String: Any]

        XCTAssertTrue(isAnimated(position))
        let kfs = keyframes(position)
        XCTAssertEqual(kfs.count, 3)
    }

    func testRotate() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .rotate, start: 0, end: 1, easing: .linear,
                                params: MotionParams(fromDeg: 0, toDeg: 90))
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)
        let rotation = ks["r"] as! [String: Any]
        let kfs = keyframes(rotation)

        XCTAssertEqual((kfs[0]["s"] as! [Double])[0], 0, accuracy: 0.01)
        XCTAssertEqual((kfs[1]["s"] as! [Double])[0], 90, accuracy: 0.01)
    }

    // MARK: - M5 New Primitives

    func testSquash() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .squash, start: 0, end: 0.5, easing: .easeInOut,
                                params: MotionParams(amount: 130))
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)
        let scale = ks["s"] as! [String: Any]
        let kfs = keyframes(scale)

        XCTAssertEqual(kfs.count, 3)
        let mid = kfs[1]["s"] as! [Double]
        XCTAssertEqual(mid[0], 130, accuracy: 0.01, "X should grow")
        XCTAssertEqual(mid[1], 10000.0 / 130, accuracy: 0.01, "Y should shrink inversely")
        let last = kfs[2]["s"] as! [Double]
        XCTAssertEqual(last[0], 100, accuracy: 0.01, "Should return to 100")
    }

    func testStretch() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .stretch, start: 0, end: 0.5, easing: .easeInOut,
                                params: MotionParams(amount: 130))
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)
        let scale = ks["s"] as! [String: Any]
        let kfs = keyframes(scale)

        let mid = kfs[1]["s"] as! [Double]
        XCTAssertEqual(mid[0], 10000.0 / 130, accuracy: 0.01, "X should shrink")
        XCTAssertEqual(mid[1], 130, accuracy: 0.01, "Y should grow")
    }

    func testFlash() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .flash, start: 0, end: 0.5, easing: .linear,
                                params: MotionParams(amount: 0, repeatCount: 2))
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)
        let opacity = ks["o"] as! [String: Any]
        let kfs = keyframes(opacity)

        XCTAssertGreaterThanOrEqual(kfs.count, 5)
        XCTAssertEqual((kfs[0]["s"] as! [Double])[0], 100, accuracy: 0.01)
        XCTAssertEqual((kfs[1]["s"] as! [Double])[0], 0, accuracy: 0.01)
    }

    func testFlip() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .flip, start: 0, end: 0.5, easing: .easeInOut,
                                params: MotionParams(fromDeg: 0, toDeg: 180))
            ])
        ])
        let root = try compiled(spec)
        let layers = (root["layers"] as! [[String: Any]]).filter { ($0["td"] as? Int) != 1 }
        let layer = layers[0]

        XCTAssertEqual(layer["ddd"] as? Int, 1, "Layer should be 3D")
        let ks = layer["ks"] as! [String: Any]
        let ry = ks["ry"] as! [String: Any]
        let kfs = keyframes(ry)
        XCTAssertEqual((kfs[0]["s"] as! [Double])[0], 0, accuracy: 0.01)
        XCTAssertEqual((kfs[1]["s"] as! [Double])[0], 180, accuracy: 0.01)
    }

    func testFlipXAxis() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .flip, start: 0, end: 0.5, easing: .easeInOut,
                                params: MotionParams(axis: "x"))
            ])
        ])
        let root = try compiled(spec)
        let layers = (root["layers"] as! [[String: Any]]).filter { ($0["td"] as? Int) != 1 }
        let ks = layers[0]["ks"] as! [String: Any]

        XCTAssertNotNil(ks["rx"], "Should animate rotation X")
        XCTAssertNil(ks["ry"], "Should NOT animate rotation Y")
    }

    func testColorTransition() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .colorTransition, start: 0, end: 1, easing: .easeInOut,
                                params: MotionParams(color: "#FF0000", fromColor: "#00FF00"))
            ])
        ])
        let root = try compiled(spec)
        let layers = (root["layers"] as! [[String: Any]]).filter { ($0["td"] as? Int) != 1 }
        let shapes = layers[0]["shapes"] as! [[String: Any]]
        let group = shapes[0]["it"] as! [[String: Any]]
        let fill = group.first { ($0["ty"] as? String) == "fl" }!
        let color = fill["c"] as! [String: Any]

        XCTAssertTrue(isAnimated(color), "Color should be animated")
        let kfs = keyframes(color)
        XCTAssertEqual(kfs.count, 2)
        let fromColor = kfs[0]["s"] as! [Double]
        let toColor = kfs[1]["s"] as! [Double]
        XCTAssertEqual(fromColor[1], 1.0, accuracy: 0.01, "From should be green")
        XCTAssertEqual(toColor[0], 1.0, accuracy: 0.01, "To should be red")
    }

    func testBlurIn() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .blurIn, start: 0, end: 0.5, easing: .easeOut,
                                params: MotionParams(blurAmount: 25))
            ])
        ])
        let root = try compiled(spec)
        let layers = (root["layers"] as! [[String: Any]]).filter { ($0["td"] as? Int) != 1 }
        let effects = layers[0]["ef"] as! [[String: Any]]

        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects[0]["ty"] as? Int, 29, "Should be Gaussian Blur effect")
        let ef = effects[0]["ef"] as! [[String: Any]]
        let blurriness = ef[0]
        let v = blurriness["v"] as! [String: Any]
        let kfs = keyframes(v)
        XCTAssertEqual((kfs[0]["s"] as! [Double])[0], 25, accuracy: 0.01, "Should start blurry")
        XCTAssertEqual((kfs[1]["s"] as! [Double])[0], 0, accuracy: 0.01, "Should end sharp")
    }

    func testBlurOut() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .blurOut, start: 0, end: 0.5, easing: .easeIn,
                                params: MotionParams(blurAmount: 30))
            ])
        ])
        let root = try compiled(spec)
        let layers = (root["layers"] as! [[String: Any]]).filter { ($0["td"] as? Int) != 1 }
        let effects = layers[0]["ef"] as! [[String: Any]]
        let ef = effects[0]["ef"] as! [[String: Any]]
        let v = ef[0]["v"] as! [String: Any]
        let kfs = keyframes(v)

        XCTAssertEqual((kfs[0]["s"] as! [Double])[0], 0, accuracy: 0.01, "Should start sharp")
        XCTAssertEqual((kfs[1]["s"] as! [Double])[0], 30, accuracy: 0.01, "Should end blurry")
    }

    // MARK: - Elastic Easing

    func testElasticEasing() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .scaleIn, start: 0, end: 0.5, easing: .elastic,
                                params: MotionParams(from: 0, to: 100))
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)
        let scale = ks["s"] as! [String: Any]
        let kfs = keyframes(scale)
        let outHandle = kfs[0]["o"] as! [String: Any]
        let yValues = outHandle["y"] as! [Double]

        XCTAssertGreaterThan(yValues[0], 0.8, "Elastic easing should have high y-out for overshoot")
    }

    // MARK: - Stagger & Wildcard

    func testWildcardMatching() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "item_*", animations: [
                MotionPrimitive(kind: .fadeIn, start: 0, end: 0.5, easing: .easeOut)
            ], staggerDelay: 0.1)
        ])
        let root = try compiled(spec, layerNames: ["item_1", "item_2", "item_3", "other"])
        let layers = (root["layers"] as! [[String: Any]]).filter { ($0["td"] as? Int) != 1 }

        for i in 0..<3 {
            let ks = layers[i]["ks"] as! [String: Any]
            let opacity = ks["o"] as! [String: Any]
            XCTAssertTrue(isAnimated(opacity), "item_\(i+1) should be animated")
            let kfs = keyframes(opacity)
            let startFrame = kfs[0]["t"] as! Int
            XCTAssertEqual(startFrame, i * 3, "Stagger should offset by ~3 frames (0.1s * 30fps)")
        }

        let otherKs = layers[3]["ks"] as! [String: Any]
        let otherOpacity = otherKs["o"] as! [String: Any]
        XCTAssertFalse(isAnimated(otherOpacity), "'other' should NOT be animated")
    }

    func testMissingLayerWarning() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "nonexistent", animations: [
                MotionPrimitive(kind: .fadeIn, start: 0, end: 0.5)
            ])
        ])
        let result = try compiler.compile(staticLottie: minimalLottie(), spec: spec)
        XCTAssertTrue(result.warnings.contains { $0.contains("nonexistent") })
    }

    // MARK: - Composition

    func testMultipleChannelsOnSameLayer() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .fadeIn, start: 0, end: 0.5, easing: .easeOut),
                MotionPrimitive(kind: .scaleIn, start: 0, end: 0.5, easing: .spring,
                                params: MotionParams(from: 0, to: 100)),
                MotionPrimitive(kind: .rotate, start: 0, end: 0.5, easing: .linear,
                                params: MotionParams(fromDeg: -10, toDeg: 0))
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)

        XCTAssertTrue(isAnimated(ks["o"] as! [String: Any]), "Opacity should be animated")
        XCTAssertTrue(isAnimated(ks["s"] as! [String: Any]), "Scale should be animated")
        XCTAssertTrue(isAnimated(ks["r"] as! [String: Any]), "Rotation should be animated")
    }

    // MARK: - Edge Cases

    func testInvalidStaticLottie() {
        let badData = "not json".data(using: .utf8)!
        let spec = AnimationSpec(fps: 30, durationFrames: 30, layers: [])
        XCTAssertThrowsError(try compiler.compile(staticLottie: badData, spec: spec))
    }

    func testGeneratedLayerRing() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 15,
            generatedLayers: [
                GeneratedLayer(name: "wave1", shape: .ellipse, anchor: "test",
                               width: 80, height: 80, strokeColor: "#FFFFFF", strokeWidth: 3, opacity: 0),
                GeneratedLayer(name: "wave2", shape: .ellipse, anchor: "test",
                               width: 80, height: 80, strokeColor: "#FFFFFF", strokeWidth: 2, opacity: 0)
            ],
            layers: [
                LayerAnimationSpec(target: "test", animations: [
                    MotionPrimitive(kind: .pulse, start: 0, end: 0.35, easing: .anticipate, params: MotionParams(amount: 112))
                ]),
                LayerAnimationSpec(target: "wave1", animations: [
                    MotionPrimitive(kind: .fadeIn, start: 0.08, end: 0.18, easing: .easeOut),
                    MotionPrimitive(kind: .scaleIn, start: 0.08, end: 0.38, easing: .easeOut, params: MotionParams(from: 60, to: 100)),
                    MotionPrimitive(kind: .fadeOut, start: 0.28, end: 0.38, easing: .easeIn)
                ]),
                LayerAnimationSpec(target: "wave2", animations: [
                    MotionPrimitive(kind: .fadeIn, start: 0.14, end: 0.24, easing: .easeOut),
                    MotionPrimitive(kind: .scaleIn, start: 0.14, end: 0.42, easing: .easeOut, params: MotionParams(from: 50, to: 100)),
                    MotionPrimitive(kind: .fadeOut, start: 0.32, end: 0.42, easing: .easeIn)
                ])
            ])
        let root = try compiled(spec)
        let allLayers = root["layers"] as! [[String: Any]]
        let nonMatte = allLayers.filter { ($0["td"] as? Int) != 1 }

        XCTAssertEqual(nonMatte.count, 3, "Should have 3 layers: 2 generated + 1 original")
        XCTAssertEqual(nonMatte[0]["nm"] as? String, "wave1")
        XCTAssertEqual(nonMatte[1]["nm"] as? String, "wave2")
        XCTAssertEqual(nonMatte[2]["nm"] as? String, "test")

        let wave1Ks = nonMatte[0]["ks"] as! [String: Any]
        XCTAssertTrue(isAnimated(wave1Ks["o"] as! [String: Any]), "wave1 opacity should be animated")
        XCTAssertTrue(isAnimated(wave1Ks["s"] as! [String: Any]), "wave1 scale should be animated")

        let wave1Pos = (wave1Ks["p"] as! [String: Any])["k"] as! [Double]
        XCTAssertEqual(wave1Pos[0], 50, accuracy: 0.01, "wave1 should inherit anchor X")
        XCTAssertEqual(wave1Pos[1], 50, accuracy: 0.01, "wave1 should inherit anchor Y")

        let wave1Shapes = nonMatte[0]["shapes"] as! [[String: Any]]
        let groupItems = (wave1Shapes[0]["it"] as! [[String: Any]])
        let hasEllipse = groupItems.contains { ($0["ty"] as? String) == "el" }
        let hasStroke = groupItems.contains { ($0["ty"] as? String) == "st" }
        let hasFill = groupItems.contains { ($0["ty"] as? String) == "fl" }
        XCTAssertTrue(hasEllipse, "Should contain ellipse shape")
        XCTAssertTrue(hasStroke, "Should contain stroke")
        XCTAssertFalse(hasFill, "Ring should NOT have fill")
    }

    // MARK: - Shape Editing

    func testRemoveFill() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 15, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .removeFill, start: 0, end: 0, easing: .linear)
            ])
        ])
        let root = try compiled(spec)
        let layers = (root["layers"] as! [[String: Any]]).filter { ($0["td"] as? Int) != 1 }
        let shapes = layers[0]["shapes"] as! [[String: Any]]
        let group = shapes[0]["it"] as! [[String: Any]]
        let hasFill = group.contains { ($0["ty"] as? String) == "fl" }
        XCTAssertFalse(hasFill, "Fill should be removed")
    }

    func testRemoveStroke() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 15, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .removeStroke, start: 0, end: 0, easing: .linear)
            ])
        ])
        let root = try compiled(spec)
        let layers = (root["layers"] as! [[String: Any]]).filter { ($0["td"] as? Int) != 1 }
        let shapes = layers[0]["shapes"] as! [[String: Any]]
        let group = shapes[0]["it"] as! [[String: Any]]
        let hasStroke = group.contains { ($0["ty"] as? String) == "st" }
        XCTAssertFalse(hasStroke, "Stroke should be removed")
    }

    func testAddStroke() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 15, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .removeFill, start: 0, end: 0, easing: .linear),
                MotionPrimitive(kind: .addStroke, start: 0, end: 0, easing: .linear,
                                params: MotionParams(color: "#FF0000", strokeWidth: 4))
            ])
        ])
        let root = try compiled(spec)
        let layers = (root["layers"] as! [[String: Any]]).filter { ($0["td"] as? Int) != 1 }
        let shapes = layers[0]["shapes"] as! [[String: Any]]
        let group = shapes[0]["it"] as! [[String: Any]]
        let stroke = group.first { ($0["ty"] as? String) == "st" }
        XCTAssertNotNil(stroke, "Stroke should be added")
        let w = (stroke?["w"] as? [String: Any])?["k"] as? Double
        XCTAssertEqual(w, 4, "Stroke width should be 4")
        let hasFill = group.contains { ($0["ty"] as? String) == "fl" }
        XCTAssertFalse(hasFill, "Fill should be removed")
    }

    func testHideLayer() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 15, layers: [
            LayerAnimationSpec(target: "test", animations: [
                MotionPrimitive(kind: .hideLayer, start: 0, end: 0, easing: .linear)
            ])
        ])
        let root = try compiled(spec)
        let ks = layerKS(root)
        let opacity = ks["o"] as! [String: Any]
        XCTAssertEqual(opacity["a"] as? Int, 0, "Should be static, not animated")
        XCTAssertEqual(opacity["k"] as? Double, 0, "Opacity should be 0")
    }

    func testGeneratedLayerMissingAnchor() throws {
        let spec = AnimationSpec(fps: 30, durationFrames: 15,
            generatedLayers: [
                GeneratedLayer(name: "orphan", shape: .ellipse, anchor: "nonexistent")
            ],
            layers: [
                LayerAnimationSpec(target: "test", animations: [
                    MotionPrimitive(kind: .fadeIn, start: 0, end: 0.5)
                ])
            ])
        let result = try compiler.compile(staticLottie: minimalLottie(), spec: spec)
        XCTAssertTrue(result.warnings.contains { $0.contains("nonexistent") })
    }

    func testFPSClamping() throws {
        let spec = AnimationSpec(fps: 1000, durationFrames: 30, layers: [])
        let result = try compiler.compile(staticLottie: minimalLottie(), spec: spec)
        let root = try JSONSerialization.jsonObject(with: result.data) as! [String: Any]
        XCTAssertEqual(root["fr"] as? Int, 60, "FPS should be clamped to 60")
    }
}
