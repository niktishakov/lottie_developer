#if os(iOS)
import SwiftUI
import Observation

/// Полный экран анимации поверх всего приложения (выше шапки и вкладок): холст растёт со своего места до экрана и обратно.
/// Шапку и вкладки не прячем — растущая анимация их просто накрывает, поэтому ничего не дёргается и страница не сдвигается.
@MainActor
@Observable
final class FullscreenHero {
    private(set) var player: DevPlayerController?
    private(set) var isPresented = false
    /// false — холст на своём месте, true — на весь экран. Анимируется только это значение.
    private(set) var expanded = false
    private(set) var sourceRect: CGRect = .zero
    private(set) var background: DevBackground = .checker
    private(set) var backgroundHex = "#FFFFFF"
    var showControls = true

    static let spring = Animation.spring(duration: 0.42, bounce: 0.1)

    func isShowing(_ p: DevPlayerController) -> Bool { isPresented && player === p }

    /// Слой встаёт ровно на место холста (живой вид Lottie переезжает в него), потом рамка растёт до экрана.
    func open(_ player: DevPlayerController, from rect: CGRect, background: DevBackground, hex: String) {
        self.player = player
        self.background = background
        backgroundHex = hex
        sourceRect = rect
        showControls = true
        expanded = false
        isPresented = true
        Task { @MainActor in withAnimation(Self.spring) { self.expanded = true } }
    }

    /// Рамка сжимается обратно, после этого вид возвращается в холст плеера.
    func close() {
        withAnimation(Self.spring, completionCriteria: .logicallyComplete) { expanded = false } completion: {
            // Кнопка «на весь экран» в плеере проявляется, сам холст подменяется без перехода (без наложения картинок).
            withAnimation(.easeOut(duration: 0.2)) {
                self.isPresented = false
                self.player = nil
            }
        }
    }
}

/// Холст: фон + живая анимация. Один вид и в плеере, и на весь экран.
struct PlayerCanvas: View {
    let player: DevPlayerController
    let background: DevBackground
    let backgroundHex: String
    var cornerRadius: CGFloat = 24

    var body: some View {
        ZStack {
            DevBackgroundView(kind: background, customHex: backgroundHex)
            DevLottieCanvas(controller: player).aspectRatio(player.aspect, contentMode: .fit)
            if let err = player.loadError {
                Text(err).font(.callout).foregroundStyle(.red).padding()
            }
        }
        // Скругление по самому холсту (UIKit-вид Lottie иначе выходит за маску).
        .mask(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Слой полного экрана на корне приложения. Тап — пауза/воспроизведение, внизу шкала, ✕ или свайп вниз — выход.
/// Управление прячется через 2 с воспроизведения.
struct FullscreenHeroLayer: View {
    @Bindable var hero: FullscreenHero

    var body: some View {
        if let player = hero.player {
            GeometryReader { g in
                let full = g.frame(in: .global)
                let r = hero.expanded ? full : hero.sourceRect
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(hero.expanded ? 1 : 0)
                    PlayerCanvas(player: player, background: hero.background, backgroundHex: hero.backgroundHex,
                                 cornerRadius: hero.expanded ? 0 : 24)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX - full.minX, y: r.minY - full.minY)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { player.toggle(); withAnimation { hero.showControls = true } }
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if v.translation.height > 100 { hero.close() }
            })
            .overlay(alignment: .topTrailing) {
                if hero.showControls && hero.expanded {
                    Button { hero.close() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.5)))
                    }
                    .accessibilityLabel("Close full screen")
                    .padding()
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if hero.showControls && hero.expanded { controls(player).transition(.opacity) }
            }
            .statusBarHidden(hero.expanded)
            .task(id: player.isPlaying) {
                guard player.isPlaying else { hero.showControls = true; return }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { hero.showControls = false }
            }
        }
    }

    private func controls(_ player: DevPlayerController) -> some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            Scrubber(frame: player.frame, start: player.startFrame, end: player.endFrame, markers: []) {
                player.seek($0.rounded())
            }
            Text(String(format: "%.2f s", max(0, player.frame - player.startFrame) / max(player.framerate, 1)))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.white)
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.55)))
        .padding()
    }
}
#endif
