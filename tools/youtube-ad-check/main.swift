import AppKit
import WebKit

// One case of the YouTube ad check: an offscreen WKWebView set up like Browsa's (Safari user agent,
// non-persistent store, the Ads rules plus YouTubeAdRules, YouTubeAds' two scripts), page muted.
// Built by run.sh together with the app's own YouTubeAds.swift and YouTubeAdRules.swift.
//
//   youtube-ad-check --case <name> --url <url> [--click results|related] [--repeat]
//                    [--ads <ads.json>] [--seconds 30] [--verbose]
//
// Prints per-second probes with --verbose, then one line:
//   RESULT <case> <seconds to play or -> <ad flags>

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> Bool { if let i = args.firstIndex(of: n) { args.remove(at: i); return true }; return false }
func opt(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
let caseName = opt("--case") ?? "case"
let url = URL(string: opt("--url") ?? "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
let click = opt("--click")
let seconds = Int(opt("--seconds") ?? "30")!
let adsPath = opt("--ads")
let storeDir = opt("--store") ?? NSTemporaryDirectory() + "youtube-ad-check-rules"
let repeatLoad = flag("--repeat"), verbose = flag("--verbose")

let start = Date()
func log(_ s: String) {
    guard verbose else { return }
    print(String(format: "[%@ %5.1f] ", caseName, Date().timeIntervalSince(start)) + s); fflush(stdout)
}
func fail(_ s: String) -> Never { print("RESULT \(caseName) - error:\(s.replacingOccurrences(of: " ", with: "_"))"); exit(2) }

final class Relay: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { log("console: \(m.body)") }
}

let relayJS = """
(function(){
  var post = function(kind, a){ try { window.webkit.messageHandlers.relay.postMessage(kind + ' ' + Array.prototype.map.call(a, function(x){ try { return x && x.stack ? String(x.stack).slice(0,200) : String(x).slice(0,200); } catch(e) { return '?'; } }).join(' ')); } catch(e){} };
  ['error','warn'].forEach(function(k){ var o = console[k]; console[k] = function(){ post(k, arguments); return o.apply(console, arguments); }; });
  window.addEventListener('unhandledrejection', function(e){ post('rejection', [e.reason]); });
})();
"""

// Runs before YouTubeAds' page script, so that script wraps these: sees YouTube's answers before the ads
// are taken out (window.__check.adsCut), and reads the stream server's wait off SABR answers
// (NEXT_REQUEST_POLICY backoff_time_ms, window.__check.backoff). Only watches; changes nothing.
let witnessJS = """
(function(){
  if (location.hostname.indexOf('youtube.com') < 0) return;
  var check = window.__check = { adsCut: 0, backoff: 0 };
  var keys = ['adPlacements', 'adSlots', 'playerAds'];
  function look(o) {
    try {
      var all = Array.isArray(o) ? o.slice(0, 8) : [o];
      all.forEach(function(x){
        if (!x || typeof x !== 'object') return;
        [x, x.playerResponse].forEach(function(r){
          if (r && typeof r === 'object' && keys.some(function(k){ return Object.prototype.hasOwnProperty.call(r, k); })) check.adsCut++;
        });
      });
    } catch (e) {}
    return o;
  }
  var parse = JSON.parse;
  JSON.parse = function(){ return look(parse.apply(JSON, arguments)); };
  var json = Response.prototype.json;
  Response.prototype.json = function(){ return json.apply(this, arguments).then(look); };
  // UMP: parts of (type, size, payload), each number in YouTube's own varint.
  function umpInt(b, i) {
    var x = b[i];
    if (x < 0x80) return [x, 1];
    if (x < 0xc0) return [(x & 0x3f) + b[i+1] * 64, 2];
    if (x < 0xe0) return [(x & 0x1f) + (b[i+1] + b[i+2] * 256) * 32, 3];
    if (x < 0xf0) return [(x & 0x0f) + (b[i+1] + b[i+2] * 256 + b[i+3] * 65536) * 16, 4];
    return [b[i+1] + b[i+2] * 256 + b[i+3] * 65536 + b[i+4] * 16777216, 5];
  }
  function pbInt(b, i) { var v = 0, m = 1, n = 0; while (i + n < b.length) { var c = b[i + n++]; v += (c & 0x7f) * m; m *= 128; if (c < 0x80) break; } return [v, n]; }
  function backoff(p) {
    for (var i = 0; i < p.length;) {
      var t = pbInt(p, i); i += t[1]; var field = Math.floor(t[0] / 8), wire = t[0] % 8;
      if (wire === 0) { var v = pbInt(p, i); i += v[1]; if (field === 4) return v[0]; }
      else if (wire === 2) { var l = pbInt(p, i); i += l[1] + l[0]; }
      else if (wire === 5) i += 4; else if (wire === 1) i += 8; else break;
    }
    return 0;
  }
  var fetch = window.fetch;
  window.fetch = function(input){
    var p = fetch.apply(this, arguments);
    try {
      var u = typeof input === 'string' ? input : (input && input.url) || '';
      if (/googlevideo\\.com\\/videoplayback.*[?&]sabr=1/.test(u)) {
        p.then(function(r){ r.clone().arrayBuffer().then(function(ab){
          var b = new Uint8Array(ab);
          for (var i = 0; i < b.length;) {
            var t = umpInt(b, i); i += t[1]; var s = umpInt(b, i); i += s[1];
            if (t[0] === 35) check.backoff = Math.max(check.backoff, backoff(b.subarray(i, i + s[0])));
            i += s[0];
          }
        }); }, function(){});
      }
    } catch (e) {}
    return p;
  };
})();
"""

let probeJS = """
(function(){
  var p = document.querySelector('#movie_player');
  var v = (p && p.querySelector('video')) || null;
  var pr = null; try { pr = p && p.getPlayerResponse ? p.getPlayerResponse() : null; } catch(e) {}
  var vid = null; try { vid = p && p.getVideoData ? p.getVideoData().video_id : null; } catch(e) {}
  var cls = p ? p.className : '';
  return JSON.stringify({
    path: location.pathname, vid: vid,
    ad: /\\bad-showing\\b/.test(cls) || /\\bad-interrupting\\b/.test(cls),
    buffering: /\\bbuffering-mode\\b/.test(cls),
    t: v ? v.currentTime : null, paused: v ? v.paused : null, rs: v ? v.readyState : null,
    placements: !!(pr && (pr.adPlacements || pr.adSlots || pr.playerAds)),
    adsCut: window.__check ? window.__check.adsCut : 0, backoff: window.__check ? window.__check.backoff : 0
  });
})()
"""

// The first thumbnail of a non-playlist video: search results, or the related list on a watch page.
let pickJS = """
(function(){
  var as = document.querySelectorAll('ytd-video-renderer a#thumbnail[href^="/watch"], #secondary a[href^="/watch?v="]');
  var here = new URLSearchParams(location.search).get('v');
  for (var i = 0; i < as.length; i++) {
    var a = as[i], h = a.getAttribute('href') || '', r = a.getBoundingClientRect();
    if (r.width < 80 || r.height < 40 || /[?&]list=/.test(h) || (here && h.indexOf(here) >= 0)) continue;
    if (r.top < 60 || r.bottom > innerHeight) { a.scrollIntoView({block: 'center'}); r = a.getBoundingClientRect(); }
    return JSON.stringify({x: r.left + r.width / 2, y: r.top + r.height / 2, href: h});
  }
  // Only playlists so far, or the list isn't drawn yet: scroll so YouTube loads more.
  window.scrollBy(0, 500);
  return null;
})()
"""

/// The newest ads.json of an installed Browsa, else the bundled starter list.
func defaultAds() -> String? {
    let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser.path
    var found: [(String, Date)] = []
    for base in ["\(home)/Library/Application Support", "\(home)/Library/Containers"] {
        for dir in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where dir.hasPrefix("com.orriginal.browsa") {
            for path in ["\(base)/\(dir)/Filters/ads.json", "\(base)/\(dir)/Data/Library/Application Support/\(dir)/Filters/ads.json"] {
                if let d = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date { found.append((path, d)) }
            }
        }
    }
    return found.max { $0.1 < $1.1 }?.0
}

@MainActor func compileRules() async -> WKContentRuleList {
    let path = adsPath ?? defaultAds() ?? ProcessInfo.processInfo.environment["STARTER_LIST"] ?? ""
    guard let json = try? String(contentsOfFile: path, encoding: .utf8) else { fail("no ads list at \(path)") }
    let modified = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let source = YouTubeAdRules.appending(to: json)
    let id = "ads.\(Int(modified)).\(source.utf8.count).yt\(YouTubeAdRules.version)"
    try? FileManager.default.createDirectory(atPath: storeDir, withIntermediateDirectories: true)
    let store = WKContentRuleListStore(url: URL(fileURLWithPath: storeDir, isDirectory: true))!
    if let list = try? await store.contentRuleList(forIdentifier: id) { return list }
    do { return try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: source)! }
    catch { fail("rules didn't compile: \(error)") }
}

