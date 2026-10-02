import XCTest
import ImageIO
@testable import LottieDeveloperMac

/// Экспорт, правки слоёв и офскрин-рендер редактора.
@MainActor
final class EditorToolsTests: XCTestCase {

    /// Две фигуры: синий прямоугольник слева сверху, красный круг справа снизу. 60 кадров.
    private func sample() throws -> Data {
        let svg = """
        <svg viewBox="0 0 200 100"><rect id="bar" x="10" y="10" width="60" height="20" fill="#00f"/>\
        <circle id="dot" cx="140" cy="60" r="30" fill="#f00"/></svg>
        """
        let geom = try SVGToLottie.convert(svgData: Data(svg.utf8)).data
        let spec = AnimationSpec(fps: 60, durationFrames: 60, layers: [
            LayerAnimationSpec(target: "dot", animations: [MotionPrimitive(kind: .fadeIn, start: 0, end: 0.5, easing: .linear)])
        ])
        return try LottieCompiler().compile(staticLottie: geom, spec: spec).data
    }

    private var tmp: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("editor_tests_\(UUID().uuidString)")
    }

    func testDotLottieIsZipWithManifestAndAnimation() throws {
        let url = tmp.appendingPathExtension("lottie")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.writeDotLottie(data: try sample(), to: url)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-Z1", url.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let list = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(list.contains("manifest.json"), list)
        XCTAssertTrue(list.contains("animations/main.json"), list)
    }

    func testGIFHasFramesAtMax30fps() throws {
        let url = tmp.appendingPathExtension("gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let n = try Exporter.writeGIF(data: try sample(), to: url, background: .white)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), n)
        XCTAssertEqual(n, 31) // 0…60 с шагом 2 (60 fps → 30 fps)
    }

    func testOverridesRecolorHideAndScaleOpacity() throws {
        let data = try sample()
        let out = LottieOverrides.apply([
            "bar": LayerOverride(color: "#00FF00"),
            "dot": LayerOverride(opacity: 50, hidden: true),
        ], to: data)
        XCTAssertEqual(LottieOverrides.firstColor(layerName: "bar", in: out), "#00FF00")
        let layers = try XCTUnwrap((try JSONSerialization.jsonObject(with: out) as? [String: Any])?["layers"] as? [[String: Any]])
        let dot = try XCTUnwrap(layers.first { $0["nm"] as? String == "dot" })
        XCTAssertEqual(dot["hd"] as? Bool, true)
        // fadeIn: анимированная прозрачность 0→100 масштабируется до 0→50.
        let o = try XCTUnwrap((dot["ks"] as? [String: Any])?["o"] as? [String: Any])
        let kfs = try XCTUnwrap(o["k"] as? [[String: Any]])
        XCTAssertEqual((kfs.last?["s"] as? [Double])?.first ?? -1, 50, accuracy: 0.01)
        // Пустые правки не меняют данные.
        XCTAssertEqual(LottieOverrides.apply([:], to: data), data)
    }

    func testRendererBoundsAndHitTestForIsolatedLayer() throws {
        let data = try sample()
        let layers = LottieOverrides.layers(in: data)
        let bar = try XCTUnwrap(layers.first { $0.name == "bar" })
        let iso = LottieOverrides.isolate(layerIndex: bar.index, in: data)
        let (img, scale) = try FrameRenderer.renderImage(animation: try FrameRenderer.decode(iso), frame: 30, size: 400, background: nil)
        let box = try XCTUnwrap(FrameRenderer.opaqueBounds(img, scale: scale))
        XCTAssertEqual(box.minX, 10, accuracy: 1); XCTAssertEqual(box.minY, 10, accuracy: 1)
        XCTAssertEqual(box.width, 60, accuracy: 1); XCTAssertEqual(box.height, 20, accuracy: 1)
        XCTAssertTrue(FrameRenderer.isOpaque(img, scale: scale, at: CGPoint(x: 40, y: 20)))
        XCTAssertFalse(FrameRenderer.isOpaque(img, scale: scale, at: CGPoint(x: 140, y: 60))) // круг скрыт
    }

    func testPlayerPicksLayerAndClampsMarkerlessRange() throws {
        let m = PlayerModel()
        m.load(data: try sample())
        m.seek(30)
        m.pickLayer(atComp: CGPoint(x: 140, y: 60))
        XCTAssertEqual(m.selectedLayer, "dot")
        XCTAssertNotNil(m.selectionBox)
        m.pickLayer(atComp: CGPoint(x: 100, y: 95))
        XCTAssertNil(m.selectedLayer)

        m.reducedMotion = true
        XCTAssertFalse(m.isPlaying)
        XCTAssertEqual(m.frame, m.endFrame)
        m.togglePlay()
        XCTAssertFalse(m.isPlaying)
    }
}
