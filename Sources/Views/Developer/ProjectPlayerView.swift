#if os(iOS)
import SwiftUI
import Inject

/// Плеер проекта на настоящем lottie-ios. Сверху крупная анимация, под ней одна панель управления
/// (шкала с метками комментариев, скорость, повтор, фон, остальное в «•••»), заметка Claude и кнопка комментария.
struct ProjectPlayerView: View {
    @ObserveInjection private var inject
    let store: ProjectStore
    let projectID: UUID
    var command: ProjectStore.UICommand?

    /// nil — статичная геометрия.
    @State private var selectedVersionID: UUID?
    @State private var didPickInitial = false
    @State private var player = DevPlayerController()
    @AppStorage("player.background") private var background: DevBackground = .checker
    @AppStorage("player.backgroundHex") private var backgroundHex = "#FFFFFF"
    @State private var choosingBackground = false
    @State private var fullscreen = false
    @State private var showFullscreenControls = true
    /// 0 — холст на своём месте, 1 — на весь экран. Анимируется только это число: рамка и скругление считаются из него.
    @State private var expanded = false
    /// Где холст в плеере (глобальные координаты) — откуда растёт и куда возвращается полный экран.
    @State private var canvasRect: CGRect = .zero
    @State private var sourceRect: CGRect = .zero
    /// Шапка и панель вкладок прячутся, только когда анимация уже на весь экран: иначе страница под ней прыгает.
    @State private var barsHidden = false
    @State private var newComment = ""
    @State private var composing = false
    @State private var appliedCommandAt: Date?

    private var project: AnimationProject? { store.project(projectID) }
    private var versions: [AnimationVersion] {
        (project?.versions ?? []).sorted { $0.index > $1.index }
    }
    private var selectedVersion: AnimationVersion? {
        versions.first { $0.id == selectedVersionID }
    }
    private var currentURL: URL? {
        guard let project else { return nil }
        if let v = selectedVersion { return store.versionURL(project.id, v.compiledFile) }
        return store.geometryPreviewURL(for: project)
    }
    /// Перезагружать, когда меняется файл версии или список версий (MCP добавил новую).
    private var loadKey: String {
        "\(selectedVersionID?.uuidString ?? "static")|\(project?.updatedAt.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        content.enableInjection()
    }

    @ViewBuilder private var content: some View {
        ZStack {
            page
            if fullscreen { fullscreenLayer }
        }
        .toolbar(barsHidden ? .hidden : .visible, for: .navigationBar, .tabBar)
        .statusBarHidden(barsHidden)
    }

