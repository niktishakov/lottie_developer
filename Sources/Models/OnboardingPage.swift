import Foundation

struct OnboardingFeature: Identifiable {
    let id: String
    let icon: String
    let key: String

    init(icon: String, key: String) {
        self.id = key
        self.icon = icon
        self.key = key
    }

    var title: String { L10n.string(key) }
}

enum OnboardingPage: Int, CaseIterable {
    case importStaticSvg
    case aiInteractionConcept
    case rocketComesAlive
    case previewAndTune
    case versionedResult

    var titleKey: String {
        switch self {
        case .importStaticSvg: "onboarding.page1.title"
        case .aiInteractionConcept: "onboarding.page2.title"
        case .rocketComesAlive: "onboarding.page3.title"
        case .previewAndTune: "onboarding.page4.title"
        case .versionedResult: "onboarding.page5.title"
        }
    }

    var subtitleKey: String {
        switch self {
        case .importStaticSvg: "onboarding.page1.subtitle"
        case .aiInteractionConcept: "onboarding.page2.subtitle"
        case .rocketComesAlive: "onboarding.page3.subtitle"
        case .previewAndTune: "onboarding.page4.subtitle"
        case .versionedResult: "onboarding.page5.subtitle"
        }
    }

    var badgeKey: String? {
        switch self {
        case .aiInteractionConcept:
            "onboarding.badge.concept"
        case .rocketComesAlive:
            "onboarding.badge.simulation"
        default:
            nil
        }
    }

    var featureKeys: [String] {
        switch self {
        case .importStaticSvg:
            [
                "onboarding.page1.feature1",
                "onboarding.page1.feature2",
                "onboarding.page1.feature3",
            ]
        case .aiInteractionConcept:
            [
                "onboarding.page2.feature1",
                "onboarding.page2.feature2",
                "onboarding.page2.feature3",
            ]
        case .rocketComesAlive:
            [
                "onboarding.page3.feature1",
                "onboarding.page3.feature2",
                "onboarding.page3.feature3",
            ]
        case .previewAndTune:
            [
                "onboarding.page4.feature1",
                "onboarding.page4.feature2",
                "onboarding.page4.feature3",
            ]
        case .versionedResult:
            []
        }
    }

    var usesInteractiveLottie: Bool {
        self == .previewAndTune
    }

    var requiresRevealCompletion: Bool {
        switch self {
        case .importStaticSvg, .aiInteractionConcept, .rocketComesAlive:
            true
        case .previewAndTune, .versionedResult:
            false
        }
    }

    var title: String { L10n.string(titleKey) }
    var subtitle: String { L10n.string(subtitleKey) }
    var badgeTitle: String? { badgeKey.map(L10n.string) }

    var features: [OnboardingFeature] {
        zip(featureIcons, featureKeys).map { icon, key in
            OnboardingFeature(icon: icon, key: key)
        }
    }

    private var featureIcons: [String] {
        switch self {
        case .importStaticSvg:
            ["doc.badge.plus", "square.stack.3d.up", "wand.and.stars"]
        case .aiInteractionConcept:
            ["text.bubble", "slider.horizontal.3", "checklist"]
        case .rocketComesAlive:
            ["arrow.trianglehead.2.clockwise.rotate.90", "arrow.up.right.circle", "checkmark.shield"]
        case .previewAndTune:
            ["repeat", "gauge.with.dots.needle.50percent", "paintpalette"]
        case .versionedResult:
            []
        }
    }
}
