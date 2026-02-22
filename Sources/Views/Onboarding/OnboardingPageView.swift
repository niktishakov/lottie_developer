import SwiftUI

private struct OnboardingColorOption: Identifiable {
    let id: String
    let color: Color
}

private struct OnboardingVersionItem: Identifiable {
    let id: Int
    let titleKey: String
    let badgeKey: String?
}

struct OnboardingPageView: View {
    let page: OnboardingPage
    let isActive: Bool
    let onComplete: () -> Void
    let onRevealCompletionChanged: (Bool) -> Void

    @Environment(PurchaseStore.self) private var purchaseStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showPaywall = false
    @State private var revealStage = 0
    @State private var revealTask: Task<Void, Never>?
    @State private var staticPlayback = PlaybackState()
    @State private var alivePlayback = PlaybackState()
    @State private var tunePlayback = PlaybackState()

    private let previewSpeedPresets: [Double] = [0.5, 1.0, 1.5, 2.0]

    private let colorOptions: [OnboardingColorOption] = [
        OnboardingColorOption(id: "ice", color: Color(red: 0.95, green: 0.95, blue: 0.95)),
        OnboardingColorOption(id: "sky", color: Color(red: 0.53, green: 0.73, blue: 0.98)),
        OnboardingColorOption(id: "mint", color: Color(red: 0.42, green: 0.88, blue: 0.74)),
        OnboardingColorOption(id: "amber", color: Color(red: 0.95, green: 0.66, blue: 0.26)),
        OnboardingColorOption(id: "rose", color: Color(red: 0.95, green: 0.46, blue: 0.55)),
        OnboardingColorOption(id: "violet", color: Color(red: 0.64, green: 0.57, blue: 0.96)),
    ]

    private let hullLayers = ["Body", "Body 2", "Body 3", "Body 4", "Body 5"]
    private let wingLayers = ["1 wing", "2 wing"]
    private let exhaustLayers = [
        "Soplo L",
        "Soplo R",
        "Soplo Line 1",
        "Soplo Line 2",
        "Soplo Line 3",
        "Soplo Line 4",
        "Soplo Line 5",
        "Soplo Line 6",
        "Soplo Line 7",
        "Soplo Line 8",
        "Soplo Line 9",
        "Soplo Line 10",
        "Soplo Line 11",
        "Soplo Line 12",
        "Soplo Line 13",
    ]