    @ViewBuilder private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                canvas
                transport
                if let v = selectedVersion, !v.prompt.isEmpty || !v.note.isEmpty { claudeNote(v) }
                Button { player.pause(); composing = true } label: {
                    // Без номера кадра: при воспроизведении он бы постоянно менялся. Кадр видно в окне комментария.
                    Label("Add comment", systemImage: "text.bubble")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                comments
            }
            .padding()
        }
        .navigationTitle(project?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { versionMenu }
        }
        .onAppear {
            if !didPickInitial { didPickInitial = true; selectedVersionID = versions.first?.id }
            applyCommand()
            if let project { SeenVersions.markSeen(project) }
        }
        .sheet(isPresented: $composing) { commentSheet }
        .sheet(isPresented: $choosingBackground) {
            BackgroundSheet(kind: $background, customHex: $backgroundHex, lottieURL: currentURL)
        }
        .onChange(of: command?.issuedAt) { _, _ in applyCommand() }
        .onChange(of: versions.first?.id) { old, new in
            // Пришла новая версия от Claude — показываем её, если смотрели последнюю.
            if selectedVersionID == old, let new { selectedVersionID = new }
            if let project { SeenVersions.markSeen(project) }
        }
        .task(id: loadKey) {
            guard let url = currentURL else { return }
            let pendingFrame = pendingCommandFrame
            pendingCommandFrame = nil
            player.load(url: url, frame: pendingFrame, autoplay: pendingFrame == nil && selectedVersion != nil)
        }
        .onDisappear { player.teardown() }
    }

    @State private var pendingCommandFrame: Double?

    private func applyCommand() {
        guard let cmd = command, cmd.issuedAt != appliedCommandAt else { return }
        appliedCommandAt = cmd.issuedAt
        if let vid = cmd.versionID, versions.contains(where: { $0.id == vid }) {
            if vid != selectedVersionID {
                pendingCommandFrame = cmd.frame
                selectedVersionID = vid
                return
            }
        }
        if let f = cmd.frame {
            // Плеер ещё не загрузил файл (только открыли проект) — кадр применит загрузка.
            if player.endFrame == 0 { pendingCommandFrame = f } else { player.pause(); player.seek(f) }
        }
    }

    // MARK: - Canvas

    /// Холст: фон + живая анимация. Один и тот же вид в плеере и на весь экран — matchedGeometryEffect
    /// плавно меняет ему рамку и скругление, без наложения двух картинок.
    private func canvasCore(cornerRadius: CGFloat) -> some View {
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

    private var canvas: some View {
        Group {
            if fullscreen { Color.clear } else { canvasCore(cornerRadius: 24) }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { canvasRect = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, r in canvasRect = r }
        })
        // Форма анимации, но не выше 60% экрана: вертикальный экран не вытесняет панель управления.
        .aspectRatio(player.aspect, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if !fullscreen {
                Button { setFullscreen(true) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Circle().fill(.black.opacity(0.45)))
                }
                .accessibilityLabel("Full screen")
                .padding(10)
            }
        }
        .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
        .frame(maxWidth: .infinity)
        .onTapGesture { player.toggle() }
    }

    private static let heroSpring = Animation.spring(duration: 0.42, bounce: 0.1)

    /// Открытие: слой встаёт ровно на место холста (живой вид Lottie переезжает в него), потом рамка растёт до экрана.
    /// Закрытие: рамка сжимается обратно, после этого вид возвращается в холст. Наложения двух картинок нет.
    private func setFullscreen(_ on: Bool) {
        showFullscreenControls = true
        if on {
            sourceRect = canvasRect
            expanded = false
            fullscreen = true
            Task { @MainActor in
                withAnimation(Self.heroSpring) { expanded = true } completion: { barsHidden = true }
            }
        } else {
            barsHidden = false
            withAnimation(Self.heroSpring, completionCriteria: .logicallyComplete) { expanded = false } completion: {
                fullscreen = false
            }
        }
    }

    // MARK: - Полный экран

    /// Тап — пауза/воспроизведение, внизу шкала, ✕ или свайп вниз — выход. Управление прячется через 2 с воспроизведения.
    private var fullscreenLayer: some View {
        GeometryReader { g in
            let full = g.frame(in: .global)
            let r = expanded ? full : sourceRect
            ZStack(alignment: .topLeading) {
                Color.black.opacity(expanded ? 1 : 0)
                canvasCore(cornerRadius: expanded ? 0 : 24)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX - full.minX, y: r.minY - full.minY)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
            .onTapGesture { player.toggle(); withAnimation { showFullscreenControls = true } }
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if v.translation.height > 100 { setFullscreen(false) }
            })
            .overlay(alignment: .topTrailing) {
                if showFullscreenControls && expanded {
                    Button { setFullscreen(false) } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.5)))
                    }
                    .accessibilityLabel("Close full screen")
                    .padding()
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if showFullscreenControls && expanded {
                    HStack(spacing: 12) {
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3).foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                        Scrubber(frame: player.frame, start: player.startFrame, end: player.endFrame, markers: []) {
                            player.seek($0.rounded())
                        }
                        Text(timeText).font(.subheadline.monospacedDigit()).foregroundStyle(.white)
                            .frame(minWidth: 58, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding()
                    .transition(.opacity)
                }
            }
            .task(id: player.isPlaying) {
                guard player.isPlaying else { showFullscreenControls = true; return }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showFullscreenControls = false }
            }
    }

    // MARK: - Transport

    private var transport: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Circle().fill(.tint))
                }
                .buttonStyle(.plain)
                Scrubber(frame: player.frame, start: player.startFrame, end: player.endFrame,
                         markers: commentFrames) { player.seek($0.rounded()) }
                Text(timeText).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 58, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Menu {
                    Picker("Speed", selection: $player.speed) {
                        ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { s in Text(Self.speedText(s)).tag(s) }
                    }
                } label: { Chip(text: Self.speedText(player.speed)) }
                Button { player.loop.toggle() } label: { Chip(text: "Loop", on: player.loop) }
                    .buttonStyle(.plain)
                Button { choosingBackground = true } label: {
                    HStack(spacing: 6) {
                        if background == .custom {
                            Circle().fill(Color(hex: backgroundHex) ?? .white).frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 0.5))
                        }
                        Chip(text: background == .custom ? backgroundHex : background.rawValue)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Picker("Engine", selection: $player.engine) {
                        ForEach(DevEngineChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("Engine in use: \(player.activeEngine)")
                } label: { Chip(text: "•••") }
            }
        }
        .devCard()
    }

    private var timeText: String { seconds(player.frame) }

    /// Кадр → время от начала, «2.77 s». Дизайнеру понятнее секунды, чем номер кадра.
    private func seconds(_ frame: Double) -> String {
        String(format: "%.2f s", max(0, frame - player.startFrame) / max(player.framerate, 1))
    }

    static func speedText(_ s: Double) -> String { s == 1 ? "1×" : "\(s.formatted())×" }

    /// Кадры открытых комментариев к этой версии — красные метки на шкале.
    private var commentFrames: [Double] {
        feedback.filter { !$0.resolved && $0.versionID == selectedVersion?.id }.map { Double($0.frame) }
    }

    private func claudeNote(_ v: AnimationVersion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: v.source == "file" ? "square.and.arrow.down" : "sparkle").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(v.source == "file" ? "Imported" : "Agent") · \(v.label)").font(.subheadline.weight(.semibold))
                if !v.note.isEmpty { Text(v.note).font(.subheadline).foregroundStyle(.secondary) }
                if !v.prompt.isEmpty, v.prompt != v.note {
                    Text(v.prompt).font(.footnote).foregroundStyle(.tertiary)
                }
            }
        }
        .devCard()
    }

    private var versionMenu: some View {
        Menu {
            Picker("Version", selection: $selectedVersionID) {
                ForEach(versions) { v in
                    Text(v.isFavourite ? "\(v.label) ★" : v.label).tag(Optional(v.id))
                }
                Text("Static geometry").tag(UUID?.none)
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedVersion?.label ?? "Static").font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
        }
    }

    // MARK: - Comments

    private var feedback: [FeedbackItem] {
        _ = store.feedbackRevision
        return store.feedback(projectID: projectID).sorted { $0.createdAt > $1.createdAt }
    }

    @State private var feedbackTick = 0

    private var comments: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comments").font(.headline)
            let items = feedback
            let _ = feedbackTick
            if items.isEmpty {
                Text("Pause on a moment and leave a comment. The agent reads it and makes a fix.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Button { jump(to: item) } label: { commentRow(item) }
                    .buttonStyle(.plain)
            }
        }
        .devCard()
    }

    private func commentRow(_ item: FeedbackItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(item.versionLabel) · \(seconds(Double(item.frame)))").font(.caption.bold())
                if let layer = item.layer { Text(layer).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if item.resolved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            Text(item.text).font(.callout)
            if let reply = item.reply, !reply.isEmpty {
                Text("Agent: \(reply)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
        .opacity(item.resolved ? 0.6 : 1)
    }

    private var commentSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(selectedVersion?.label ?? "Static") · at \(seconds(player.frame))")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextField("What should change here?", text: $newComment, axis: .vertical)
                    .lineLimit(3...8)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
                Spacer()
            }
            .padding()
            .navigationTitle("Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { composing = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addComment(); composing = false }
                        .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func addComment() {
        let text = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        player.pause()
        let item = FeedbackItem(versionID: selectedVersion?.id,
                                versionLabel: selectedVersion?.label ?? "static",
                                frame: Int(player.frame.rounded()),
                                layer: nil, text: text)
        _ = store.addFeedback(projectID: projectID, item)
        newComment = ""
        feedbackTick += 1
    }

    private func jump(to item: FeedbackItem) {
        if let vid = item.versionID, vid != selectedVersionID, versions.contains(where: { $0.id == vid }) {
            pendingCommandFrame = Double(item.frame)
            selectedVersionID = vid
        } else {
            player.seek(Double(item.frame))
        }
    }
}
#endif

#if os(iOS)
/// Шкала кадров с метками комментариев. Тянется пальцем, тап — переход к кадру.
private struct Scrubber: View {
    let frame: Double
    let start: Double
    let end: Double
    let markers: [Double]
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let span = max(end - start, 1)
            let x = { (f: Double) in CGFloat((f - start) / span) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 4)
                Capsule().fill(.tint).frame(width: max(0, x(frame)), height: 4)
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    Circle().fill(.red).frame(width: 9, height: 9).offset(x: x(m) - 4.5, y: -11)
                }
                Circle().fill(.white).frame(width: 18, height: 18).shadow(radius: 1)
                    .offset(x: x(frame) - 9)
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onSeek(start + Double(min(max(v.location.x / w, 0), 1)) * span)
            })
        }
        .frame(height: 34)
    }
}

/// Маленькая кнопка-капсула в панели плеера.
private struct Chip: View {
    let text: String
    var on = false
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold))
            .foregroundStyle(on ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.18)))
    }
}
#endif


