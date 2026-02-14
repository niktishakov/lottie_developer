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
                            Label(String(localized: "player.menu.rename"), systemImage: "pencil")
                        }

                        Button {
                            store.toggleFavorite(item)
                        } label: {
                            Label(
                                item.isFavorite
                                    ? String(localized: "player.menu.removeFavorite")
                                    : String(localized: "player.menu.addFavorite"),
                                systemImage: item.isFavorite ? "star.slash" : "star.fill"
                            )
                        }

                        Button {
                            showInfo.toggle()
                        } label: {
                            Label(String(localized: "player.menu.fileInfo"), systemImage: "info.circle")
                        }
                        .keyboardShortcut("i", modifiers: .command)

                        ShareLink(item: store.fileURL(for: item))
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert(String(localized: "player.rename.title"), isPresented: $showRenameAlert) {
                TextField(String(localized: "player.rename.placeholder"), text: $newName)
                Button(String(localized: "player.rename.save")) {
                    store.rename(item, to: newName)
                }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            }
            .sheet(isPresented: $showInfo) {
                FileInfoSheet(item: item)
            }
            .onKeyPress(.space) {
                playback.isPlaying.toggle()
                return .handled
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
        LottieView(
            fileURL: store.fileURL(for: item),
            playback: playback
        )
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            CheckerboardBackground()
                .opacity(0.05)
        )
    }

    // MARK: - Controls

    private var controlsPanel: some View {
        VStack(spacing: 16) {
            progressSection
            playbackButtons
            rangeSection
            speedSection
        }
        .padding()
        .background(.regularMaterial)
    }

    private var progressSection: some View {
        VStack(spacing: 4) {
            Slider(value: $playback.currentProgress, in: 0...1) { editing in
                if editing {
                    playback.isPlaying = false
                }
            }
            .accessibilityLabel(String(localized: "player.progress.playing"))
            HStack {
                Text("\(Int(playback.currentProgress * 100))%")
                Spacer()
                Text(playback.isPlaying
                    ? String(localized: "player.progress.playing")
                    : String(localized: "player.progress.paused"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var playbackButtons: some View {
        HStack(spacing: 32) {
            Button {
                playback.currentProgress = playback.fromProgress
                playback.isPlaying = false
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
            }
            .accessibilityLabel("Rewind")

            Button {
                playback.isPlaying.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.largeTitle)
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button {
                playback.currentProgress = playback.toProgress
                playback.isPlaying = false
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
            }
            .accessibilityLabel("Fast forward")

            Button {
                playback.loopEnabled.toggle()
            } label: {
                Image(systemName: playback.loopEnabled ? "repeat" : "repeat.1")
                    .font(.title3)
                    .foregroundStyle(playback.loopEnabled ? .indigo : .secondary)
            }
            .accessibilityLabel(playback.loopEnabled ? "Loop enabled" : "Loop disabled")
        }
    }

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("player.range.title")
                .font(.caption)
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
                .accessibilityLabel(String(localized: "player.range.title"))

                Text("\(Int(playback.toProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36)
            }
        }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("player.speed.title \(playback.speed.formatted(.number.precision(.fractionLength(0...2))))")
                .font(.caption)
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
                                playback.speed == speed ? Color.indigo : Color.secondary.opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(playback.speed == speed ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Speed \(speed)x")
                }
            }
        }
    }
}

// MARK: - File Info Sheet

struct FileInfoSheet: View {
    let item: AnimationItem
    @Environment(AnimationStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "fileInfo.section.general")) {
                    LabeledContent(String(localized: "fileInfo.name"), value: item.name)
                    LabeledContent(String(localized: "fileInfo.added"), value: item.dateAdded, format: .dateTime)
                    LabeledContent(String(localized: "fileInfo.favorite"), value: item.isFavorite
                        ? String(localized: "fileInfo.favorite.yes")
                        : String(localized: "fileInfo.favorite.no"))
                }

                Section(String(localized: "fileInfo.section.file")) {
                    LabeledContent(String(localized: "fileInfo.fileName"), value: item.fileName)
                    if let attrs = try? FileManager.default.attributesOfItem(
                        atPath: store.fileURL(for: item).path
                    ),
                       let size = attrs[.size] as? Int {
                        LabeledContent(String(localized: "fileInfo.size"), value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                }
            }
            .navigationTitle(String(localized: "fileInfo.title"))
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "fileInfo.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
