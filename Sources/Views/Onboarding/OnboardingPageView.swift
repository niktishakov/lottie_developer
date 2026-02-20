import SwiftUI

struct OnboardingPageView: View {
    let page: OnboardingPage
    let onComplete: () -> Void

    @Environment(PurchaseStore.self) private var purchaseStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPaywall = false
    @State private var playback = PlaybackState()
    @State private var demoInteractions = 0
    @State private var hasAutoPresentedPaywall = false

    private let demoSpeeds: [Double] = [0.5, 1.0, 2.0]

    var body: some View {
        Group {
            if page == .ready {
                readyDemoContent
            } else {
                featurePageContent
                    .padding()
                    .frame(maxWidth: 500)
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environment(purchaseStore)
        }
        .onAppear {
            guard page == .ready else { return }
            resetDemoPlayback()
            resetDemoConversionState()
        }
    }

    private var featurePageContent: some View {
        VStack(spacing: 24) {
            Spacer()

            iconSection

            Text(page.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text(page.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !page.features.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page.features) { feature in
                        HStack(spacing: 14) {
                            Image(systemName: feature.icon)
                                .font(.title3)
                                .foregroundStyle(.cyan)
                                .frame(width: 32)
                            Text(feature.title)
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }

            Spacer()
            Spacer()
                .frame(height: 60)
        }
    }

    private var readyDemoContent: some View {
        ZStack {
            // Тёмный фон (аналог PlayerBackdrop)
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.12, blue: 0.22),
                    Color(red: 0.02, green: 0.08, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.cyan.opacity(0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 60)
                .offset(x: -40, y: -100)

            VStack(spacing: 0) {
                // Canvas — берём тот же паттерн что в AnimationPlayerView.animationCanvas
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        )

                    CheckerboardBackground()
                        .opacity(0.09)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))

                    if let url = demoAnimationURL {
                        LottieView(fileURL: url, playback: playback)
                            .padding(20)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                            Text(L10n.string("onboarding.demo.unavailable"))
                                .font(.footnote)
                        }
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .frame(height: 240)

                // Controls — компактная версия controlsPanel
                VStack(spacing: 12) {
                    // Progress slider
                    VStack(alignment: .leading, spacing: 6) {
                        Slider(value: $playback.currentProgress, in: 0...1) { editing in
                            if editing { playback.isPlaying = false }
                            else { registerDemoInteraction() }
                        }
                        .tint(.cyan)

                        HStack {
                            Text("\(Int(playback.currentProgress * 100))%")
                            Spacer()
                            Text(playback.isPlaying ? L10n.string("player.progress.playing") : L10n.string("player.progress.paused"))
                                .contentTransition(.opacity)
                                .animation(reduceMotion ? .none : .easeInOut(duration: 0.15), value: playback.isPlaying)
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                    }

                    // Transport buttons — те же что в AnimationPlayerView.playbackButtons
                    HStack(spacing: 12) {
                        demoTransportButton(systemName: "backward.end.fill", diameter: 40, tint: .white.opacity(0.5)) {
                            playback.currentProgress = 0
                            playback.isPlaying = false
                        }

                        demoTransportButton(systemName: playback.isPlaying ? "pause.fill" : "play.fill", diameter: 54, tint: .cyan, emphasized: true) {
                            playback.isPlaying.toggle()
                            registerDemoInteraction()
                        }

                        demoTransportButton(systemName: "forward.end.fill", diameter: 40, tint: .white.opacity(0.5)) {
                            playback.currentProgress = 1
                            playback.isPlaying = false
                        }

                        demoTransportButton(systemName: playback.loopEnabled ? "repeat" : "repeat.1", diameter: 40, tint: playback.loopEnabled ? .orange : .white.opacity(0.5)) {
                            playback.loopEnabled.toggle()
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Speed pills
                    HStack(spacing: 6) {
                        ForEach(demoSpeeds, id: \.self) { speed in
                            Button {
                                withAnimation(reduceMotion ? .none : .snappy) { playback.speed = speed }
                                registerDemoInteraction()
                            } label: {
                                let label = speed == floor(speed)
                                    ? "\(Int(speed))x"
                                    : String(format: "%.1fx", speed).replacingOccurrences(of: ",", with: ".")
                                Text(label)
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(playback.speed == speed ? Color.cyan : Color.white.opacity(0.1), in: Capsule())
                                    .foregroundStyle(playback.speed == speed ? .white : .white.opacity(0.65))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0.12), Color.black.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // CTA
                VStack(spacing: 8) {
                    Button {
                        if purchaseStore.isPro { onComplete() } else { showPaywall = true }
                    } label: {
                        Text(purchaseStore.isPro
                            ? L10n.string("onboarding.demo.cta.continue")
                            : L10n.string("onboarding.demo.cta.unlock"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing)
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Button(L10n.string("onboarding.demo.cta.free")) { onComplete() }
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.35))
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func demoTransportButton(
        systemName: String,
        diameter: CGFloat,
        tint: Color,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: emphasized ? 20 : 16, weight: .semibold))
                .foregroundStyle(emphasized ? Color.white : tint)
                .frame(width: diameter, height: diameter)
                .background(
                    Group {
                        if emphasized {
                            Circle().fill(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        } else {
                            Circle().fill(.thinMaterial).overlay(Circle().stroke(tint.opacity(0.35), lineWidth: 1))
                        }
                    }
                )
        }
        .buttonStyle(DemoPressScaleStyle(reduceMotion: reduceMotion))
    }

    @ViewBuilder
    private var demoPreviewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
                )

            if let demoAnimationURL {
                LottieView(fileURL: demoAnimationURL, playback: playback)
                    .padding(14)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text(L10n.string("onboarding.demo.unavailable"))
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: 220)
        .aspectRatio(1.2, contentMode: .fit)
    }

    private var demoAnimationURL: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "demo_animation", withExtension: "json")
        #else
        Bundle.main.url(forResource: "demo_animation", withExtension: "json")
        #endif
    }

    private func resetDemoPlayback() {
        playback.isPlaying = true
        playback.speed = 1.0
        playback.loopEnabled = true
        playback.currentProgress = 0.0
        playback.fromProgress = 0.0
        playback.toProgress = 1.0
    }

    private func resetDemoConversionState() {
        demoInteractions = 0
        hasAutoPresentedPaywall = false
    }

    private func registerDemoInteraction() {
        guard page == .ready else { return }
        guard !purchaseStore.isPro else { return }
        guard !showPaywall else { return }
        guard !hasAutoPresentedPaywall else { return }

        demoInteractions += 1
        guard demoInteractions >= 4 else { return }

        hasAutoPresentedPaywall = true
        showPaywall = true
    }

    @ViewBuilder
    private var iconSection: some View {
        if page.usesAppLogo {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            Image(systemName: page.iconName)
                .font(.system(size: 64))
                .foregroundStyle(.cyan)
        }
    }
}

private struct DemoPressScaleStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1.0)
            .animation(
                configuration.isPressed ? .easeIn(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.5),
                value: configuration.isPressed
            )
    }
}
