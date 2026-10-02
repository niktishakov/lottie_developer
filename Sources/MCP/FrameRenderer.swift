import Foundation
import AppKit
import Lottie

/// Рендер кадров Lottie в PNG (main-thread engine — он умеет рисовать через `render(in:)`).
@MainActor
enum FrameRenderer {

    struct RenderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// - frame: номер кадра (nil → по `progress` 0…1).
    /// - size: максимальная сторона PNG в px.
    static func renderPNG(lottieData: Data, frame: Double?, progress: Double?, size: Int,
                          background: NSColor?) throws -> (png: Data, frame: Double, width: Int, height: Int) {
        let animation: LottieAnimation
        do { animation = try JSONDecoder().decode(LottieAnimation.self, from: lottieData) }
        catch { throw RenderError(message: "Lottie decode failed: \(error.localizedDescription)") }

        let compW = max(animation.bounds.width, 1), compH = max(animation.bounds.height, 1)
        let scale = Double(max(16, min(size, 4096))) / Double(max(compW, compH))
        let w = Int((compW * scale).rounded()), h = Int((compH * scale).rounded())

        let target: Double
        if let frame { target = frame }
        else {
            let p = min(max(progress ?? 0, 0), 1)
            target = animation.startFrame + (animation.endFrame - animation.startFrame) * p
        }
        let clamped = min(max(target, animation.startFrame), animation.endFrame)

        let layer = LottieAnimationLayer(animation: animation,
                                         configuration: LottieConfiguration(renderingEngine: .mainThread))
        layer.frame = CGRect(x: 0, y: 0, width: compW, height: compH)
        layer.currentFrame = clamped
        layer.forceDisplayUpdate()
        // Без хост-вью layout не вызывается: центрируем внутренний слой композиции вручную.
        layer.sublayers?.forEach {
            $0.bounds = layer.bounds
            $0.position = CGPoint(x: compW / 2, y: compH / 2)
        }
        layer.displayIfNeeded()

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError(message: "Cannot create bitmap context")
        }
        if let bg = background?.cgColor {
            ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        // CALayer рисует в координатах с началом сверху — переворачиваем.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        layer.render(in: ctx)

        guard let img = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
            throw RenderError(message: "PNG encode failed")
        }
        return (png, clamped, w, h)
    }

    static func color(hex: String?) -> NSColor? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.lowercased() != "transparent" else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
