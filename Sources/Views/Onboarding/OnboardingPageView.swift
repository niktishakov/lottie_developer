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
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Тёмный градиентный фон
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.08, blue: 0.18),
                        Color(red: 0.02, green: 0.12, blue: 0.22)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                // Glow-акцент сзади canvas
                Circle()
                    .fill(Color.cyan.opacity(0.12))
                    .frame(width: 320, height: 320)
                    .blur(radius: 60)
                    .offset(y: -geo.size.height * 0.1)

                VStack(spacing: 0) {
                    // Заголовок
                    VStack(spacing: 6) {
                        Text(page.title)
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text(page.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 28)
                    .padding(.horizontal, 24)

                    // Canvas с анимацией
                    ZStack {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
                            )

                        // Шахматный фон — признак прозрачности
                        CheckerboardBackground()
                            .opacity(0.05)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

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

                        // Progress бар снизу canvas
                        VStack {
                            Spacer()
                            GeometryReader { bar in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.12))
                                        .frame(height: 3)
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [.cyan, .blue],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: bar.size.width * playback.currentProgress, height: 3)
                                }
                            }
                            .frame(height: 3)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                        }
                    }
                    .frame(height: min(geo.size.height * 0.38, 280))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    // Контролы плеера
                    VStack(spacing: 14) {
                        // Строка: прогресс% + play/pause + скорости
                        HStack(spacing: 12) {
                            // Прогресс %
                            Text("\(Int(playback.currentProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 36, alignment: .leading)

                            // Play/Pause
                            Button {
                                playback.isPlaying.toggle()
                                registerDemoInteraction()
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [.cyan, .blue],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 52, height: 52)
                                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            // Скорости
                            HStack(spacing: 6) {
                                ForEach(demoSpeeds, id: \.self) { speed in
                                    Button {
                                        withAnimation(reduceMotion ? .none : .snappy) {
                                            playback.speed = speed
                                        }
                                        registerDemoInteraction()
                                    } label: {
                                        let label = speed == floor(speed)
                                            ? "\(Int(speed))x"
                                            : String(format: "%.1fx", speed).replacingOccurrences(of: ",", with: ".")
                                        Text(label)
                                            .font(.caption.weight(.semibold))
                                            .monospacedDigit()
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(
                                                playback.speed == speed
                                                    ? Color.cyan
                                                    : Color.white.opacity(0.1),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(playback.speed == speed ? .white : .white.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Скрабber
                        Slider(value: $playback.currentProgress, in: 0...1) { editing in
                            if editing {
                                playback.isPlaying = false
                            } else {
                                registerDemoInteraction()
                            }
                        }
                        .tint(.cyan)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)

                    Spacer(minLength: 20)

                    // CTA
                    VStack(spacing: 12) {
                        Button {
                            if purchaseStore.isPro {
                                onComplete()
                            } else {
                                showPaywall = true
                            }
                        } label: {
                            Text(
                                purchaseStore.isPro
                                    ? L10n.string("onboarding.demo.cta.continue")
                                    : L10n.string("onboarding.demo.cta.unlock")
                            )
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

                        Button(L10n.string("onboarding.demo.cta.free")) {
                            onComplete()
                        }
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.35))
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 44)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
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
