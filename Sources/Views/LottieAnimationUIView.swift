import Foundation
import SwiftUI
import Lottie
#if canImport(UIKit)
import UIKit
#endif

/// Обёртка, которая обнуляет intrinsicContentSize — UIView не раздувает SwiftUI layout.
final class FlexibleLottieContainer: UIView {
    let animationView = LottieAnimationView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        animationView.backgroundColor = .clear
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
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { .zero }
}

struct LottieView: UIViewRepresentable {
    typealias UIViewType = FlexibleLottieContainer

    let fileURL: URL
    let playback: PlaybackState
    let colorOverrides: [String: Color]
    let syncProgress: Bool

    init(
        fileURL: URL,
        playback: PlaybackState,
        colorOverrides: [String: Color] = [:],
        syncProgress: Bool = true
    ) {
        self.fileURL = fileURL
        self.playback = playback
        self.colorOverrides = colorOverrides
        self.syncProgress = syncProgress
    }

    private func hasMeaningfulChange(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) > 0.0005
    }

    private func colorSignature(for overrides: [String: Color]) -> String {
        overrides
            .sorted { $0.key < $1.key }
            .map { keypath, color in
                let components = components(from: color)
                    .map { String(format: "%.4f,%.4f,%.4f,%.4f", $0.0, $0.1, $0.2, $0.3) }
                    ?? "0.0000,0.0000,0.0000,0.0000"
                return "\(keypath)=\(components)"
            }
            .joined(separator: "|")
    }

    private func components(from color: Color) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        #if canImport(UIKit)
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return (red, green, blue, alpha)
        #else
        return nil
        #endif
    }

    private func applyColorOverrides(
        _ overrides: [String: Color],
        to animationView: LottieAnimationView
    ) {
        for (keypath, color) in overrides {
            guard let rgba = components(from: color) else { continue }
            let valueProvider = ColorValueProvider(
                LottieColor(
                    r: Double(rgba.0),
                    g: Double(rgba.1),
                    b: Double(rgba.2),
                    a: Double(rgba.3)
                )
            )
            animationView.setValueProvider(
                valueProvider,
                keypath: AnimationKeypath(keypath: keypath)
            )
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: FlexibleLottieContainer,
        context: Context
    ) -> CGSize? {
        nil // SwiftUI сам определяет размер через proposed size
    }

    func makeUIView(context: Context) -> FlexibleLottieContainer {
        FlexibleLottieContainer()
    }

    func updateUIView(_ container: FlexibleLottieContainer, context: Context) {
        let uiView = container.animationView
        let coordinator = context.coordinator

        if coordinator.loadedURL != fileURL {
            coordinator.loadedURL = fileURL
            let animation = LottieAnimation.filepath(fileURL.path)
            uiView.animation = animation
            coordinator.resetPlaybackState()
        }

        let currentColorSignature = colorSignature(for: colorOverrides)
        if coordinator.lastColorSignature != currentColorSignature {
            applyColorOverrides(colorOverrides, to: uiView)
            coordinator.lastColorSignature = currentColorSignature
        }

        let loopMode: LottieLoopMode = playback.loopEnabled ? .loop : .playOnce

        let rangeChanged = hasMeaningfulChange(coordinator.lastFromProgress, playback.fromProgress)
            || hasMeaningfulChange(coordinator.lastToProgress, playback.toProgress)
        let loopChanged = coordinator.lastLoopEnabled != playback.loopEnabled
        let speedChanged = hasMeaningfulChange(coordinator.lastSpeed, playback.speed)

        if speedChanged {
            uiView.animationSpeed = CGFloat(playback.speed)
            coordinator.lastSpeed = playback.speed
        }
        if loopChanged {
            uiView.loopMode = loopMode
            coordinator.lastLoopEnabled = playback.loopEnabled
        }

        if playback.isPlaying {
            let startProgress = min(
                max(playback.currentProgress, playback.fromProgress),
                playback.toProgress
            )
            let needsStart = !coordinator.isPlaying || rangeChanged || loopChanged
            if needsStart {
                let from = CGFloat(playback.fromProgress)
                let to = CGFloat(playback.toProgress)
                let start = CGFloat(startProgress)

                // Если мы в loop и пересоздали view в середине диапазона (например, при hero/fullscreen),
                // сначала доигрываем текущий отрезок, затем входим в loop строго по playback range.
                if playback.loopEnabled, startProgress > playback.fromProgress + 0.0005 {
                    uiView.play(
                        fromProgress: start,
                        toProgress: to,
                        loopMode: .playOnce
                    ) { finished in
                        guard finished, playback.isPlaying, playback.loopEnabled else { return }
                        uiView.play(
                            fromProgress: from,
                            toProgress: to,
                            loopMode: .loop
                        )
                    }
                } else {
                    uiView.play(
                        fromProgress: playback.loopEnabled ? from : start,
                        toProgress: to,
                        loopMode: loopMode
                    ) { finished in
                        guard !playback.loopEnabled, finished else { return }
                        playback.currentProgress = playback.toProgress
                        playback.isPlaying = false
                    }
                }
                coordinator.isPlaying = true
            }
            if syncProgress {
                coordinator.startProgressSync(view: uiView, playback: playback)
            } else {
                coordinator.stopProgressSync()
            }
        } else {
            coordinator.stopProgressSync()
            if coordinator.isPlaying || uiView.isAnimationPlaying {
                uiView.pause()
                coordinator.isPlaying = false
            }
            if hasMeaningfulChange(Double(uiView.currentProgress), playback.currentProgress) {
                uiView.currentProgress = CGFloat(playback.currentProgress)
            }
        }

        coordinator.lastFromProgress = playback.fromProgress
        coordinator.lastToProgress = playback.toProgress
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        var loadedURL: URL?
        var isPlaying = false
        var lastFromProgress = 0.0
        var lastToProgress = 1.0
        var lastLoopEnabled = true
        var lastSpeed = 1.0
        var lastColorSignature = ""
        private weak var trackedView: LottieAnimationView?
        private weak var trackedPlayback: PlaybackState?
        private var progressTimer: Timer?

        deinit {
            stopProgressSync()
        }

        func startProgressSync(view: LottieAnimationView, playback: PlaybackState) {
            trackedView = view
            trackedPlayback = playback
            guard progressTimer == nil else { return }
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(syncProgress),
                userInfo: nil,
                repeats: true
            )
            progressTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func stopProgressSync() {
            progressTimer?.invalidate()
            progressTimer = nil
            trackedView = nil
            trackedPlayback = nil
        }

        @MainActor
        @objc private func syncProgress() {
            guard let trackedView, let trackedPlayback else { return }

            let progress = Double(trackedView.realtimeAnimationProgress)
            guard progress.isFinite else { return }
            guard abs(trackedPlayback.currentProgress - progress) > 0.005 else { return }
            trackedPlayback.currentProgress = progress
        }

        func resetPlaybackState() {
            isPlaying = false
            lastFromProgress = 0.0
            lastToProgress = 1.0
            lastLoopEnabled = true
            lastSpeed = 1.0
            lastColorSignature = ""
            stopProgressSync()
        }
    }
}
