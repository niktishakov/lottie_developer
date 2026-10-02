#if os(macOS)
import SwiftUI
import AppKit
import Lottie

/// `LottieAnimationView`, которым управляет `PlayerModel`: кадр выставляется вручную на каждый тик,
/// при смене версии/движка/reduced motion вью пересоздаётся (конфигурация задаётся только при init).
struct LottieCanvas: NSViewRepresentable {
    let model: PlayerModel
    var compare = false

    func makeNSView(context: Context) -> FlexibleLottieContainer { FlexibleLottieContainer() }

    func updateNSView(_ container: FlexibleLottieContainer, context: Context) {
        let rev = compare ? model.compareRevision : model.revision
        let anim = compare ? model.compareAnimation : model.animation
        if context.coordinator.revision != rev {
            context.coordinator.revision = rev
            let config = LottieConfiguration(renderingEngine: model.engine.option,
                                             reducedMotionOption: model.reducedMotion ? .reducedMotion : .standardMotion)
            container.replaceAnimationView(LottieAnimationView(animation: anim, configuration: config))
            if !compare {
                let used = container.animationView.currentRenderingEngine
                DispatchQueue.main.async { model.activeEngine = used.map { "\($0)" } ?? "—" }
            }
        }
        // Чтение model.frame подписывает вью на каждый тик часов.
        container.animationView.currentFrame = model.frame
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var revision = -1 }
}

/// Сцена превью: фон, рамка устройства / фиксированный размер, рамка выбранного слоя, клики.
struct CanvasStage: View {
    let model: PlayerModel
    var compare = false

    var body: some View {
        GeometryReader { geo in
            let outer = CGRect(origin: .zero, size: geo.size)
            let screen = screenRect(in: outer)
            let anim = animRect(in: screen)
            ZStack(alignment: .topLeading) {
                backdrop
                    .frame(width: screen.width, height: screen.height)
                    .clipShape(RoundedRectangle(cornerRadius: model.stage == .iphone ? 36 : 10, style: .continuous))
                    .offset(x: screen.minX, y: screen.minY)

                if model.stage == .iphone {
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .strokeBorder(Color(white: 0.35), lineWidth: 6)
                        .frame(width: screen.width + 12, height: screen.height + 12)
                        .offset(x: screen.minX - 6, y: screen.minY - 6)
                    Capsule().fill(Color.black)
                        .frame(width: screen.width * 0.3, height: 22)
                        .offset(x: screen.midX - screen.width * 0.15, y: screen.minY + 10)
                }

                LottieCanvas(model: model, compare: compare)
                    .frame(width: anim.width, height: anim.height)
                    .offset(x: anim.minX, y: anim.minY)
                    .allowsHitTesting(false)

                if !compare, let box = model.selectionBox {
                    let s = anim.width / max(model.compSize.width, 1)
                    Rectangle()
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .background(Color.accentColor.opacity(0.06))
                        .frame(width: max(box.width * s + 6, 6), height: max(box.height * s + 6, 6))
                        .offset(x: anim.minX + box.minX * s - 3, y: anim.minY + box.minY * s - 3)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                guard !compare else { return }
                if model.mode == .button || model.mode == .toggle { model.triggerControl(); return }
                guard anim.contains(tap.location) else { model.select(nil); return }
                let s = anim.width / max(model.compSize.width, 1)
                model.pickLayer(atComp: CGPoint(x: (tap.location.x - anim.minX) / s, y: (tap.location.y - anim.minY) / s))
            })
        }
    }

    @ViewBuilder private var backdrop: some View {
        switch model.backdrop {
        case .checker: CheckerboardBackground()
        case .light: Color.white
        case .dark: Color(white: 0.07)
        }
    }

    /// Область «экрана»: всё поле, или экран iPhone (390×844 pt), вписанный по высоте.
    private func screenRect(in r: CGRect) -> CGRect {
        guard model.stage == .iphone else { return r }
        let phone = CGSize(width: 390, height: 844)
        let s = min((r.width - 24) / phone.width, (r.height - 24) / phone.height)
        let w = phone.width * s, h = phone.height * s
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// Прямоугольник самой анимации (с сохранением пропорций композиции).
    private func animRect(in screen: CGRect) -> CGRect {
        let comp = model.compSize
        let aspect = comp.width / max(comp.height, 1)
        var w: CGFloat, h: CGFloat
        if let pts = model.stage.fixedPoints {
            if aspect >= 1 { w = pts; h = pts / aspect } else { h = pts; w = pts * aspect }
        } else {
            let pad: CGFloat = model.stage == .iphone ? screen.width * 0.12 : 8
            let box = screen.insetBy(dx: pad, dy: pad)
            if box.width / max(box.height, 1) > aspect { h = box.height; w = h * aspect } else { w = box.width; h = w / aspect }
        }
        return CGRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: max(w, 1), height: max(h, 1))
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.22)))
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.28)))
                }
            }
        }
    }
}
#endif
