import SwiftUI

struct AnimationPlayerView: View {
    let item: AnimationItem
    @Environment(AnimationStore.self) private var store
    @State private var playback = PlaybackState()
    @State private var showRenameAlert = false
    @State private var newName = ""
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 0) {
            animationCanvas
            Divider()
            controlsPanel
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        newName = item.name
                        showRenameAlert = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button {
                        store.toggleFavorite(item)
                    } label: {
                        Label(
                            item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: item.isFavorite ? "star.slash" : "star.fill"
                        )
                    }

                    Button {
                        showInfo.toggle()
                    } label: {
                        Label("File Info", systemImage: "info.circle")
                    }

                    ShareLink(item: store.fileURL(for: item))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Animation", isPresented: $showRenameAlert) {
            TextField("Name", text: $newName)
            Button("Save") {
                store.rename(item, to: newName)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showInfo) {
            FileInfoSheet(item: item)
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
            HStack {
                Text("\(Int(playback.currentProgress * 100))%")
                Spacer()
                Text(playback.isPlaying ? "Playing" : "Paused")
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

            Button {
                playback.isPlaying.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.largeTitle)
            }

            Button {
                playback.currentProgress = playback.toProgress
                playback.isPlaying = false
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
            }

            Button {
                playback.loopEnabled.toggle()
            } label: {
                Image(systemName: playback.loopEnabled ? "repeat" : "repeat.1")
                    .font(.title3)
                    .foregroundStyle(playback.loopEnabled ? .indigo : .secondary)
            }
        }
    }

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Playback Range")
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

                Text("\(Int(playback.toProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36)
            }
        }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed: \(playback.speed, specifier: "%.2f")x")
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
                Section("General") {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Added", value: item.dateAdded, format: .dateTime)
                    LabeledContent("Favorite", value: item.isFavorite ? "Yes" : "No")
                }

                Section("File") {
                    LabeledContent("File Name", value: item.fileName)
                    if let attrs = try? FileManager.default.attributesOfItem(
                        atPath: store.fileURL(for: item).path
                    ),
                       let size = attrs[.size] as? Int {
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                }
            }
            .navigationTitle("File Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
