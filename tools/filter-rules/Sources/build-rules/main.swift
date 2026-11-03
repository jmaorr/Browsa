import ContentBlockerConverter
import Foundation

// Downloads AdGuard's filter lists and converts them into WebKit content-blocking JSON, one file
// per group, plus a manifest the app checks for updates. Usage: build-rules <output directory>

/// AdGuard filter IDs (filters.adtidy.org), in iOS-optimised form. The group names are the raw
/// values of `FilterGroup` in the app.
let groups: [(name: String, filterIDs: [Int])] = [
    ("ads", [2, 11]),
    ("privacy", [3, 4]),
    ("annoyances", [18, 19, 20, 21, 22]),
]

struct Manifest: Encodable {
    struct Group: Encodable {
        let file: String
        let rules: Int
    }
    let version: String
    let groups: [String: Group]
}

guard CommandLine.arguments.count == 2 else {
    print("Usage: build-rules <output directory>")
    exit(2)
}
let output = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
let sources = output.appending(path: "sources", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

var manifestGroups: [String: Manifest.Group] = [:]
for group in groups {
    var text = ""
    for id in group.filterIDs {
        let url = URL(string: "https://filters.adtidy.org/ios/filters/\(id)_optimized.txt")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            // Publishing a partial group would quietly drop blocking for everyone, so stop instead.
            print("Couldn't download filter \(id)")
            exit(1)
        }
        // The rules are derived from these GPL lists, so they're published alongside them.
        try data.write(to: sources.appending(path: "\(id).txt"))
        text += String(decoding: data, as: UTF8.self) + "\n"
    }
    let rules = text.split(whereSeparator: \.isNewline).map(String.init)
    let result = ContentBlockerConverter().convertArray(rules: rules, safariVersion: .safari26)
    guard result.safariRulesCount > 0 else {
        print("No rules converted for \(group.name)")
        exit(1)
    }
    let file = "\(group.name).json"
    try result.safariRulesJSON.write(to: output.appending(path: file), atomically: true, encoding: .utf8)
    manifestGroups[group.name] = .init(file: file, rules: result.safariRulesCount)
    print("\(group.name): \(result.safariRulesCount) rules from \(rules.count) lines")
}

let version = ISO8601DateFormatter().string(from: .now)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(Manifest(version: version, groups: manifestGroups))
    .write(to: output.appending(path: "manifest.json"))
