import Foundation
import SwiftUI
import Lottie

struct LottieView: UIViewRepresentable {
    let fileURL: URL
    let playback: PlaybackState

    private func hasMeaningfulChange(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) > 0.0005
    }

    func makeUIView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        view.contentMode = .scaleAspectFit
        view.backgroundBehavior = .pauseAndRestore
        return view
    }

    func updateUIView(_ uiView: LottieAnimationView, context: Context) {
        let coordinator = context.coordinator

        if coordinator.loadedURL != fileURL {
            coordinator.loadedURL = fileURL
            let animation = LottieAnimation.filepath(fileURL.path)
            uiView.animation = animation
            coordinator.resetPlaybackState()
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
                uiView.play(
                    fromProgress: CGFloat(startProgress),
                    toProgress: CGFloat(playback.toProgress),
                    loopMode: loopMode
                ) { finished in
                    guard !playback.loopEnabled, finished else { return }
                    playback.currentProgress = playback.toProgress
                    playback.isPlaying = false
                }
                coordinator.isPlaying = true
            }
            coordinator.startProgressSync(view: uiView, playback: playback)
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
                timeInterval: 0.05,
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
            stopProgressSync()
        }
    }
}
