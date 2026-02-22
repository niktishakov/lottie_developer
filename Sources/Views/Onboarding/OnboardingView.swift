import SwiftUI

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var currentPage = 0
    @State private var revealCompletion: [Int: Bool] = [:]

    private var pages: [OnboardingPage] { OnboardingPage.allCases }
    private var lastPageIndex: Int { pages.count - 1 }

    private var currentOnboardingPage: OnboardingPage {
        OnboardingPage(rawValue: currentPage) ?? .importStaticSvg
    }

    private var isNextEnabled: Bool {
        guard currentPage < lastPageIndex else { return false }
        if !currentOnboardingPage.requiresRevealCompletion { return true }
        return revealCompletion[currentOnboardingPage.rawValue] == true
    }

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $currentPage) {
                ForEach(pages, id: \.rawValue) { page in
                    OnboardingPageView(
                        page: page,
                        isActive: currentPage == page.rawValue,
                        onComplete: complete,
                        onRevealCompletionChanged: { isComplete in
                            revealCompletion[page.rawValue] = isComplete
                        }
                    )
                    .tag(page.rawValue)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: currentPage < lastPageIndex ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .scrollContentBackground(.hidden)


            if currentPage < lastPageIndex {
                HStack {
                    Text(
                        L10n.format(
                            "onboarding.step",
                            currentPage + 1,
                            pages.count
                        )
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())

                    Spacer()

                    Button {
                        withAnimation {
                            currentPage = lastPageIndex
                        }
                    } label: {
                        Text(L10n.string("onboarding.skip"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 12)
                .safeAreaPadding(.top)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if currentPage < lastPageIndex {
                Button {
                    guard isNextEnabled else { return }
                    withAnimation {
                        currentPage += 1
                    }
                } label: {
                    Text(L10n.string("onboarding.next"))
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
                .disabled(!isNextEnabled)
                .opacity(isNextEnabled ? 1.0 : 0.55)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
        .onAppear(perform: primeRevealState)
        .onChange(of: currentPage) { _, newValue in
            guard let page = OnboardingPage(rawValue: newValue) else { return }
            if !page.requiresRevealCompletion {
                revealCompletion[newValue] = true
            }
        }
        .background {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.12, blue: 0.22),
                    Color(red: 0.02, green: 0.08, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color.cyan.opacity(0.12))
                    .frame(width: 260, height: 260)
                    .blur(radius: 60)
                    .offset(x: -40, y: -100)
            }
            .ignoresSafeArea()
        }
    }

    private func complete() {
        withAnimation {
            hasCompletedOnboarding = true
        }
    }

    private func primeRevealState() {
        for page in pages where !page.requiresRevealCompletion {
            revealCompletion[page.rawValue] = true
        }
    }
}
