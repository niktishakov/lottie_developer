import SwiftUI

struct OnboardingFeature: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
}

enum OnboardingPage: Int, CaseIterable {
    case toolkit
    case fineTune
    case ready

    var title: String {
        switch self {
        case .toolkit: L10n.string("onboarding.page1.title")
        case .fineTune: L10n.string("onboarding.page2.title")
        case .ready: L10n.string("onboarding.page3.title")
        }
    }

    var subtitle: String {
        switch self {
        case .toolkit: L10n.string("onboarding.page1.subtitle")
        case .fineTune: L10n.string("onboarding.page2.subtitle")
        case .ready: L10n.string("onboarding.page3.subtitle")
        }
    }

    var iconName: String {
        switch self {
        case .toolkit: "play.circle.fill"
        case .fineTune: "slider.horizontal.3"
        case .ready: "checkmark.circle.fill"
        }
    }

    var usesAppLogo: Bool {
        self == .toolkit
    }

    var features: [OnboardingFeature] {
        switch self {
        case .toolkit:
            [
                OnboardingFeature(icon: "folder.badge.plus", title: L10n.string("onboarding.page1.feature1")),
                OnboardingFeature(icon: "play.circle", title: L10n.string("onboarding.page1.feature2")),
                OnboardingFeature(icon: "iphone.and.ipad", title: L10n.string("onboarding.page1.feature3")),
            ]
        case .fineTune:
            [
                OnboardingFeature(icon: "gauge.with.dots.needle.33percent", title: L10n.string("onboarding.page2.feature1")),
                OnboardingFeature(icon: "arrow.left.and.right", title: L10n.string("onboarding.page2.feature2")),
                OnboardingFeature(icon: "star", title: L10n.string("onboarding.page2.feature3")),
            ]
        case .ready:
            []
        }
    }
}
