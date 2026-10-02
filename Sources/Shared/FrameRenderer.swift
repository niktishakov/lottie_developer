import Foundation
import CoreGraphics
import Lottie

/// Офскрин-рендер кадров Lottie (main-thread engine — он умеет рисовать через `render(in:)`).
/// Общий для приложения (раскадровка, экспорт, выбор слоя кликом) и lottie-mcp (`render_frame`).
@MainActor
enum FrameRenderer {

    struct RenderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func decode(_ data: Data) throws -> LottieAnimation {
        do { return try JSONDecoder().decode(LottieAnimation.self, from: data) }
        catch { throw RenderError(message: "Lottie decode failed: \(error.localizedDescription)") }
    }

    /// Кадр в CGImage. `size` — максимальная сторона в px. Начало координат картинки — сверху слева,
    /// 1 px картинки = 1/scale единиц композиции.
    static func renderImage(animation: LottieAnimation, frame: Double, size: Int,
                            background: CGColor?) throws -> (image: CGImage, scale: Double) {
        let compW = max(animation.bounds.width, 1), compH = max(animation.bounds.height, 1)
        let scale = Double(max(8, min(size, 4096))) / Double(max(compW, compH))
        let w = max(Int((compW * scale).rounded()), 1), h = max(Int((compH * scale).rounded()), 1)

        let layer = LottieAnimationLayer(animation: animation,
                                         configuration: LottieConfiguration(renderingEngine: .mainThread))
        layer.frame = CGRect(x: 0, y: 0, width: compW, height: compH)
        // Без хост-вью layout не вызывается: центрируем внутренний слой композиции вручную.
        layer.sublayers?.forEach {
            $0.bounds = layer.bounds
            $0.position = CGPoint(x: compW / 2, y: compH / 2)
        }
        layer.currentFrame = min(max(frame, animation.startFrame), animation.endFrame)
        layer.forceDisplayUpdate()
        layer.displayIfNeeded()

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError(message: "Cannot create bitmap context")
        }
        if let bg = background {
            ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        // isGeometryFlipped + переворот контекста: только так и фигуры, и contents слоёв-картинок
        // получаются в правильной ориентации (один переворот контекста переворачивает картинки).
        #if os(macOS)
        layer.isGeometryFlipped = true // на iOS слои и так «сверху вниз»; лишний флаг переворачивает картинки
        #endif
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { throw RenderError(message: "Cannot make image") }
        return (img, scale)
    }

    /// - frame: номер кадра (nil → по `progress` 0…1).
    static func renderPNG(lottieData: Data, frame: Double?, progress: Double?, size: Int,
                          background: CGColor?) throws -> (png: Data, frame: Double, width: Int, height: Int) {
        let animation = try decode(lottieData)
        let target: Double
        if let frame { target = frame }
        else {
            let p = min(max(progress ?? 0, 0), 1)
            target = animation.startFrame + (animation.endFrame - animation.startFrame) * p
        }
        let clamped = min(max(target, animation.startFrame), animation.endFrame)
        let (img, _) = try renderImage(animation: animation, frame: clamped, size: size, background: background)
        return (try png(img), clamped, img.width, img.height)
    }

    static func png(_ img: CGImage) throws -> Data {
        guard let data = SVGDocument.pngData(img) else {
            throw RenderError(message: "PNG encode failed")
        }
        return data
    }

    /// Bounding box непрозрачных пикселей в координатах композиции (nil — слой пуст на этом кадре).
    static func opaqueBounds(_ img: CGImage, scale: Double) -> CGRect? {
        guard let px = rgba(img) else { return nil }
        let w = img.width, h = img.height
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where px[row + x * 4 + 3] > 8 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: Double(minX) / scale, y: Double(minY) / scale,
                      width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
    }

    /// Есть ли непрозрачный пиксель в точке (координаты композиции).
    static func isOpaque(_ img: CGImage, scale: Double, at p: CGPoint) -> Bool {
        guard let px = rgba(img) else { return false }
        let x = Int(p.x * scale), y = Int(p.y * scale)
        guard x >= 0, y >= 0, x < img.width, y < img.height else { return false }
        return px[(y * img.width + x) * 4 + 3] > 8
    }

    private static func rgba(_ img: CGImage) -> [UInt8]? {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    static func color(hex: String?) -> CGColor? {
        guard let rgb = LottieOverrides.rgb(hex: hex) else { return nil }
        return CGColor(srgbRed: CGFloat(rgb[0]), green: CGFloat(rgb[1]), blue: CGFloat(rgb[2]), alpha: 1)
    }
}
