import SwiftUI

struct AnimationPlayerView: View {
    let item: AnimationItem
    @Environment(AnimationStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var playback = PlaybackState()
    @State private var showRenameAlert = false
    @State private var newName = ""
    @State private var showInfo = false

    var body: some View {
        adaptiveLayout
            .background(PlayerBackdrop().ignoresSafeArea())
            .navigationTitle(item.name)
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            newName = item.name
                            showRenameAlert = true
                        } label: {
                            Label(L10n.string("player.menu.rename"), systemImage: "pencil")
                        }

                        Button {
                            store.toggleFavorite(item)
                        } label: {
                            Label(
                                item.isFavorite
                                    ? L10n.string("player.menu.removeFavorite")
                                    : L10n.string("player.menu.addFavorite"),
                                systemImage: item.isFavorite ? "star.slash" : "star.fill"
                            )
                        }

                        Button {
                            showInfo.toggle()
                        } label: {
                            Label(L10n.string("player.menu.fileInfo"), systemImage: "info.circle")
                        }
                        .keyboardShortcut("i", modifiers: .command)

                        ShareLink(item: store.fileURL(for: item))
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert(L10n.string("player.rename.title"), isPresented: $showRenameAlert) {
                TextField(L10n.string("player.rename.placeholder"), text: $newName)
                Button(L10n.string("player.rename.save")) {
                    store.rename(item, to: newName)
                }
                Button(L10n.string("common.cancel"), role: .cancel) {}
            }
            .sheet(isPresented: $showInfo) {
                FileInfoSheet(item: item)
            }
            .onKeyPress(.space) {
                playback.isPlaying.toggle()
                return .handled
            }
            .onChange(of: playback.fromProgress) { _, newValue in
                if playback.currentProgress < newValue {
                    playback.currentProgress = newValue
                }
            }
            .onChange(of: playback.toProgress) { _, newValue in
                if playback.currentProgress > newValue {
                    playback.currentProgress = newValue
                }
            }
    }

    // MARK: - Adaptive Layout

    @ViewBuilder
    private var adaptiveLayout: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                animationCanvas
                Divider()
                controlsPanel
                    .frame(width: 300)
            }
        } else {
            VStack(spacing: 0) {
                animationCanvas
                Divider()
                controlsPanel
            }
        }
    }

    // MARK: - Canvas

    private var animationCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )

            CheckerboardBackground()
                .opacity(0.06)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))

            LottieView(
                fileURL: store.fileURL(for: item),
                playback: playback
            )
            .padding(20)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Controls

    private var controlsPanel: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                controlsCard { progressSection }
                controlsCard { playbackButtons }
                controlsCard { rangeSection }
                controlsCard { speedSection }
            }
            .padding(.vertical, 4)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.08), Color.black.opacity(0.03)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private func controlsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )
            )
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("player.progress.slider"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Slider(value: $playback.currentProgress, in: 0...1) { editing in
                if editing {
                    playback.isPlaying = false
                }
            }
            .accessibilityLabel(L10n.string("player.progress.slider"))
            HStack {
                Text("\(Int(playback.currentProgress * 100))%")
                Spacer()
                Text(playback.isPlaying
                    ? L10n.string("player.progress.playing")
                    : L10n.string("player.progress.paused"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var playbackButtons: some View {
        HStack(spacing: 12) {
            transportButton(
                systemName: "backward.end.fill",
                diameter: 44,
                tint: .secondary
            ) {
                playback.currentProgress = playback.fromProgress
                playback.isPlaying = false
            }
            .accessibilityLabel(L10n.string("player.control.rewind"))

            transportButton(
                systemName: playback.isPlaying ? "pause.fill" : "play.fill",
                diameter: 58,
                tint: .cyan,
                emphasized: true
            ) {
                playback.isPlaying.toggle()
            }
            .accessibilityLabel(
                L10n.string(playback.isPlaying ? "player.control.pause" : "player.control.play")
            )

            transportButton(
                systemName: "forward.end.fill",
                diameter: 44,
                tint: .secondary
            ) {
                playback.currentProgress = playback.toProgress
                playback.isPlaying = false
            }
            .accessibilityLabel(L10n.string("player.control.fastForward"))

            transportButton(
                systemName: playback.loopEnabled ? "repeat" : "repeat.1",
                diameter: 44,
                tint: playback.loopEnabled ? .orange : .secondary
            ) {
                playback.loopEnabled.toggle()
            }
            .accessibilityLabel(
                L10n.string(
                    playback.loopEnabled
                        ? "player.control.loopEnabled"
                        : "player.control.loopDisabled"
                )
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(
        systemName: String,
        diameter: CGFloat,
        tint: Color,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: emphasized ? 22 : 18, weight: .semibold))
                .foregroundStyle(emphasized ? Color.white : tint)
                .frame(width: diameter, height: diameter)
                .background(
                    Group {
                        if emphasized {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.cyan, Color.blue],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        } else {
                            Circle()
                                .fill(.thinMaterial)
                                .overlay(
                                    Circle()
                                        .stroke(tint.opacity(0.35), lineWidth: 1)
                                )
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("player.range.title"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack {
                Text("\(Int(playback.fromProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36)

                RangeSlider(
                    low: $playback.fromProgress,
                    high: $playback.toProgress,
                    range: 0...1
                )
                .accessibilityLabel(L10n.string("player.range.title"))

                Text("\(Int(playback.toProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36)
            }
        }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let speedText = playback.speed.formatted(.number.precision(.fractionLength(0...2)))
            Text(L10n.format("player.speed.title", speedText))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(PlaybackState.speeds, id: \.self) { speed in
                    Button {
                        withAnimation(.snappy) {
                            playback.speed = speed
                        }
                    } label: {
                        Text("\(speed, specifier: speed == floor(speed) ? "%.0f" : "%.2f")x")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                playback.speed == speed
                                    ? Color.cyan
                                    : Color.secondary.opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(playback.speed == speed ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        L10n.format(
                            "player.control.speed",
                            speed.formatted(.number.precision(.fractionLength(0...2)))
                        )
                    )
                }
            }
    }
    }

}

// MARK: - File Info Sheet

private struct PlayerBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.12, blue: 0.22).opacity(0.24),
                Color(red: 0.03, green: 0.18, blue: 0.24).opacity(0.1),
                Color.clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(.cyan.opacity(0.1))
                .frame(width: 280, height: 280)
                .blur(radius: 34)
                .offset(x: -60, y: 80)
        }
    }
}

struct FileInfoSheet: View {
    let item: AnimationItem
    @Environment(AnimationStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.string("fileInfo.section.general")) {
                    LabeledContent(L10n.string("fileInfo.name"), value: item.name)
                    LabeledContent(L10n.string("fileInfo.added"), value: item.dateAdded, format: .dateTime)
                    LabeledContent(L10n.string("fileInfo.favorite"), value: item.isFavorite
                        ? L10n.string("fileInfo.favorite.yes")
                        : L10n.string("fileInfo.favorite.no"))
                }

                Section(L10n.string("fileInfo.section.file")) {
                    LabeledContent(L10n.string("fileInfo.fileName"), value: item.fileName)
                    if let attrs = try? FileManager.default.attributesOfItem(
                        atPath: store.fileURL(for: item).path
                    ),
                       let size = attrs[.size] as? Int {
                        LabeledContent(L10n.string("fileInfo.size"), value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                }
            }
            .navigationTitle(L10n.string("fileInfo.title"))
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("fileInfo.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
