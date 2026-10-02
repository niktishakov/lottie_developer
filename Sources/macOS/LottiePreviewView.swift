#if os(macOS)
import SwiftUI
import AppKit
import Lottie

/// Контейнер, обнуляющий intrinsicContentSize — иначе LottieAnimationView раздувает
/// SwiftUI-layout своим натуральным размером (как на iOS — см. FlexibleLottieContainer).
final class FlexibleLottieContainer: NSView {
    private(set) var animationView = LottieAnimationView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        install(animationView)
    }

    /// Заменить вью (нужно при смене конфигурации: движок, reduced motion).
    func replaceAnimationView(_ view: LottieAnimationView) {
        animationView.removeFromSuperview()
        animationView = view
        install(view)
    }

    private func install(_ animationView: LottieAnimationView) {
        animationView.contentMode = .scaleAspectFit
        animationView.backgroundBehavior = .pauseAndRestore
        animationView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(animationView)
        NSLayoutConstraint.activate([
            animationView.leadingAnchor.constraint(equalTo: leadingAnchor),
            animationView.trailingAnchor.constraint(equalTo: trailingAnchor),
            animationView.topAnchor.constraint(equalTo: topAnchor),
            animationView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Не даём анимации диктовать размер контейнера (её натуральный размер огромен).
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.defaultLow, for: axis)
            setContentCompressionResistancePriority(.defaultLow, for: axis)
            animationView.setContentHuggingPriority(.defaultLow, for: axis)
            animationView.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    /// SwiftUI на macOS опрашивает fittingSize у NSViewRepresentable — возвращаем 0,
    /// чтобы превью не раздувало окно и не выталкивало контролы.
    override var fittingSize: NSSize { .zero }
}

/// AppKit-обёртка над `LottieAnimationView` для macOS-превью.
/// Ядро запуска анимаций (то же, что lottie-ios даёт на iOS).
struct LottiePreviewView: NSViewRepresentable {
    let fileURL: URL
    var loop: Bool = true
    var speed: CGFloat = 1.0

    func makeNSView(context: Context) -> FlexibleLottieContainer {
        FlexibleLottieContainer()
    }

    func updateNSView(_ container: FlexibleLottieContainer, context: Context) {
        let view = container.animationView
        if context.coordinator.loadedPath != fileURL.path {
            context.coordinator.loadedPath = fileURL.path
            view.animation = LottieAnimation.filepath(fileURL.path)
            view.currentProgress = 0
        }
        view.animationSpeed = speed
        view.loopMode = loop ? .loop : .playOnce
        if !view.isAnimationPlaying {
            view.play()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedPath: String?
    }
}
#endif
