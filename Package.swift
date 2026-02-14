// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LottieDeveloper",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .iOSApplication(
            name: "LottieDeveloper",
            targets: ["LottieDeveloper"],
            bundleIdentifier: "com.nikapps.lottie.developer",
            teamIdentifier: "LWV5ZRPC43",
            displayVersion: "1.0.0",
            bundleVersion: "1",
            appIcon: .asset("AppIcon"),
            accentColor: .presetColor(.indigo),
            supportedDeviceTypes: [.iPhone, .iPad],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft
            ],
            appCategory: .developerTools
        )
    ],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.6.0")
    ],
    targets: [
        .executableTarget(
            name: "LottieDeveloper",
            dependencies: [
                .product(name: "Lottie", package: "lottie-ios")
            ],
            path: "Sources",
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/ru.lproj")
            ]
        )
    ]
)
