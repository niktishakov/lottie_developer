#if os(macOS)
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Lottie

/// Экспорт текущего вида (с запечёнными правками): Lottie JSON, dotLottie, GIF, PNG-кадры, один кадр.
@MainActor
enum Exporter {

    enum Kind: String, CaseIterable, Identifiable {
        case json = "Lottie JSON…", dotLottie = "dotLottie (.lottie)…", gif = "GIF…",
             pngSequence = "PNG sequence…", currentFrame = "Current frame PNG…"
        var id: String { rawValue }
    }

    /// Возвращает текст для статуса (что и куда записано) или nil, если пользователь отменил.
    static func run(_ kind: Kind, data: Data, frame: Double, baseName: String, background: NSColor?) throws -> String? {
        switch kind {
        case .json:
            guard let url = savePanel(name: "\(baseName).json", type: .json) else { return nil }
            try data.write(to: url, options: .atomic)
            return "Saved \(url.lastPathComponent)"
        case .dotLottie:
            guard let url = savePanel(name: "\(baseName).lottie", type: UTType(filenameExtension: "lottie") ?? .zip) else { return nil }
            try writeDotLottie(data: data, to: url)
            return "Saved \(url.lastPathComponent)"
        case .gif:
            guard let url = savePanel(name: "\(baseName).gif", type: .gif) else { return nil }
            let n = try writeGIF(data: data, to: url, background: background ?? .white)
            return "Saved \(url.lastPathComponent) · \(n) frames"
        case .pngSequence:
            guard let dir = folderPanel() else { return nil }
            let anim = try FrameRenderer.decode(data)
            var n = 0
            for f in stride(from: anim.startFrame, through: anim.endFrame, by: 1) {
                let (img, _) = try FrameRenderer.renderImage(animation: anim, frame: f, size: 1024, background: background?.cgColor)
                try FrameRenderer.png(img).write(to: dir.appendingPathComponent(String(format: "%@_%04d.png", baseName, Int(f))))
                n += 1
            }
            return "Saved \(n) PNG frames to \(dir.lastPathComponent)"
        case .currentFrame:
            guard let url = savePanel(name: "\(baseName)_f\(Int(frame)).png", type: .png) else { return nil }
            let (img, _) = try FrameRenderer.renderImage(animation: try FrameRenderer.decode(data), frame: frame,
                                                         size: 1024, background: background?.cgColor)
            try FrameRenderer.png(img).write(to: url)
            return "Saved \(url.lastPathComponent)"
        }
    }

    /// dotLottie = zip: manifest.json + animations/<id>.json.
    static func writeDotLottie(data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dotlottie_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("animations"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try data.write(to: tmp.appendingPathComponent("animations/main.json"))
        let manifest: [String: Any] = ["version": "1", "generator": "Lottie Developer",
                                       "animations": [["id": "main"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: tmp.appendingPathComponent("manifest.json"))
        try? fm.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = tmp
        p.arguments = ["-r", "-X", "-q", url.path, "manifest.json", "animations"]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FrameRenderer.RenderError(message: "zip failed (\(p.terminationStatus))") }
    }

    /// GIF до 30 fps, 480 px. Прозрачность GIF плохая — рисуем на фоне.
    static func writeGIF(data: Data, to url: URL, background: NSColor) throws -> Int {
        let anim = try FrameRenderer.decode(data)
        let stepFrames = anim.framerate > 30 ? 2.0 : 1.0
        let frames = Array(stride(from: anim.startFrame, through: anim.endFrame, by: stepFrames))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw FrameRenderer.RenderError(message: "Cannot create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = stepFrames / max(anim.framerate, 1)
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for f in frames {
            let (img, _) = try FrameRenderer.renderImage(animation: anim, frame: f, size: 480, background: background.cgColor)
            CGImageDestinationAddImage(dest, img, props)
        }
        guard CGImageDestinationFinalize(dest) else { throw FrameRenderer.RenderError(message: "GIF finalize failed") }
        return frames.count
    }

    private static func savePanel(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func folderPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
#endif
