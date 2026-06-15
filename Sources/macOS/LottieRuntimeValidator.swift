#if os(macOS)
import Foundation
import AppKit
import Lottie

/// Находка проверки. Локальный тип (Pipeline/QAFinding ещё не в macOS-таргете —
/// при интеграции Pipeline маппится в QAFinding 1:1).
struct LottieValidationFinding: Identifiable {
    enum Severity: String { case critical, high, medium, low, info }
    let id = UUID()
    let severity: Severity
    let code: String
    let message: String
}

struct LottieRuntimeReport {
    let findings: [LottieValidationFinding]
    let renderingEngine: String
    let fps: Int
    let durationFrames: Int
    let sampledFrames: Int

    /// Проходит, если нет critical/high находок.
    var passed: Bool {
        !findings.contains { $0.severity == .critical || $0.severity == .high }
    }
}

/// Runtime-gate на реальном lottie-ios: structural decode + 60fps/frame-grid +
/// офскрин-рендер сэмплов кадров + детект CA-движок vs main-thread fallback.
/// Это ядро проверки M2 — то же ядро, что и запускает анимации.
enum LottieRuntimeValidator {

    @MainActor
    static func validate(fileURL: URL) -> LottieRuntimeReport {
        var findings: [LottieValidationFinding] = []

        // 1. Structural decode через lottie-ios (= валидный bodymovin).
        guard let animation = LottieAnimation.filepath(fileURL.path) else {
            findings.append(.init(severity: .critical, code: "decode",
                                  message: "lottie-ios could not decode the animation (invalid Lottie JSON)"))
            return LottieRuntimeReport(findings: findings, renderingEngine: "—", fps: 0, durationFrames: 0, sampledFrames: 0)
        }

        let fps = Int(animation.framerate.rounded())
        let durationFrames = Int((animation.endFrame - animation.startFrame).rounded())

        // 2. 60fps / frame-grid.
        if fps != 60 {
            findings.append(.init(severity: .medium, code: "fps",
                                  message: "Frame rate is \(fps) fps, expected 60 for smooth 60fps playback"))
        }
        if durationFrames <= 0 {
            findings.append(.init(severity: .high, code: "duration",
                                  message: "Non-positive duration (\(durationFrames) frames)"))
        }

        // 3. CA-engine compatibility (риск просадки 60fps при fallback на main-thread).
        let probe = LottieAnimationLayer(
            animation: animation,
            configuration: LottieConfiguration(renderingEngine: .automatic)
        )
        let engine = probe.currentRenderingEngine
        let engineLabel = engine?.description ?? "unknown"
        switch engine {
        case .coreAnimation:
            findings.append(.init(severity: .info, code: "engine",
                                  message: "Renders on Core Animation engine (hardware-accelerated, smooth 60fps)"))
        case .mainThread:
            findings.append(.init(severity: .medium, code: "engine",
                                  message: "Falls back to Main Thread engine — uses unsupported features; 60fps may drop on complex scenes"))
        case .none:
            findings.append(.init(severity: .low, code: "engine",
                                  message: "Could not resolve rendering engine"))
        }

        // 4. Офскрин-рендер сэмплов кадров (детект «ничего не рендерится»).
        // Main-thread движок даёт детерминированный render(in:) по выставленному currentProgress.
        let sampler = LottieAnimationLayer(
            animation: animation,
            configuration: LottieConfiguration(renderingEngine: .mainThread)
        )
        let (sampled, allBlank) = sampleFrames(layer: sampler, animationSize: animation.size)
        if sampled > 0, allBlank {
            findings.append(.init(severity: .high, code: "render",
                                  message: "All \(sampled) sampled frames render empty — animation produces no visible output"))
        }

        return LottieRuntimeReport(
            findings: findings,
            renderingEngine: engineLabel,
            fps: fps,
            durationFrames: durationFrames,
            sampledFrames: sampled
        )
    }

    /// Рендерит ~N кадров на сетке прогресса в офскрин-битмап, возвращает (число сэмплов, все ли пустые).
    @MainActor
    private static func sampleFrames(layer: LottieAnimationLayer, animationSize: CGSize) -> (count: Int, allBlank: Bool) {
        // Ограничиваем размер рендера ради скорости (сохраняя пропорции).
        let maxSide: CGFloat = 240
        let scale = min(1, maxSide / max(animationSize.width, animationSize.height, 1))
        let w = max(Int(animationSize.width * scale), 1)
        let h = max(Int(animationSize.height * scale), 1)
        layer.frame = CGRect(x: 0, y: 0, width: w, height: h)

        let steps = 24
        var blank = 0
        var rendered = 0
        for i in 0...steps {
            layer.currentProgress = CGFloat(i) / CGFloat(steps)
            layer.forceDisplayUpdate()
            layer.layoutIfNeeded()
            guard let image = renderToCGImage(layer: layer, width: w, height: h) else { continue }
            rendered += 1
            if isFullyTransparent(image) { blank += 1 }
        }
        return (rendered, rendered > 0 && blank == rendered)
    }

    @MainActor
    private static func renderToCGImage(layer: CALayer, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// Полностью ли прозрачен кадр (alpha==0 у всех пикселей).
    private static func isFullyTransparent(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let ptr = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var i = 3 // alpha канал
        let total = width * height * 4
        while i < total {
            if ptr[i] != 0 { return false }
            i += 4
        }
        return true
    }
}
#endif
