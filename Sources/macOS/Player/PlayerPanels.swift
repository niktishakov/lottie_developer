#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Timeline

/// Транспорт: play/pause, шаг по кадрам, скраббер, маркеры, режим проигрывания, скорость.
struct TimelineBar: View {
    @Bindable var model: PlayerModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { model.step(-1) } label: { Image(systemName: "backward.frame") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Previous frame (←)")
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (Space)")
                Button { model.step(1) } label: { Image(systemName: "forward.frame") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Next frame (→)")

                Slider(value: Binding(get: { model.frame }, set: { model.seek($0) }),
                       in: model.startFrame...max(model.endFrame, model.startFrame + 1))

                Text("\(Int(model.frame.rounded())) / \(Int(model.endFrame))")
                    .monospacedDigit().frame(width: 74, alignment: .trailing)
                Text(String(format: "%.2fs", model.frame / max(model.fps, 1)))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Picker("", selection: $model.mode) {
                    ForEach(PlayerModel.PlayMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Loop / Once — preview. Button / Switch — click the canvas to trigger like a UI control.")

                if !model.markers.isEmpty {
                    Menu {
                        Button("Whole timeline") { model.playMarker(nil) }
                        Divider()
                        ForEach(model.markers, id: \.self) { m in Button(m) { model.playMarker(m) } }
                    } label: {
                        Label(model.activeMarker ?? "All markers", systemImage: "flag")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }

                if model.mode == .toggle {
                    Text(model.toggleOn ? "Switch: on" : "Switch: off").font(.caption).foregroundStyle(.secondary)
                }

                Spacer()
                Text("Speed").foregroundStyle(.secondary)
                Slider(value: $model.speed, in: 0.1...3).frame(width: 110)
                Text(String(format: "%.2fx", model.speed)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            .font(.callout)
        }
    }
}

// MARK: - Filmstrip

/// Раскадровка: N кадров офскрин-рендером; клик — переход к кадру.
struct FilmstripView: View {
    let model: PlayerModel
    var count = 10
    @State private var thumbs: [(frame: Double, image: NSImage)] = []

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(thumbs.enumerated()), id: \.offset) { _, t in
                Button { model.seek(t.frame) } label: {
                    ZStack(alignment: .bottomLeading) {
                        CheckerboardBackground()
                        Image(nsImage: t.image).resizable().scaledToFit().padding(2)
                        Text("\(Int(t.frame))").font(.system(size: 9).monospacedDigit())
                            .padding(.horizontal, 3).background(.black.opacity(0.5)).foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(FilmstripHighlight(model: model, frame: t.frame, step: step))
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: model.revision) { render() }
    }

    private var step: Double { (model.endFrame - model.startFrame) / Double(max(count - 1, 1)) }

    private func render() {
        guard let anim = model.animation else { thumbs = []; return }
        thumbs = (0..<count).compactMap { i in
            let f = (anim.startFrame + step * Double(i)).rounded()
            guard let (img, _) = try? FrameRenderer.renderImage(animation: anim, frame: f, size: 160, background: nil) else { return nil }
            return (f, NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
        }
    }
}

/// Отдельная вью, чтобы на каждый тик перерисовывалась только рамка, а не картинки.
private struct FilmstripHighlight: View {
    let model: PlayerModel
    let frame: Double
    let step: Double
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(abs(model.frame - frame) <= step / 2 ? Color.accentColor : .clear, lineWidth: 2)
    }
}

// MARK: - Layers

struct LayersPanel: View {
    let model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Text("\(model.layers.count)").foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.layers) { info in row(info) }
                }
                .padding(6)
            }
            if model.hasEdits {
                Divider()
                Button("Reset all edits") { model.resetEdits() }.padding(10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ info: LottieLayerInfo) -> some View {
        let selected = model.selectedLayer == info.name
        let o = model.override(for: info.name)
        return HStack(spacing: 6) {
            Image(systemName: info.symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(info.name).lineLimit(1).truncationMode(.middle)
            if !o.isEmpty && !(o.hidden && o.color == nil && o.opacity == nil) {
                Circle().fill(Color.orange).frame(width: 6, height: 6).help("Edited")
            }
            Spacer(minLength: 4)
            Button { model.toggleHidden(info.name) } label: {
                Image(systemName: o.hidden ? "eye.slash" : "eye").foregroundStyle(o.hidden ? .secondary : .primary)
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.28) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.select(selected ? nil : info.name) }
        .opacity(o.hidden ? 0.55 : 1)
    }
}

// MARK: - Inspector

/// Правка выбранного слоя на лету (цвет, прозрачность, видимость) + сохранение в новую версию.
struct InspectorPanel: View {
    let model: PlayerModel
    var onSaveVersion: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inspector").font(.headline)
            if let name = model.selectedLayer {
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                let o = model.override(for: name)

                HStack {
                    Text("Color").foregroundStyle(.secondary)
                    Spacer()
                    ColorPicker("", selection: colorBinding(name), supportsOpacity: false).labelsHidden()
                    if o.color != nil {
                        Button { var n = o; n.color = nil; model.setOverride(n, for: name) } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }.buttonStyle(.plain).help("Reset color")
                    }
                }
                HStack {
                    Text("Opacity").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { o.opacity ?? 100 }, set: { v in
                        var n = model.override(for: name); n.opacity = v >= 99.5 ? nil : v; model.setOverride(n, for: name)
                    }), in: 0...100)
                    Text("\(Int(o.opacity ?? 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                Toggle("Hidden", isOn: Binding(get: { o.hidden }, set: { _ in model.toggleHidden(name) }))
            } else {
                Text("Select a layer in the list or click it on the canvas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                onSaveVersion()
            } label: {
                Label("Save edits as new version", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
            }
            .disabled(!model.hasEdits)
        }
        .padding(10)
    }

    private func colorBinding(_ name: String) -> Binding<Color> {
        Binding(
            get: {
                let hex = model.override(for: name).color ?? model.originalColor(of: name)
                return FrameRenderer.color(hex: hex).map(Color.init(nsColor:)) ?? .white
            },
            set: { c in
                guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
                var n = model.override(for: name)
                n.color = String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
                model.setOverride(n, for: name)
            })
    }
}
#endif
