#if os(iOS)
import SwiftUI

/// Плеер проекта на настоящем lottie-ios: версии, play/pause, кадр, скорость, loop, движок, фон, комментарии.
struct ProjectPlayerView: View {
    let store: ProjectStore
    let projectID: UUID
    var command: ProjectStore.UICommand?

    /// nil — статичная геометрия.
    @State private var selectedVersionID: UUID?
    @State private var didPickInitial = false
    @State private var player = DevPlayerController()
    @State private var background: DevBackground = .checker
    @State private var newComment = ""
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                canvas
                transport
                settings
                if let v = selectedVersion, !v.prompt.isEmpty || !v.note.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if !v.prompt.isEmpty { Text(v.prompt).font(.callout) }
                        if !v.note.isEmpty { Text(v.note).font(.caption).foregroundStyle(.secondary) }
                    }
                    .devCard()
                }
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
        }
        .onChange(of: command?.issuedAt) { _, _ in applyCommand() }
        .onChange(of: versions.first?.id) { old, new in
            // Пришла новая версия от Claude — показываем её, если смотрели последнюю.
            if selectedVersionID == old, let new { selectedVersionID = new }
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
        if let f = cmd.frame { player.seek(f) }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            DevBackgroundView(kind: background)
            DevLottieCanvas(controller: player)
            if let err = player.loadError {
                Text(err).font(.callout).foregroundStyle(.red).padding()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { player.toggle() }
    }

    // MARK: - Transport

    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                Slider(value: Binding(get: { player.frame }, set: { player.seek($0.rounded()) }),
                       in: player.startFrame...max(player.endFrame, player.startFrame + 1))
                Text("\(Int(player.frame.rounded())) / \(Int(player.endFrame))")
                    .font(.caption.monospacedDigit()).frame(minWidth: 64, alignment: .trailing)
            }
            HStack {
                Toggle("Loop", isOn: $player.loop).toggleStyle(.button)
                Spacer()
                Picker("Speed", selection: $player.speed) {
                    ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { s in
                        Text(s == 1 ? "1×" : "\(s.formatted())×").tag(s)
                    }
                }
                .pickerStyle(.segmented).frame(maxWidth: 240)
            }
        }
        .devCard()
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Engine", selection: $player.engine) {
                ForEach(DevEngineChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Engine in use: \(player.activeEngine)")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Background", selection: $background) {
                ForEach(DevBackground.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
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
            Label(selectedVersion?.label ?? "Static", systemImage: "clock.arrow.circlepath")
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
            HStack {
                TextField("Comment at frame \(Int(player.frame.rounded()))", text: $newComment, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addComment() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            let items = feedback
            let _ = feedbackTick
            if items.isEmpty {
                Text("No comments yet.").font(.caption).foregroundStyle(.secondary)
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
                Text("\(item.versionLabel) · frame \(item.frame)").font(.caption.bold())
                if let layer = item.layer { Text(layer).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if item.resolved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            Text(item.text).font(.callout)
            if let reply = item.reply, !reply.isEmpty {
                Text("Claude: \(reply)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
        .opacity(item.resolved ? 0.6 : 1)
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
