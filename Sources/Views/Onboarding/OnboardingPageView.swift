import SwiftUI

struct OnboardingPageView: View {
    let page: OnboardingPage
    let onComplete: () -> Void

    @Environment(PurchaseStore.self) private var purchaseStore
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
            }
        }
        .padding()
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity)
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
        VStack(spacing: 0) {
            Text(page.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            Text(page.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.top, 6)

            demoPreviewCard
                .padding(.top, 16)

            // Playback controls overlay
            HStack {
                Button {
                    playback.isPlaying.toggle()
                    registerDemoInteraction()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 4) {
                    ForEach(demoSpeeds, id: \.self) { speed in
                        Button {
                            withAnimation(.snappy) {
                                playback.speed = speed
                            }
                            registerDemoInteraction()
                        } label: {
                            Text("\(speed, specifier: speed == floor(speed) ? "%.0f" : "%.1f")x")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    playback.speed == speed
                                        ? Color.cyan
                                        : Color(uiColor: .secondarySystemBackground),
                                    in: Capsule()
                                )
                                .foregroundStyle(playback.speed == speed ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 12)

            Slider(value: $playback.currentProgress, in: 0...1) { editing in
                if editing {
                    playback.isPlaying = false
                } else {
                    registerDemoInteraction()
                }
            }
            .tint(.cyan)
            .padding(.top, 8)

            Spacer(minLength: 16)

            // CTA section
            VStack(spacing: 10) {
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
                    .padding(.vertical, 15)
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
            .padding(.bottom, 40)
        }
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
        guard demoInteractions >= 2 else { return }

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
