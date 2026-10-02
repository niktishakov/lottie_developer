#if os(macOS)
import SwiftUI
import AppKit
import Lottie
import Observation

/// Состояние плеера редактора. Время ведём сами (а не через `play()` Lottie):
/// так скраббер, шаг по кадрам, сравнение двух версий и диапазоны маркеров синхронны по определению.
@MainActor
@Observable
final class PlayerModel {

    enum PlayMode: String, CaseIterable, Identifiable {
        case loop = "Loop", once = "Once", button = "Button", toggle = "Switch"
        var id: String { rawValue }
    }

    enum Engine: String, CaseIterable, Identifiable {
        case automatic = "Automatic", coreAnimation = "Core Animation", mainThread = "Main thread"
        var id: String { rawValue }
        var option: RenderingEngineOption {
            switch self {
            case .automatic: return .automatic
            case .coreAnimation: return .coreAnimation
            case .mainThread: return .mainThread
            }
        }
    }

    enum Backdrop: String, CaseIterable, Identifiable {
        case checker = "Checker", light = "Light", dark = "Dark"
        var id: String { rawValue }
    }

    enum Stage: String, CaseIterable, Identifiable {
        case fit = "Fit", iphone = "iPhone", pt120 = "120 pt", pt48 = "48 pt", pt24 = "24 pt"
        var id: String { rawValue }
        var fixedPoints: CGFloat? {
            switch self {
            case .pt120: return 120
            case .pt48: return 48
            case .pt24: return 24
            default: return nil
            }
        }
    }

    // MARK: Source

    /// Исходные данные текущей версии (без правок).
    private(set) var sourceData: Data?
    /// То, что реально показываем: исходник + запечённые правки.
    private(set) var displayData: Data?
    private(set) var animation: LottieAnimation?
    private(set) var layers: [LottieLayerInfo] = []
    /// Растёт при каждой смене `animation` — по нему канвас понимает, что надо перезагрузиться.
    private(set) var revision = 0

    // MARK: Compare

    private(set) var compareAnimation: LottieAnimation?
    private(set) var compareLabel: String?
    private(set) var compareRevision = 0

    // MARK: Playback

    var frame: Double = 0
    var isPlaying = true
    var speed: Double = 1
    var mode: PlayMode = .loop { didSet { isPlaying = mode == .loop; toggleOn = false } }
    /// Активный диапазон кадров (маркер или весь таймлайн).
    var range: ClosedRange<Double> = 0...1
    var activeMarker: String?
    /// Состояние переключателя (режим Switch): false — первая половина, true — вторая.
    var toggleOn = false

    // MARK: View options

    var engine: Engine = .automatic { didSet { revision += 1; compareRevision += 1 } }
    /// Как в Lottie: при reduced motion анимация не играет, показываем кадр маркера
    /// "reduced motion" (если есть) или последний кадр.
    var reducedMotion = false {
        didSet {
            revision += 1; compareRevision += 1
            if reducedMotion { isPlaying = false; frame = reducedMotionFrame; updateSelectionBox() }
        }
    }

    private var reducedMotionFrame: Double {
        if let anim = animation, let name = anim.markerNames.first(where: { $0.lowercased() == "reduced motion" }),
           let f = anim.frameTime(forMarker: name) { return Double(f) }
        return endFrame
    }
    /// Движок, который Lottie реально выбрал (для Automatic может отличаться).
    var activeEngine = "—"
    var backdrop: Backdrop = .checker
    var stage: Stage = .fit

    // MARK: Layers / edits

    var selectedLayer: String?
    private(set) var overrides: [String: LayerOverride] = [:]
    /// Рамка выбранного слоя на текущем кадре (координаты композиции).
    private(set) var selectionBox: CGRect?

    var hasEdits: Bool { overrides.values.contains { !$0.isEmpty } }

    var startFrame: Double { animation.map { Double($0.startFrame) } ?? 0 }
    var endFrame: Double { animation.map { Double($0.endFrame) } ?? 1 }
    var fps: Double { animation.map { Double($0.framerate) } ?? 60 }
    var compSize: CGSize { animation?.bounds.size ?? CGSize(width: 100, height: 100) }
    var markers: [String] { animation?.markerNames ?? [] }

    private var clock: Task<Void, Never>?
    private var boxFrame: Double = -1

    // MARK: - Loading

    func load(data: Data?) {
        sourceData = data
        overrides = [:]
        selectionBox = nil
        rebuild(resetFrame: true)
        if let sel = selectedLayer, !layers.contains(where: { $0.name == sel }) { selectedLayer = nil }
    }

    func loadCompare(data: Data?, label: String?) {
        compareAnimation = data.flatMap { try? FrameRenderer.decode($0) }
        compareLabel = data == nil ? nil : label
        compareRevision += 1
    }

    private func rebuild(resetFrame: Bool) {
        guard let src = sourceData else {
            displayData = nil; animation = nil; layers = []; revision += 1; return
        }
        let data = LottieOverrides.apply(overrides, to: src)
        displayData = data
        animation = try? FrameRenderer.decode(data)
        layers = LottieOverrides.layers(in: src)
        if resetFrame {
            activeMarker = nil
            range = startFrame...max(endFrame, startFrame + 1)
            frame = range.lowerBound
            toggleOn = false
            if mode != .loop { isPlaying = false }
        }
        revision += 1
        boxFrame = -1
        updateSelectionBox()
    }

    // MARK: - Clock

    func startClock() {
        guard clock == nil else { return }
        clock = Task { @MainActor [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self else { return }
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                self.tick(dt)
            }
        }
    }

    func stopClock() { clock?.cancel(); clock = nil }

