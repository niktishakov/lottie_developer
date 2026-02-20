import SwiftUI

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var currentPage = 0

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $currentPage) {
                ForEach(OnboardingPage.allCases, id: \.rawValue) { page in
                    OnboardingPageView(page: page) {
                        complete()
                    }
                    .tag(page.rawValue)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: currentPage < OnboardingPage.allCases.count - 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack {
                Text(
                    L10n.format(
                        "onboarding.step",
                        currentPage + 1,
                        OnboardingPage.allCases.count
                    )
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())

                Spacer()

                if currentPage < OnboardingPage.allCases.count - 1 {
                    Button {
                        complete()
                    } label: {
                        Text(L10n.string("onboarding.skip"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 12)

            if currentPage < OnboardingPage.allCases.count - 1 {
                VStack {
                    Spacer()

                    Button {
                        withAnimation {
                            currentPage += 1
                        }
                    } label: {
                        Text(L10n.string("onboarding.next"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
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
                    .padding(.horizontal, 32)
                    .padding(.bottom, 88)
                }
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }

    private func complete() {
        withAnimation {
            hasCompletedOnboarding = true
        }
    }
}
