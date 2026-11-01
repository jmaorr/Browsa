// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowserKit",
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "Suggest", targets: ["Suggest"]),
    ],
    targets: [
        // Pure Swift + Foundation. No UIKit/WebKit so it can be unit-tested anywhere.
        .target(
            name: "Suggest",
            resources: [.copy("Resources/seed-sites.json")]
        ),
        .testTarget(name: "SuggestTests", dependencies: ["Suggest"]),

        // WebKit + models. Depends on Suggest for the history/favourites stores it feeds.
        .target(name: "BrowserCore", dependencies: ["Suggest"]),
    ]
)