    private func tick(_ dt: TimeInterval) {
        guard isPlaying, animation != nil, !reducedMotion else { return }
        let next = frame + dt * fps * speed
        switch mode {
        case .loop:
            let len = max(range.upperBound - range.lowerBound, 1)
            frame = next > range.upperBound ? range.lowerBound + (next - range.lowerBound).truncatingRemainder(dividingBy: len) : next
        case .once, .button, .toggle:
            let end = playbackEnd
            if next >= end { frame = end; isPlaying = false } else { frame = next }
        }
        if Int(frame) % 3 == 0 { updateSelectionBox() }
    }

    /// Конец текущего проигрывания для Once/Button/Switch.
    private var playbackEnd: Double {
        if mode == .toggle { return toggleOn ? range.upperBound : midFrame }
        return range.upperBound
    }

    private var midFrame: Double { (range.lowerBound + range.upperBound) / 2 }

    // MARK: - Transport

    func togglePlay() {
        guard !reducedMotion else { return }
        if !isPlaying && mode != .loop && frame >= playbackEnd { frame = range.lowerBound }
        isPlaying.toggle()
    }

    func step(_ delta: Int) {
        isPlaying = false
        frame = min(max((frame + Double(delta)).rounded(), startFrame), endFrame)
        updateSelectionBox()
    }

    func seek(_ f: Double) {
        isPlaying = false
        frame = min(max(f, startFrame), endFrame)
        updateSelectionBox()
    }

    /// Клик по превью в режимах Button/Switch — как пользователь нажал бы на контрол.
    func triggerControl() {
        switch mode {
        case .button:
            frame = range.lowerBound; isPlaying = true
        case .toggle:
            toggleOn.toggle()
            frame = toggleOn ? midFrame : range.lowerBound
            isPlaying = true
        default: break
        }
    }

    func playMarker(_ name: String?) {
        guard let animation else { return }
        if let name, let start = animation.frameTime(forMarker: name),
           let dur = animation.durationFrameTime(forMarker: name) {
            activeMarker = name
            let s = min(max(Double(start), startFrame), endFrame)
            // Маркер без длительности — точка входа: играем от неё до конца.
            let e = dur > 0 ? min(Double(start + dur), endFrame) : endFrame
            let lo = max(min(s, endFrame - 1), startFrame)
            range = lo...max(min(e, endFrame), lo + 1)
        } else {
            activeMarker = nil
            range = startFrame...max(endFrame, startFrame + 1)
        }
        frame = range.lowerBound
        isPlaying = true
    }

    // MARK: - Edits

    func override(for layer: String) -> LayerOverride { overrides[layer] ?? LayerOverride() }

    func setOverride(_ o: LayerOverride, for layer: String) {
        overrides[layer] = o.isEmpty ? nil : o
        rebuild(resetFrame: false)
    }

    func toggleHidden(_ layer: String) {
        var o = override(for: layer)
        o.hidden.toggle()
        setOverride(o, for: layer)
    }

    func resetEdits() {
        overrides = [:]
        rebuild(resetFrame: false)
    }

    func originalColor(of layer: String) -> String? {
        sourceData.flatMap { LottieOverrides.firstColor(layerName: layer, in: $0) }
    }

    // MARK: - Selection

    func select(_ layer: String?) {
        selectedLayer = layer
        boxFrame = -1
        updateSelectionBox()
    }

    /// Выбор слоя кликом: офскрин-рендер каждого слоя отдельно, берём верхний непрозрачный в точке.
    /// Тап по точке композиции — так же, как клик по холсту (выбор слоя или срабатывание контрола).
    func tap(atComp p: CGPoint) {
        if mode == .button || mode == .toggle { triggerControl() } else { pickLayer(atComp: p) }
    }

    func pickLayer(atComp p: CGPoint) {
        guard let data = displayData, let anim = animation else { return }
        _ = anim
        for info in layers where !info.isMatte && info.type != 3 {
            let iso = LottieOverrides.isolate(layerIndex: info.index, in: data)
            guard let a = try? FrameRenderer.decode(iso),
                  let (img, scale) = try? FrameRenderer.renderImage(animation: a, frame: frame, size: 256, background: nil)
            else { continue }
            if FrameRenderer.isOpaque(img, scale: scale, at: p) { select(info.name); return }
        }
        select(nil)
    }

    private func updateSelectionBox() {
        guard let name = selectedLayer, let data = displayData,
              let info = layers.first(where: { $0.name == name }) else { selectionBox = nil; return }
        guard abs(boxFrame - frame) >= 1 || boxFrame < 0 else { return }
        boxFrame = frame
        let iso = LottieOverrides.isolate(layerIndex: info.index, in: data)
        guard let a = try? FrameRenderer.decode(iso),
              let (img, scale) = try? FrameRenderer.renderImage(animation: a, frame: frame, size: 256, background: nil)
        else { selectionBox = nil; return }
        selectionBox = FrameRenderer.opaqueBounds(img, scale: scale)
    }

    // MARK: - Perf

    /// Среднее время офскрин-рендера кадра (main-thread engine), мс — грубая оценка тяжести анимации.
    func measureFrameCost(samples: Int = 12) -> Double? {
        guard let anim = animation else { return nil }
        let t0 = Date()
        for i in 0..<samples {
            let f = startFrame + (endFrame - startFrame) * Double(i) / Double(max(samples - 1, 1))
            _ = try? FrameRenderer.renderImage(animation: anim, frame: f, size: 512, background: nil)
        }
        return Date().timeIntervalSince(t0) * 1000 / Double(samples)
    }
}
#endif
