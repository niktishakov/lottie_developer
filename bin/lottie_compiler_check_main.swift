import Foundation

// Standalone-проверка LottieCompiler на хосте (без iOS-симулятора).
// Запуск: bin/check_lottie_compiler.sh
// Компилируется вместе с Sources/AI/Spec/*.swift.

private func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("ASSERT FAILED: " + msg + "\n").utf8))
    exit(1)
}
private func check(_ cond: Bool, _ msg: String) { if !cond { fail(msg) } }

@main
struct CompilerCheck {
    static func main() {
        let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
        let staticPath = root + "/Sources/Resources/rocket_static_simplified.json"
        guard let staticData = FileManager.default.contents(atPath: staticPath) else {
            fail("cannot read static lottie at \(staticPath)")
        }

        let spec = AnimationSpec(
            fps: 30,
            durationFrames: 90,
            layers: [
                LayerAnimationSpec(target: "Body", animations: [
                    MotionPrimitive(kind: .fadeIn, start: 0, end: 0.5, easing: .easeOut),
                    MotionPrimitive(kind: .slideIn, start: 0, end: 0.6, easing: .easeOut,
                                    params: MotionParams(direction: "up", distance: 80))
                ]),
                LayerAnimationSpec(target: "Iilum", animations: [
                    MotionPrimitive(kind: .pulse, start: 0.5, end: 2.5, easing: .easeInOut,
                                    params: MotionParams(amount: 130, repeatCount: 2))
                ]),
                LayerAnimationSpec(target: "2 wing", animations: [
                    MotionPrimitive(kind: .rotate, start: 0, end: 1.0, easing: .linear,
                                    params: MotionParams(fromDeg: 0, toDeg: 15))
                ]),
                LayerAnimationSpec(target: "DoesNotExist", animations: [
                    MotionPrimitive(kind: .fadeIn, start: 0, end: 1)
                ])
            ]
        )

        let compiler = LottieCompiler()
        let result: LottieCompiler.CompileResult
        do { result = try compiler.compile(staticLottie: staticData, spec: spec) }
        catch { fail("compile threw: \(error)") }

        guard let outRoot = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any] else {
            fail("compiled output is not a JSON object")
        }
        check((outRoot["fr"] as? NSNumber)?.intValue == 30, "fr should be 30")
        check((outRoot["op"] as? NSNumber)?.intValue == 90, "op should be 90")
        check((outRoot["ip"] as? NSNumber)?.intValue == 0, "ip should be 0")

        guard let layers = outRoot["layers"] as? [[String: Any]] else { fail("no layers") }
        func layer(_ name: String) -> [String: Any]? { layers.first { ($0["nm"] as? String) == name } }

        guard let body = layer("Body"), let bodyKs = body["ks"] as? [String: Any],
              let o = bodyKs["o"] as? [String: Any], let oKeys = o["k"] as? [[String: Any]] else {
            fail("Body opacity keyframes missing")
        }
        check((o["a"] as? NSNumber)?.intValue == 1, "Body opacity should be animated")
        check(oKeys.count == 2, "Body opacity should have 2 keyframes")
        check((oKeys.first?["t"] as? NSNumber)?.intValue == 0, "first opacity kf at t=0")
        check((oKeys.last?["t"] as? NSNumber)?.intValue == 15, "last opacity kf at t=15")
        check(oKeys.last?["i"] == nil, "last keyframe must not carry easing handles")
        check(oKeys.first?["i"] != nil, "non-last keyframe must carry easing handles")

        guard let p = bodyKs["p"] as? [String: Any], (p["a"] as? NSNumber)?.intValue == 1 else {
            fail("Body position should be animated")
        }

        guard let iilum = layer("Iilum"), let iks = iilum["ks"] as? [String: Any],
              let s = iks["s"] as? [String: Any], let sKeys = s["k"] as? [[String: Any]] else {
            fail("Iilum scale keyframes missing")
        }
        check(sKeys.count >= 4, "pulse should produce multiple keyframes")
        var lastT = Int.min
        for k in sKeys {
            let t = (k["t"] as? NSNumber)?.intValue ?? -1
            check(t > lastT, "pulse keyframe times must strictly increase")
            lastT = t
        }

        guard let wing = layer("2 wing"), let wks = wing["ks"] as? [String: Any],
              let r = wks["r"] as? [String: Any], (r["a"] as? NSNumber)?.intValue == 1 else {
            fail("2 wing rotation should be animated")
        }

        check(result.warnings.contains { $0.contains("DoesNotExist") }, "expected warning for DoesNotExist")

        let srcLayers = ((try? JSONSerialization.jsonObject(with: staticData)) as? [String: Any])?["layers"] as? [[String: Any]]
        check(srcLayers?.count == layers.count, "layer count must be preserved")

        // M4: новые примитивы + overshoot easing компилируются и анимируют нужные каналы.
        let m4 = AnimationSpec(
            fps: 60,
            durationFrames: 180,
            layers: [
                LayerAnimationSpec(target: "Body", animations: [
                    MotionPrimitive(kind: .scaleIn, start: 0, end: 0.5, easing: .easeOutBack),
                    MotionPrimitive(kind: .float, start: 0.6, end: 3.0, easing: .easeInOut, params: MotionParams(amount: 14))
                ]),
                LayerAnimationSpec(target: "2 wing", animations: [
                    MotionPrimitive(kind: .spin, start: 0, end: 3.0, easing: .linear, params: MotionParams(repeatCount: 2))
                ]),
                LayerAnimationSpec(target: "Iilum", animations: [
                    MotionPrimitive(kind: .breathe, start: 0.5, end: 3.0, easing: .easeInOut, params: MotionParams(amount: 106, repeatCount: 3))
                ]),
                LayerAnimationSpec(target: "1 wing", animations: [
                    MotionPrimitive(kind: .swing, start: 0.5, end: 3.0, easing: .easeInOut, params: MotionParams(amount: 8))
                ])
            ]
        )
        let m4Result: LottieCompiler.CompileResult
        do { m4Result = try compiler.compile(staticLottie: staticData, spec: m4) }
        catch { fail("M4 compile threw: \(error)") }
        guard let m4Root = (try? JSONSerialization.jsonObject(with: m4Result.data)) as? [String: Any],
              let m4Layers = m4Root["layers"] as? [[String: Any]] else { fail("M4 output invalid") }
        func m4Animated(_ name: String, _ channel: String) -> Bool {
            guard let l = m4Layers.first(where: { ($0["nm"] as? String) == name }),
                  let ks = l["ks"] as? [String: Any], let ch = ks[channel] as? [String: Any] else { return false }
            return (ch["a"] as? NSNumber)?.intValue == 1
        }
        check(m4Animated("Body", "p"), "float should animate Body position")
        check(m4Animated("Body", "s"), "scaleIn should animate Body scale")
        check(m4Animated("2 wing", "r"), "spin should animate 2 wing rotation")
        check(m4Animated("Iilum", "s"), "breathe should animate Iilum scale")
        check(m4Animated("1 wing", "r"), "swing should animate 1 wing rotation")
        check(m4Result.warnings.isEmpty, "M4 spec should produce no warnings, got \(m4Result.warnings)")

        print("OK: all checks passed (incl. M4 primitives). warnings=\(result.warnings.count)")
        for w in result.warnings { print("  warning: \(w)") }
    }
}
