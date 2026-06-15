import Foundation
import UIKit
import WebKit

enum SVGSnapshotRenderer {
    enum RenderError: LocalizedError {
        case invalidSVGEncoding
        case snapshotFailed

        var errorDescription: String? {
            switch self {
            case .invalidSVGEncoding:
                return "Unable to decode SVG payload"
            case .snapshotFailed:
                return "Unable to render SVG snapshot"
            }
        }
    }

    @MainActor
    static func renderPNGData(from svgData: Data, width: Int, height: Int) async throws -> Data {
        guard let svgString = String(data: svgData, encoding: .utf8) else {
            throw RenderError.invalidSVGEncoding
        }

        let safeWidth = max(width, 1)
        let safeHeight = max(height, 1)
        let size = CGSize(width: safeWidth, height: safeHeight)

        let webView = WKWebView(frame: CGRect(origin: .zero, size: size))
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        let html = """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: transparent; overflow: hidden; }
        svg { width: 100%; height: 100%; display: block; }
        </style>
        </head>
        <body>
        \(svgString)
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
        try await waitUntilReady(webView: webView)

        let image = try await snapshot(webView: webView, size: size)
        guard let pngData = image.pngData() else {
            throw RenderError.snapshotFailed
        }
        return pngData
    }

    @MainActor
    private static func waitUntilReady(webView: WKWebView) async throws {
        for _ in 0..<40 {
            let state = await readyState(webView: webView)
            if state == "complete" {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private static func readyState(webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.readyState") { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    @MainActor
    private static func snapshot(webView: WKWebView, size: CGSize) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: size)
            webView.takeSnapshot(with: config) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? RenderError.snapshotFailed)
                }
            }
        }
    }
}
