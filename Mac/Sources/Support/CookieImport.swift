import Foundation
import WebKit
import BrowserCore

/// Sign-ins from the sandbox days. WebKit kept the app's cookies in the container's
/// Library/Cookies/Cookies.binarycookies; outside the sandbox it keeps them somewhere apps can't
/// copy into, so `SandboxMigration` can't carry them across as a file. Instead this reads the old
/// file and hands each cookie to WebKit's store, once, then reloads any page already open.
@MainActor
enum CookieImport {
    static func runIfNeeded(reload: @escaping @MainActor () -> Void) {
        guard !AppFolders.isSandboxed, let id = Bundle.main.bundleIdentifier else { return }
        let fm = FileManager.default
        let file = fm.homeDirectoryForCurrentUser.appending(path: "Library/Containers/\(id)/Data/Library/Cookies/Cookies.binarycookies")
        let marker = AppFolders.support.appending(path: ".cookies-imported")
        guard fm.fileExists(atPath: file.path), !fm.fileExists(atPath: marker.path) else { return }
        guard let data = try? Data(contentsOf: file) else {
            NSLog("[migration] couldn't read %@", file.path)
            return
        }
        let cookies = BinaryCookies.parse(data).filter { ($0.expiresDate ?? .distantFuture) > Date() }
        Task { @MainActor in
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in cookies { await store.setCookie(cookie) }
            try? fm.createDirectory(at: AppFolders.support, withIntermediateDirectories: true)
            try? Data("imported \(cookies.count) cookies from \(file.path) at \(Date())\n".utf8).write(to: marker)
            NSLog("[migration] imported %d cookies", cookies.count)
            reload()
        }
    }
}

/// Apple's binarycookies format: "cook", a page count and sizes (big-endian), then pages of
/// cookie records (little-endian) holding offsets to the domain, name, path and value strings and
/// the expiry as seconds since 2001.
enum BinaryCookies {
    static func parse(_ data: Data) -> [HTTPCookie] {
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes[0..<4] == [0x63, 0x6F, 0x6F, 0x6B] else { return [] }
        func be32(_ at: Int) -> Int { at + 4 <= bytes.count ? Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) : 0 }
        func le32(_ at: Int) -> Int { at + 4 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 : 0 }
        func double(_ at: Int) -> Double {
            guard at + 8 <= bytes.count else { return 0 }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[at + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: v)
        }
        func string(_ at: Int) -> String? {
            guard at > 0, at < bytes.count, let end = bytes[at...].firstIndex(of: 0) else { return nil }
            return String(decoding: bytes[at..<end], as: UTF8.self)
        }

        let pageCount = be32(4)
        guard pageCount > 0, pageCount < 100_000 else { return [] }
        var pageStart = 8 + 4 * pageCount
        var out: [HTTPCookie] = []
        for p in 0..<pageCount {
            let size = be32(8 + 4 * p)
            defer { pageStart += size }
            guard size > 8, pageStart + size <= bytes.count else { continue }
            let count = le32(pageStart + 4)
            for c in 0..<min(count, 10_000) {
                let r = pageStart + le32(pageStart + 8 + 4 * c)
                let flags = le32(r + 8)
                guard let domain = string(r + le32(r + 16)), let name = string(r + le32(r + 20)),
                      let path = string(r + le32(r + 24)), let value = string(r + le32(r + 28)) else { continue }
                var props: [HTTPCookiePropertyKey: Any] = [.domain: domain, .name: name, .path: path, .value: value]
                let expires = double(r + 40)
                if expires > 0 { props[.expires] = Date(timeIntervalSinceReferenceDate: expires) }
                if flags & 1 != 0 { props[.secure] = "TRUE" }
                if flags & 4 != 0 { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if let cookie = HTTPCookie(properties: props) { out.append(cookie) }
            }
        }
        return out
    }
}
