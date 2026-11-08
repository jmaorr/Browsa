// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowserKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "Suggest", targets: ["Suggest"]),
        .library(name: "BrowserEngine", targets: ["BrowserEngine"]),
        .library(name: "WebKitEngine", targets: ["WebKitEngine"]),
        .library(name: "Extensibility", targets: ["Extensibility"]),
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

        // The engine-neutral page API the Mac app is written against. No WebKit here, so a
        // Chromium (CEF) engine can sit beside WebKit later. See docs/engines.md.
        .target(name: "BrowserEngine"),

        // WKWebView behind BrowserEngine. macOS for now; iOS still uses BrowserCore's TabSession.
        .target(
            name: "WebKitEngine",
            dependencies: ["BrowserEngine", "BrowserCore"],
            resources: [.copy("Resources/extension-compat.js"), .copy("Resources/extension-diagnostics.js")]
        ),

        // Extensions, plugins, Margin notes and the agent (MCP) toolbox. Foundation only, no
        // engine, so it's testable on its own. See docs/extensibility.md.
        .target(name: "Extensibility"),
        .testTarget(name: "ExtensibilityTests", dependencies: ["Extensibility"]),
    ]
)
