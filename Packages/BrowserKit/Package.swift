// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowserKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "Suggest", targets: ["Suggest"]),
    ],
    dependencies: [
        // AdGuard's filter-list converter (GPL-3.0): AdGuard/EasyList syntax to WebKit
        // content-blocking JSON. Used at runtime, when filter lists are downloaded.
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", from: "4.3.1"),
    ],
    targets: [
        // Pure Swift + Foundation. No UIKit/WebKit so it can be unit-tested anywhere.
        .target(
            name: "Suggest",
            resources: [.copy("Resources/seed-sites.json")]
        ),
        .testTarget(name: "SuggestTests", dependencies: ["Suggest"]),

        // WebKit + models. Depends on Suggest for the history/favourites stores it feeds.
        .target(
            name: "BrowserCore",
            dependencies: [
                "Suggest",
                .product(name: "ContentBlockerConverter", package: "SafariConverterLib"),
            ],
            resources: [
                .copy("Resources/blocklist.json"),
                .copy("Resources/autoconsent.js"),
                .copy("Resources/autoconsent-LICENSE.txt"),
                .copy("Resources/Readability.js"),
                .copy("Resources/Readability-LICENSE.txt"),
            ]
        ),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
    ]
)
