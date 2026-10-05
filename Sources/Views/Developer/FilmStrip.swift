#if os(iOS)
import SwiftUI
import UIKit
import Lottie

/// Лента кадров вместо полоски: миниатюры по всей длине анимации, белая линия — текущий момент,
/// красные точки — открытые комментарии. Тянешь пальцем — анимация идёт следом.
struct FilmStrip: View {
    let url: URL?
    let aspect: Double
    let frame: Double
    let start: Double
    let end: Double
    let markers: [Double]
    var background: DevBackground = .checker
    var backgroundHex = "#FFFFFF"
    let onSeek: (Double) -> Void

    @State private var thumbs: [UIImage] = []
    private static let height: CGFloat = 46

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let span = max(end - start, 1)
            let x = { (f: Double) in CGFloat((f - start) / span) * w }
            let count = Self.count(width: w, aspect: aspect)
            ZStack(alignment: .leading) {
                DevBackgroundView(kind: background, customHex: backgroundHex)
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        Group {
                            if i < thumbs.count { Image(uiImage: thumbs[i]).resizable().scaledToFill() } else { Color.clear }
                        }
                        .frame(width: w / CGFloat(count), height: Self.height)
                        .clipped()
                        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.35)).frame(width: 1) }
                    }
                }
                // Пройденная часть чуть темнее — видно, где мы.
                Rectangle().fill(.black.opacity(0.28)).frame(width: max(0, x(frame)))
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    Circle().fill(.red).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .offset(x: x(m) - 4.5, y: -Self.height / 2 + 7)
                }
                RoundedRectangle(cornerRadius: 1.5).fill(.white)
                    .frame(width: 3, height: Self.height + 8)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: min(max(x(frame) - 1.5, 0), w - 3))
            }
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onSeek(start + Double(min(max(v.location.x / w, 0), 1)) * span)
            })
            .task(id: "\(url?.path ?? "")|\(count)|\(Self.mtime(url))") {
                thumbs = await Self.render(url: url, count: count, aspect: aspect)
            }
        }
        .frame(height: Self.height)
    }

    private static func count(width: CGFloat, aspect: Double) -> Int {
        let thumbW = height * CGFloat(max(aspect, 0.2))
        return max(4, min(16, Int((width / thumbW).rounded())))
    }

    private static func mtime(_ url: URL?) -> Double {
        guard let url else { return 0 }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
    }

    // MARK: - Миниатюры

    @MainActor private static var cache: [String: [UIImage]] = [:]

    /// Кадры в середине каждого отрезка, рендер настоящим lottie-ios (Main Thread движок умеет рисовать вне экрана).
    @MainActor
    private static func render(url: URL?, count: Int, aspect: Double) async -> [UIImage] {
        guard let url else { return [] }
        let key = "\(url.path)|\(count)|\(mtime(url))"
        if let c = cache[key] { return c }
        guard let anim = LottieAnimation.filepath(url.path) else { return [] }
        let size = CGSize(width: height * 2 * CGFloat(max(aspect, 0.2)), height: height * 2)
        let view = LottieAnimationView(animation: anim, configuration: LottieConfiguration(renderingEngine: .mainThread))
        view.frame = CGRect(origin: .zero, size: size)
        view.contentMode = .scaleAspectFit
        view.backgroundBehavior = .stop
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var out: [UIImage] = []
        for i in 0..<count {
            view.currentProgress = (Double(i) + 0.5) / Double(count)
            view.layoutIfNeeded()
            view.forceDisplayUpdate()
            out.append(renderer.image { view.layer.render(in: $0.cgContext) })
            await Task.yield()
        }
        cache[key] = out
        return out
    }
}
#endif