    private let versionItems: [OnboardingVersionItem] = [
        OnboardingVersionItem(id: 1, titleKey: "onboarding.version.v1", badgeKey: nil),
        OnboardingVersionItem(id: 2, titleKey: "onboarding.version.v2", badgeKey: "onboarding.badge.concept"),
        OnboardingVersionItem(id: 3, titleKey: "onboarding.version.v3", badgeKey: "onboarding.badge.simulation"),
        OnboardingVersionItem(id: 4, titleKey: "onboarding.version.v4", badgeKey: nil),
        OnboardingVersionItem(id: 5, titleKey: "onboarding.version.v5", badgeKey: nil),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                headerSection
                visualSection

                if !page.features.isEmpty {
                    featuresSection
                }

                if page == .versionedResult {
                    finalCTASection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, page == .versionedResult ? 24 : (page.usesInteractiveLottie ? 104 : 96))
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .safeAreaPadding(.top)
        .sheet(isPresented: $showPaywall, onDismiss: {
            onComplete()
        }) {
            PaywallView(onDismissToLibrary: onComplete)
                .environment(purchaseStore)
        }
        .onAppear {
            if isActive {
                activatePage()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                activatePage()
            } else {
                revealTask?.cancel()
            }
        }
        .onDisappear {
            revealTask?.cancel()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            if let badgeText = headerBadgeText {
                badgePill(badgeText)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            Text(page.title)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(page.subtitle)
                .font(.body)
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var visualSection: some View {
        switch page {
        case .importStaticSvg:
            importSourceVisual
        case .aiInteractionConcept:
            aiDirectionVisual
        case .rocketComesAlive:
            conversionVisual
        case .previewAndTune:
            previewAndTuneVisual
        case .versionedResult:
            versionedResultVisual
        }
    }

    private var featuresSection: some View {
        panel {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.features) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.cyan)
                            .frame(width: 18)

                        Text(feature.title)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.88))
                    }
                }
            }
        }
    }

    private var importSourceVisual: some View {
        panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L10n.string("onboarding.import.card.title"), systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    Spacer()

                    if revealStage >= 1 {
                        Text(L10n.string("onboarding.import.fileBadge"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.cyan.opacity(0.16), in: Capsule())
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.05))

                    if revealStage >= 2 {
                        staticRocketView
                            .transition(.opacity)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .padding(20)
                    }
                }
                .frame(height: 250)

                if revealStage >= 3 {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(L10n.string("onboarding.import.parseReady"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    private var aiDirectionVisual: some View {
        VStack(spacing: 12) {
            panel {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.string("onboarding.ai.prompt.title"), systemImage: "text.bubble")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text(L10n.string("onboarding.ai.prompt.value"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))

                    if revealStage >= 1 {
                        HStack(spacing: 8) {
                            chip(L10n.string("onboarding.ai.chip.loop"))
                            chip(L10n.string("onboarding.ai.chip.timing"))
                            chip(L10n.string("onboarding.ai.chip.style"))
                        }
                        .transition(.opacity)
                    }
                }
            }

            Image(systemName: "arrow.down")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.cyan.opacity(0.8))
                .opacity(revealStage >= 2 ? 1.0 : 0.25)
                .animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: revealStage)

            if revealStage >= 2 {
                panel {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.string("onboarding.ai.draft.title"), systemImage: "sparkles.rectangle.stack")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)

                        Text(L10n.string("onboarding.ai.draft.line1"))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.84))

                        Text(L10n.string("onboarding.ai.draft.line2"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private var conversionVisual: some View {
        panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    chip(L10n.string("onboarding.convert.strip.source"))
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    chip(L10n.string("onboarding.convert.strip.output"))
                }

                if revealStage >= 1 {
                    chip(L10n.string("onboarding.convert.compiled"), tint: .mint)
                        .transition(.opacity)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.05))

                    if revealStage >= 2 {
                        animatedRocketView
                            .transition(.opacity)
                    } else {
                        staticRocketView
                            .transition(.opacity)
                    }
                }
                .frame(height: 260)

                if revealStage >= 3 {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.cyan)
                        Text(L10n.string("onboarding.convert.playbackStarted"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.86))
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    private var previewAndTuneVisual: some View {
        VStack(spacing: 14) {
            panel {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.05))

                    if let url = demoAnimationURL {
                        LottieView(
                            fileURL: url,
                            playback: tunePlayback,
                            colorOverrides: tuneColorOverrides
                        )
                        .padding(10)
                    } else {
                        unavailableState(key: "onboarding.demo.unavailable")
                    }
                }
                .frame(height: 250)
            }

            panel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Button {
                            tunePlayback.isPlaying.toggle()
                        } label: {
                            Label(
                                tunePlayback.isPlaying
                                    ? L10n.string("onboarding.control.pause")
                                    : L10n.string("onboarding.control.play"),
                                systemImage: tunePlayback.isPlaying ? "pause.fill" : "play.fill"
                            )
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.cyan, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)

                        Button {
                            tunePlayback.loopEnabled.toggle()
                        } label: {
                            Label(
                                tunePlayback.loopEnabled
                                    ? L10n.string("onboarding.control.loopOn")
                                    : L10n.string("onboarding.control.loopOff"),
                                systemImage: tunePlayback.loopEnabled ? "repeat" : "repeat.1"
                            )
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(.white.opacity(0.88))
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("onboarding.control.speed"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.74))

                        Slider(
                            value: Binding(
                                get: { tunePlayback.speed },
                                set: { tunePlayback.speed = $0 }
                            ),
                            in: 0.25...3.0,
                            step: 0.05
                        )
                        .tint(.cyan)

                        HStack(spacing: 8) {
                            ForEach(previewSpeedPresets, id: \.self) { speed in
                                Button {
                                    tunePlayback.speed = speed
                                } label: {
                                    Text(speedLabel(speed))
                                        .font(.caption2.weight(.semibold))
                                        .monospacedDigit()
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                        .background(
                                            tunePlayback.speed == speed
                                                ? Color.cyan
                                                : Color.white.opacity(0.12),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer()

                            Text(speedLabel(tunePlayback.speed))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.74))
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.string("onboarding.control.colors"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.74))

                        colorControlRow(
                            title: L10n.string("onboarding.control.color.hull"),
                            selectedColor: tunePlayback.selectedHullColor,
                            onSelect: { tunePlayback.selectedHullColor = $0 }
                        )

                        colorControlRow(
                            title: L10n.string("onboarding.control.color.wings"),
                            selectedColor: tunePlayback.selectedWingColor,
                            onSelect: { tunePlayback.selectedWingColor = $0 }
                        )

                        colorControlRow(
                            title: L10n.string("onboarding.control.color.exhaust"),
                            selectedColor: tunePlayback.selectedExhaustColor,
                            onSelect: { tunePlayback.selectedExhaustColor = $0 }
                        )
                    }
                }
            }
        }
    }

    private var versionedResultVisual: some View {
        VStack(spacing: 14) {
            panel {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("onboarding.version.timeline.title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    ForEach(versionItems) { item in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(item.id == versionItems.count ? Color.cyan : Color.white.opacity(0.35))
                                .frame(width: 8, height: 8)

                            Text(L10n.string(item.titleKey))
                                .font(.caption.weight(item.id == versionItems.count ? .semibold : .regular))
                                .foregroundStyle(.white.opacity(item.id == versionItems.count ? 0.95 : 0.74))

                            Spacer()

                            if let badgeKey = item.badgeKey {
                                badgePill(L10n.string(badgeKey), compact: true)
                            }
                        }
                    }
                }
            }

            panel {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("onboarding.version.share.title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    if let shareURL = demoAnimationURL {
                        ShareLink(
                            item: shareURL,
                            preview: SharePreview(L10n.string("onboarding.version.share.preview"))
                        ) {
                            Label(L10n.string("onboarding.version.share.action"), systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .foregroundStyle(.white)
                        }
                    } else {
                        unavailableState(key: "onboarding.demo.unavailable")
                    }
                }
            }

            panel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.string("onboarding.version.sync.title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)

                        Spacer()

                        badgePill(L10n.string("onboarding.badge.syncConcept"), compact: true)
                    }

                    Text(L10n.string("onboarding.version.sync.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
    }

    private var finalCTASection: some View {
        Button {
            if purchaseStore.isPro {
                onComplete()
            } else {
                showPaywall = true
            }
        } label: {
            Text(L10n.string(purchaseStore.isPro ? "onboarding.demo.cta.continue" : "onboarding.demo.cta.unlock"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [.cyan, .blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.top, 4)
    }

    private var staticRocketView: some View {
        Group {
            if let url = staticRocketURL {
                LottieView(fileURL: url, playback: staticPlayback)
                    .padding(10)
            } else {
                unavailableState(key: "onboarding.import.preview.unavailable")
            }
        }
    }

    private var animatedRocketView: some View {
        Group {
            if let url = demoAnimationURL {
                LottieView(fileURL: url, playback: alivePlayback)
                    .padding(10)
            } else {
                unavailableState(key: "onboarding.demo.unavailable")
            }
        }
    }

    private var tuneColorOverrides: [String: Color] {
        var overrides: [String: Color] = [:]

        for layer in hullLayers {
            overrides["\(layer).**.Color"] = tunePlayback.selectedHullColor
        }

        for layer in wingLayers {
            overrides["\(layer).**.Color"] = tunePlayback.selectedWingColor
        }

        for layer in exhaustLayers {
            overrides["\(layer).**.Color"] = tunePlayback.selectedExhaustColor
        }

        return overrides
    }

    private var headerBadgeText: String? {
        guard let badge = page.badgeTitle else { return nil }
        if page == .aiInteractionConcept {
            return revealStage >= 3 ? badge : nil
        }
        return badge
    }

    private var staticRocketURL: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "rocket_static_simplified", withExtension: "json")
        #else
        Bundle.main.url(forResource: "rocket_static_simplified", withExtension: "json")
        #endif
    }

    private var demoAnimationURL: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "demo_animation", withExtension: "json")
        #else
        Bundle.main.url(forResource: "demo_animation", withExtension: "json")
        #endif
    }

    private func activatePage() {
        revealTask?.cancel()

        switch page {
        case .importStaticSvg:
            resetStaticPlayback()
            onRevealCompletionChanged(false)
            revealStage = 0
            revealTask = Task { await runImportReveal() }

        case .aiInteractionConcept:
            onRevealCompletionChanged(false)
            revealStage = 0
            revealTask = Task { await runAIReveal() }

        case .rocketComesAlive:
            resetStaticPlayback()
            resetAlivePlayback()
            onRevealCompletionChanged(false)
            revealStage = 0
            revealTask = Task { await runAliveReveal() }

        case .previewAndTune:
            resetTunePlayback()
            revealStage = 0
            onRevealCompletionChanged(true)

        case .versionedResult:
            revealStage = 0
            onRevealCompletionChanged(true)
        }
    }

    private func runImportReveal() async {
        do {
            try await pause(milliseconds: 350)
            await setRevealStage(1)

            try await pause(milliseconds: 550)
            await setRevealStage(2)

            try await pause(milliseconds: 400)
            await setRevealStage(3)

            await MainActor.run { onRevealCompletionChanged(true) }
        } catch {
            return
        }
    }

    private func runAIReveal() async {
        do {
            try await pause(milliseconds: 500)
            await setRevealStage(1)

            try await pause(milliseconds: 600)
            await setRevealStage(2)

            try await pause(milliseconds: 500)
            await setRevealStage(3)

            await MainActor.run { onRevealCompletionChanged(true) }
        } catch {
            return
        }
    }

    private func runAliveReveal() async {
        do {
            try await pause(milliseconds: 700)
            await setRevealStage(1)

            try await pause(milliseconds: 500)
            await setRevealStage(2)

            try await pause(milliseconds: 600)
            await MainActor.run {
                alivePlayback.currentProgress = 0
                alivePlayback.isPlaying = true
            }
            await setRevealStage(3)

            await MainActor.run { onRevealCompletionChanged(true) }
        } catch {
            return
        }
    }

    private func pause(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    @MainActor
    private func setRevealStage(_ stage: Int) {
        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.25)) {
            revealStage = stage
        }
    }

    private func resetStaticPlayback() {
        staticPlayback.isPlaying = false
        staticPlayback.loopEnabled = false
        staticPlayback.speed = 1.0
        staticPlayback.fromProgress = 0
        staticPlayback.toProgress = 1
        staticPlayback.currentProgress = 0
    }

    private func resetAlivePlayback() {
        alivePlayback.isPlaying = false
        alivePlayback.loopEnabled = true
        alivePlayback.speed = 1.0
        alivePlayback.fromProgress = 0
        alivePlayback.toProgress = 1
        alivePlayback.currentProgress = 0
    }

    private func resetTunePlayback() {
        tunePlayback.isPlaying = true
        tunePlayback.loopEnabled = true
        tunePlayback.speed = 1.0
        tunePlayback.fromProgress = 0
        tunePlayback.toProgress = 1
        tunePlayback.currentProgress = 0
        tunePlayback.selectedHullColor = PlaybackState.defaultHullColor
        tunePlayback.selectedWingColor = PlaybackState.defaultWingColor
        tunePlayback.selectedExhaustColor = PlaybackState.defaultExhaustColor
    }

    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    )
            )
    }

    private func chip(_ title: String, tint: Color = .cyan) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private func badgePill(_ title: String, compact: Bool = false) -> some View {
        Text(title)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(.cyan)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .background(.cyan.opacity(0.16), in: Capsule())
    }

    @ViewBuilder
    private func unavailableState(key: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
            Text(L10n.string(key))
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == floor(speed) ? "\(Int(speed))x" : String(format: "%.1fx", speed)
    }

    private func colorControlRow(
        title: String,
        selectedColor: Color,
        onSelect: @escaping (Color) -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 62, alignment: .leading)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                ForEach(colorOptions) { option in
                    Button {
                        onSelect(option.color)
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .stroke(
                                        colorsMatch(selectedColor, option.color)
                                            ? Color.white
                                            : Color.white.opacity(0.24),
                                        lineWidth: colorsMatch(selectedColor, option.color) ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func colorsMatch(_ lhs: Color, _ rhs: Color) -> Bool {
        #if canImport(UIKit)
        let left = UIColor(lhs)
        let right = UIColor(rhs)
        var lr: CGFloat = 0
        var lg: CGFloat = 0
        var lb: CGFloat = 0
        var la: CGFloat = 0
        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0

        guard left.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
              right.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        else {
            return false
        }

        return abs(lr - rr) < 0.01
            && abs(lg - rg) < 0.01
            && abs(lb - rb) < 0.01
            && abs(la - ra) < 0.01
        #else
        return false
        #endif
    }
}
