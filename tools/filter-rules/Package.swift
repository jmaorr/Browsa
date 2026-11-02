// swift-tools-version: 6.0
import PackageDescription

// GPL-3.0, unlike the rest of the repo, because it links AdGuard's SafariConverterLib. It's kept
// out of the app on purpose: the app only downloads the rules this produces.
let package = Package(
    name: "filter-rules",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", from: "4.3.1"),
    ],
    targets: [
        .executableTarget(
            name: "build-rules",
            dependencies: [.product(name: "ContentBlockerConverter", package: "SafariConverterLib")]
        ),
    ]
)
