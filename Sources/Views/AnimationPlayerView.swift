import SwiftUI

struct AnimationPlayerView: View {
    let item: AnimationItem
    @Environment(AnimationStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback = PlaybackState()
    @State private var showRenameAlert = false
    @State private var newName = ""
    @State private var showInfo = false
    @State private var isExpanded = false

    var body: some View {
        adaptiveLayout
            .navigationTitle(item.name)
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
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
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .semibold))
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
            .sheet(isPresented: $isExpanded) {
                fullscreenPreviewSheet
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
                animationCanvasView
                Divider()
                controlsPanel
                    .frame(maxWidth: 340)
            }
            .background(AppBackground().ignoresSafeArea())
        } else {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    animationCanvasView
                    controlsCards
                }
                .frame(width: geo.size.width)
            }
            .background(AppBackground().ignoresSafeArea())
        }
    }

    // MARK: - Canvas
    // Высота определяется через aspectRatio — нет хардкода,
    // canvas адаптируется под любой экран автоматически.

    private var animationCanvasView: some View {
        previewCanvasCard(
            cornerRadius: 20,
            checkerboardOpacity: 0.14,
            lottiePadding: 10,
            syncProgress: !isExpanded
        )
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Expanded Canvas (fullscreen overlay)

    private var fullscreenPreviewSheet: some View {
        NavigationStack {
            VStack(spacing: 18) {
                previewCanvasCard(
                    cornerRadius: 28,
                    checkerboardOpacity: 0.18,
                    lottiePadding: 20,
                    syncProgress: true
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .shadow(color: .black.opacity(0.35), radius: 28, y: 14)

                expandedProgressPanel
                    .padding(.horizontal, 20)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle(item.name)
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isExpanded = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .accessibilityLabel(L10n.string("player.control.closeFullscreen"))
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        .interactiveDismissDisabled(false)
    }

    private var expandedProgressPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("player.progress.slider"))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)

            Slider(value: $playback.currentProgress, in: 0...1) { editing in
                if editing { playback.isPlaying = false }
            }
            .tint(.cyan)

            HStack {
                Text("\(Int(playback.currentProgress * 100))%")
                    .monospacedDigit()
                Spacer()
                Text(
                    playback.isPlaying
                        ? L10n.string("player.progress.playing")
                        : L10n.string("player.progress.paused")
                )
            }
            .font(.caption)
            .foregroundStyle(AppTheme.textMuted)
        }
        .padding(14)
        .appGlassCard(cornerRadius: 18, fillOpacity: 0.12, borderOpacity: 0.2)
    }

    private func previewCanvasCard(
        cornerRadius: CGFloat,
        checkerboardOpacity: Double,
        lottiePadding: CGFloat,
        syncProgress: Bool
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(AppTheme.border, lineWidth: 1)
                )

            CheckerboardBackground(color: .white.opacity(0.2))
                .opacity(checkerboardOpacity)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            LottieView(
                fileURL: store.fileURL(for: item),
                playback: playback,
                syncProgress: syncProgress
            )
            .padding(lottiePadding)
            .clipShape(RoundedRectangle(cornerRadius: max(cornerRadius - 4, 0), style: .continuous))
        }
    }

    // MARK: - Controls

    // Карточки без скролла — используются внутри внешнего ScrollView (compact)
    // или внутри List (regular/iPad)
    private var controlsCards: some View {
        VStack(spacing: 10) {
            controlsCard { progressSection }
            controlsCard { playbackButtons }
            controlsCard { rangeSection }
            controlsCard { speedSection }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .padding(.bottom, 20)
    }

    // Для regular layout (iPad) — List с правильными отступами
    private var controlsPanel: some View {
        List {
            controlsCard { progressSection }
            controlsCard { playbackButtons }
            controlsCard { rangeSection }
            controlsCard { speedSection }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(Color.clear)
    }

    @ViewBuilder
    private func controlsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .appGlassCard(cornerRadius: 18, fillOpacity: 0.08, borderOpacity: 0.15)
            // Убираем стандартные отступы и фон List-ячейки
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("player.progress.slider"))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)

            Slider(value: $playback.currentProgress, in: 0...1) { editing in
                if editing { playback.isPlaying = false }
            }
            .tint(.cyan)
            .animation(reduceMotion ? .none : .linear(duration: 0.05), value: playback.currentProgress)
            .accessibilityLabel(L10n.string("player.progress.slider"))

            // Используем ZStack вместо HStack+Spacer — гарантированно вписывается в ширину
            ZStack {
                Text("\(Int(playback.currentProgress * 100))%")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(playback.isPlaying
                    ? L10n.string("player.progress.playing")
                    : L10n.string("player.progress.paused"))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentTransition(.opacity)
                    .animation(
                        reduceMotion ? .none : .easeInOut(duration: 0.15),
                        value: playback.isPlaying
                    )
            }
            .font(.caption)
            .foregroundStyle(AppTheme.textMuted)
        }
    }

    private var playbackButtons: some View {
        HStack(spacing: 12) {
            // Левая группа — прижата к trailing (ближе к play)
            HStack(spacing: 12) {
                transportButton(
                    systemName: "backward.end.fill",
                    diameter: 44,
                    tint: AppTheme.textSecondary
                ) {
                    playback.currentProgress = playback.fromProgress
                    playback.isPlaying = false
                }
                .accessibilityLabel(L10n.string("player.control.rewind"))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Центр — play/pause
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

            // Правая группа — прижата к leading (ближе к play)
            HStack(spacing: 12) {
                transportButton(
                    systemName: "forward.end.fill",
                    diameter: 44,
                    tint: AppTheme.textSecondary
                ) {
                    playback.currentProgress = playback.toProgress
                    playback.isPlaying = false
                }
                .accessibilityLabel(L10n.string("player.control.fastForward"))

                transportButton(
                    systemName: playback.loopEnabled ? "repeat" : "repeat.1",
                    diameter: 44,
                    tint: playback.loopEnabled ? .orange : AppTheme.textSecondary
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                                .fill(Color.white.opacity(0.08))
                                .overlay(
                                    Circle()
                                        .stroke(tint.opacity(0.38), lineWidth: 1)
                                )
                        }
                    }
                )
        }
        .buttonStyle(PressScaleButtonStyle(reduceMotion: reduceMotion))
    }

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("player.range.title"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)

            HStack(spacing: 6) {
                Text("\(Int(playback.fromProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 40, alignment: .leading)

                RangeSlider(
                    low: $playback.fromProgress,
                    high: $playback.toProgress,
                    range: 0...1
                )
                .frame(maxWidth: .infinity)
                .accessibilityLabel(L10n.string("player.range.title"))

                Text("\(Int(playback.toProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let speedText = playback.speed.formatted(.number.precision(.fractionLength(0...2)))
            Text(L10n.format("player.speed.title", speedText))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)

            Slider(value: $playback.speed, in: 0.25...3.0, step: 0.01)
                .tint(.cyan)
                .accessibilityLabel(L10n.format("player.control.speed", speedText))

            // Пресеты
            HStack(spacing: 8) {
                ForEach(PlaybackState.speeds, id: \.self) { speed in
                    Button {
                        withAnimation(.snappy) {
                            playback.speed = speed
                        }
                    } label: {
                        Text("\(speed, specifier: speed == floor(speed) ? "%.0f" : "%.2f")x")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(
                                        playback.speed == speed
                                            ? AnyShapeStyle(AppTheme.accentGradient)
                                            : AnyShapeStyle(Color.white.opacity(0.14))
                                    )
                            )
                            .foregroundStyle(playback.speed == speed ? .white : AppTheme.textPrimary)
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

private struct PressScaleButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1.0)
            .animation(
                configuration.isPressed
                    ? .easeIn(duration: 0.1)
                    : .spring(response: 0.3, dampingFraction: 0.5),
                value: configuration.isPressed
            )
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
            .scrollContentBackground(.hidden)
            .background(AppBackground().ignoresSafeArea())
            .listRowBackground(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .navigationTitle(L10n.string("fileInfo.title"))
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("fileInfo.done")) {
                        dismiss()
                    }
                    .foregroundStyle(.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }
}
