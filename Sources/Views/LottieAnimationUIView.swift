import SwiftUI
import Lottie

struct LottieView: UIViewRepresentable {
    let fileURL: URL
    let playback: PlaybackState

    func makeUIView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        view.contentMode = .scaleAspectFit
        view.backgroundBehavior = .pauseAndRestore
        return view
    }

    func updateUIView(_ uiView: LottieAnimationView, context: Context) {
        if context.coordinator.loadedURL != fileURL {
            context.coordinator.loadedURL = fileURL
            let animation = LottieAnimation.filepath(fileURL.path)
            uiView.animation = animation
        }

        uiView.animationSpeed = CGFloat(playback.speed)
        uiView.loopMode = playback.loopEnabled ? .loop : .playOnce

        if playback.isPlaying {
            uiView.play(
                fromProgress: CGFloat(playback.fromProgress),
                toProgress: CGFloat(playback.toProgress),
                loopMode: playback.loopEnabled ? .loop : .playOnce
            )
        } else {
            uiView.pause()
            uiView.currentProgress = CGFloat(playback.currentProgress)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var loadedURL: URL?
    }
}