@MainActor func run() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let c = WKWebViewConfiguration()
    c.websiteDataStore = .nonPersistent()          // no cookies, no account, nothing kept
    c.upgradeKnownHostsToHTTPS = true
    c.mediaTypesRequiringUserActionForPlayback = []   // autoplay, so "seconds to play" is measurable; page is muted
    c.defaultWebpagePreferences.preferredContentMode = .desktop
    let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "27.2"
    c.applicationNameForUserAgent = "Version/\(safari) Safari/605.1.15"
    let ucc = c.userContentController
    ucc.add(Relay(), contentWorld: .page, name: "relay")
    ucc.addUserScript(WKUserScript(source: relayJS, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    ucc.add(await compileRules())
    ucc.addUserScript(WKUserScript(source: witnessJS, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    for script in YouTubeAds.scripts(skipping: []) { ucc.addUserScript(script) }

    let size = NSSize(width: 1280, height: 800)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: c)
    window.contentView = web
    window.orderFrontRegardless()
    // Mute the page in the engine (invisible to the page). Never run with sound.
    let mute = NSSelectorFromString("_setPageMuted:")
    guard web.responds(to: mute) else { fail("can't mute the page") }
    typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
    unsafeBitCast(web.method(for: mute), to: SetMuted.self)(web, mute, 1)

    func probe() async -> [String: Any] {
        guard let s = (try? await web.evaluateJavaScript(probeJS)) as? String,
              let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return [:] }
        log(s)
        return o
    }

    /// Seconds until the main video plays with no ad showing, and the ad flags seen meanwhile.
    func watch(expect: String? = nil) async -> (Double?, Set<String>) {
        let from = Date()
        var flags = Set<String>(), played: Double? = nil
        while Date().timeIntervalSince(from) < Double(seconds) {
            try? await Task.sleep(for: .milliseconds(500))
            let o = await probe()
            if o["ad"] as? Bool == true { flags.insert("ad-showing") }
            if o["placements"] as? Bool == true { flags.insert("ad-data-left") }
            if let n = o["adsCut"] as? Int, n > 0 { flags.insert("ads-cut") }
            if let ms = o["backoff"] as? Int, ms > 0 { flags.insert("server-wait-\(ms / 1000)s") }
            if expect == nil || o["vid"] as? String == expect, let t = o["t"] as? Double, t > 0.2, o["paused"] as? Bool == false, o["ad"] as? Bool != true {
                played = Date().timeIntervalSince(from); break
            }
        }
        return (played, flags)
    }

    func waitForPick() async -> (Double, Double, String)? {
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            let found: Any?
            do { found = try await web.evaluateJavaScript(pickJS) } catch { log("pick: \(error)"); found = nil }
            if let s = found as? String,
               let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
               let x = o["x"] as? Double, let y = o["y"] as? Double {
                try? await Task.sleep(for: .milliseconds(600))   // let the scroll settle, then measure again
                if let s2 = (try? await web.evaluateJavaScript(pickJS)) as? String,
                   let o2 = try? JSONSerialization.jsonObject(with: Data(s2.utf8)) as? [String: Any],
                   let x2 = o2["x"] as? Double, let y2 = o2["y"] as? Double { return (x2, y2, o2["href"] as? String ?? "") }
                return (x, y, o["href"] as? String ?? "")
            }
        }
        return nil
    }

    /// A real click (a user gesture, as when a person clicks), so YouTube navigates in-page.
    func clickAt(_ x: Double, _ y: Double) async {
        let point = NSPoint(x: x, y: Double(size.height) - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(e)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    web.load(URLRequest(url: url))
    var result: (Double?, Set<String>)
    if let click {
        if click == "related" {
            // Let the first video start (or not), then click a related one.
            _ = await watch()
        }
        // The page can still be moving when the first thumbnail turns up: click again until it navigates.
        let before = web.url?.absoluteString
        var href = ""
        for _ in 0..<3 {
            guard let (x, y, h) = await waitForPick() else { fail("no video to click") }
            href = h
            log("clicking \(href)")
            _ = try? await web.evaluateJavaScript("window.__check && (window.__check.adsCut = 0, window.__check.backoff = 0); 0")
            await clickAt(x, y)
            for _ in 0..<15 where web.url?.absoluteString == before { try? await Task.sleep(for: .milliseconds(200)) }
            if web.url?.absoluteString != before { break }
        }
        guard web.url?.absoluteString != before else { fail("click didn't navigate") }
        let id = URLComponents(string: "https://www.youtube.com" + href)?.queryItems?.first { $0.name == "v" }?.value
        result = await watch(expect: id)
    } else {
        result = await watch()
        if repeatLoad {
            log("loading again in the same web view")
            web.load(URLRequest(url: url))
            result = await watch()
        }
    }
    let secs = result.0.map { String(format: "%.1f", $0) } ?? "-"
    let flags = result.1.isEmpty ? "none" : result.1.sorted().joined(separator: ",")
    print("RESULT \(caseName) \(secs) \(flags)")
    exit(0)
}

Task { @MainActor in await run() }
NSApplication.shared.run()
