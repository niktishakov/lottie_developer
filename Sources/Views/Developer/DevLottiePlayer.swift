#if os(iOS)
import SwiftUI
import UIKit
import Lottie

/// Выбор движка рендеринга lottie-ios.
enum DevEngineChoice: String, CaseIterable, Identifiable {
    case automatic = "Automatic", coreAnimation = "Core Animation", mainThread = "Main Thread"
    var id: String { rawValue }
    var option: RenderingEngineOption {
        switch self {
        case .automatic: .automatic
        case .coreAnimation: .coreAnimation
        case .mainThread: .mainThread
        }
    }
}

/// Управляет одним LottieAnimationView: загрузка, play/pause, кадр, скорость, loop, движок.
@MainActor
@Observable
final class DevPlayerController {
    private(set) var isPlaying = false
    private(set) var frame: Double = 0
    private(set) var startFrame: Double = 0
    private(set) var endFrame: Double = 0
    private(set) var activeEngine = "—"
    private(set) var loadError: String?
    /// Меняется при пересоздании view — сигнал representable'у заменить subview.
    private(set) var viewGeneration = 0

    var speed: Double = 1 { didSet { view?.animationSpeed = speed } }
    var loop = true { didSet { if isPlaying { play() } } }
    var engine: DevEngineChoice = .automatic { didSet { if oldValue != engine { rebuild() } } }

    @ObservationIgnored private(set) var view: LottieAnimationView?
    @ObservationIgnored private var animation: LottieAnimation?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var timer: Timer?

    /// Загрузить файл. frame — с какого кадра показать (nil — с начала), autoplay — сразу играть.
    func load(url: URL, frame: Double? = nil, autoplay: Bool) {
        self.url = url
        animation = LottieAnimation.filepath(url.path)
        loadError = animation == nil ? "Can't read \(url.lastPathComponent)" : nil
        rebuild(frame: frame ?? Double(animation?.startFrame ?? 0), autoplay: autoplay)
    }

    private func rebuild(frame resume: Double? = nil, autoplay: Bool = false) {
        let wasPlaying = isPlaying
        let resume = resume ?? frame
        view?.stop()
        let v = LottieAnimationView(animation: animation,
                                    configuration: LottieConfiguration(renderingEngine: engine.option))
        v.contentMode = .scaleAspectFit
        v.backgroundBehavior = .pauseAndRestore
        v.animationSpeed = speed
        view = v
        startFrame = Double(animation?.startFrame ?? 0)
        endFrame = Double(animation?.endFrame ?? 0)
        isPlaying = false
        viewGeneration += 1
        seek(min(max(resume, startFrame), endFrame))
        if wasPlaying || autoplay { play() }
        refreshEngine()
    }

    func play() {
        guard let view, animation != nil else { return }
        if frame >= endFrame - 0.5 { frame = startFrame }
        view.play(fromFrame: frame, toFrame: endFrame, loopMode: loop ? .loop : .playOnce) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, !self.loop else { return }
                self.isPlaying = false
                self.stopTimer()
                self.frame = self.endFrame
            }
        }
        isPlaying = true
        startTimer()
        refreshEngine()
    }

    func pause() {
        view?.pause()
        if let view { frame = Double(view.realtimeAnimationFrame) }
        isPlaying = false
        stopTimer()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(_ f: Double) {
        if isPlaying { view?.pause(); isPlaying = false; stopTimer() }
        frame = f
        view?.currentFrame = AnimationFrameTime(f)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let v = self.view, self.isPlaying else { return }
                self.frame = Double(v.realtimeAnimationFrame)
                if self.activeEngine == "—" { self.refreshEngine() }
            }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func refreshEngine() {
        switch view?.currentRenderingEngine {
        case .coreAnimation: activeEngine = "Core Animation"
        case .mainThread: activeEngine = "Main Thread"
        default: activeEngine = "—"
        }
    }

    func teardown() { stopTimer(); view?.stop() }
}

/// SwiftUI-обёртка: показывает текущий view контроллера.
struct DevLottieCanvas: UIViewRepresentable {
    let controller: DevPlayerController

    func makeUIView(context: Context) -> DevLottieHost { DevLottieHost() }

    func updateUIView(_ host: DevLottieHost, context: Context) {
        _ = controller.viewGeneration // подписка на пересоздание
        host.show(controller.view)
    }
}

final class DevLottieHost: UIView {
    private weak var current: UIView?
    override var intrinsicContentSize: CGSize { .zero }

    func show(_ v: UIView?) {
        guard v !== current else { return }
        current?.removeFromSuperview()
        current = v
        guard let v else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// Статичный кадр анимации (середина) — для миниатюр.
struct DevLottieStill: UIViewRepresentable {
    let url: URL?
    var progress: Double = 0.5

    func makeUIView(context: Context) -> DevLottieHost { DevLottieHost() }

    func updateUIView(_ host: DevLottieHost, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        guard let url, let anim = LottieAnimation.filepath(url.path) else { host.show(nil); return }
        let v = LottieAnimationView(animation: anim, configuration: LottieConfiguration(renderingEngine: .mainThread))
        v.contentMode = .scaleAspectFit
        v.currentProgress = progress
        host.show(v)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var url: URL?? = .none }
}

/// Фон под анимацией.
enum DevBackground: String, CaseIterable, Identifiable {
    case checker = "Checker", light = "Light", dark = "Dark"
    var id: String { rawValue }
}

struct DevBackgroundView: View {
    let kind: DevBackground
    var body: some View {
        switch kind {
        case .light: Color.white
        case .dark: Color(white: 0.08)
        case .checker:
            Canvas { ctx, size in
                let s: CGFloat = 12
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.85)))
                for y in stride(from: 0, to: size.height, by: s) {
                    for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                        ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.7)))
                    }
                }
            }
        }
    }
}
#endif
