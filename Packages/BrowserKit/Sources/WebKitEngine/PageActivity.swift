#if os(macOS)
import WebKit

/// Tells the app when a page is playing sound or holds text someone typed, so a busy tab isn't
/// unloaded to save memory, and what its videos are doing, for picture in picture. One small script
/// per frame, in its own world, out of the page's reach. Each frame reports only when its answer changes.
///
/// The same script plays, pauses and pops out the frame's main video when the app asks
/// (`window.__browsaMedia(action)` in this world), and lifts a site's `disablePictureInPicture`.
enum PageActivity {
    @MainActor static let world = WKContentWorld.world(name: "browsa.activity")
    static let messageName = "browsaActivity"

    /// One frame's state. `frame` is a token the frame's script made up, unique per document.
    struct Report {
        let frame: String
        let audible: Bool
        let typed: Bool
        /// A video big enough to pop out.
        var video = false
        /// Something playing, sound or not.
        var playing = false
        /// Something played with sound in this document.
        var played = false
        /// The main video is playing with sound.
        var watching = false
        /// A video is in picture in picture.
        var pip = false
        /// The frame, to send media actions back to.
        var frameInfo: WKFrameInfo?
    }

    /// Runs a media action in the frame that reported it.
    @MainActor static func run(_ action: String, in frame: WKFrameInfo, of webView: WKWebView) {
        webView.evaluateJavaScript("window.__browsaMedia && window.__browsaMedia('\(action)')", in: frame, in: world) { _ in }
    }

    @MainActor static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        private let onReport: @MainActor (WKWebView, Report) -> Void

        init(onReport: @escaping @MainActor (WKWebView, Report) -> Void) {
            self.onReport = onReport
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let frame = body["frame"] as? String,
                  frame.count <= 32, let webView = message.webView else { return }
            func flag(_ key: String) -> Bool { body[key] as? Bool ?? false }
            let report = Report(frame: frame, audible: flag("audible"), typed: flag("typed"), video: flag("video"),
                                playing: flag("playing"), played: flag("played"), watching: flag("watching"),
                                pip: flag("pip"), frameInfo: message.frameInfo)
            MainActor.assumeIsolated { onReport(webView, report) }
        }
    }

    /// Sound: any audio or video element playing, not muted, with volume up. Typing: a text field,
    /// text area or editable area the person typed into (not a script) that still holds text. A
    /// submitted form's fields stop counting. Fields emptied by a script (a chat sending a message)
    /// are noticed by a slow re-check that only runs while something is typed.
    private static let source = """
    (function () {
      if (window.__browsaActivity) return;
      window.__browsaActivity = true;
      var frame = Math.random().toString(36).slice(2, 14);
      var media = new Set(), fields = new Set(), last = '', recheck = 0, played = false, lastHeard = null;

      function collect() {
        document.querySelectorAll('audio, video').forEach(function (m) { media.add(m); });
        media.forEach(function (m) { if (!m.isConnected && m.paused) media.delete(m); });
      }
      function running(m) { return !m.paused && !m.ended; }
      function heard(m) { return running(m) && !m.muted && m.volume > 0; }
      function inPiP(v) {
        return document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture';
      }
      // The video to pop out: the one in picture in picture, else a playing one with sound, else a
      // playing one, else the biggest. Tiny ones (icons, previews) don't count.
      function mainVideo() {
        var best = null, score = -1;
        media.forEach(function (m) {
          if (!(m instanceof HTMLVideoElement) || !m.isConnected) return;
          var pip = inPiP(m);
          if (!pip && (!m.videoWidth || m.readyState < 1)) return;
          var r = m.getBoundingClientRect(), area = r.width * r.height;
          if (!pip && (r.width < 160 || r.height < 90)) return;
          var s = Math.min(area, 1e7) + (heard(m) ? 1e8 : 0) + (running(m) ? 1e9 : 0) + (pip ? 1e10 : 0);
          if (s > score) { score = s; best = m; }
        });
        return best;
      }
      // What play/pause acts on: what's playing with sound, else what last did, else the main video.
      // Muted autoplay (a feed, a background) only if there's nothing else.
      function mainMedia() {
        var list = Array.from(media).filter(function (m) { return m.isConnected; });
        return list.find(heard) || (lastHeard && lastHeard.isConnected ? lastHeard : null)
          || mainVideo() || list.find(running) || null;
      }
      function text(f) { return f.isContentEditable ? f.textContent : f.value; }
      function typed() {
        fields.forEach(function (f) { var v = text(f); if (!f.isConnected || !v || !v.trim()) fields.delete(f); });
        return fields.size > 0;
      }
      function post(r) {
        r.frame = frame;
        try { webkit.messageHandlers.\(messageName).postMessage(r); } catch (e) {}
      }
      function state() {
        collect();
        var a = false, p = false, pip = false;
        media.forEach(function (m) {
          if (heard(m)) { a = true; played = true; lastHeard = m; }
          if (running(m)) p = true;
          if (m instanceof HTMLVideoElement && inPiP(m)) pip = true;
        });
        var v = mainVideo();
        return { audible: a, typed: typed(), video: !!v, playing: p, played: played && media.size > 0,
                 watching: !!v && heard(v), pip: pip };
      }
      function report() {
        var r = state();
        var now = ['audible', 'typed', 'video', 'playing', 'played', 'watching', 'pip']
          .map(function (k) { return r[k] ? '1' : '0'; }).join('');
        if (r.typed && !recheck) recheck = setInterval(report, 10000);
        if (!r.typed && recheck) { clearInterval(recheck); recheck = 0; }
        if (now === last) return;
        last = now;
        post(r);
      }
      // Feeds full of autoplay clips fire media events all the time, and each report looks up every video
      // and measures it. One report for a burst of them is enough.
      var pending = 0;
      function soon() {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; report(); }, 200);
      }
      function editable(el) {
        if (!el) return false;
        if (el.isContentEditable) return true;
        if (el instanceof HTMLTextAreaElement) return true;
        if (el instanceof HTMLInputElement)
          return !/^(search|checkbox|radio|range|color|file|submit|button|reset|image|hidden)$/i.test(el.type);
        return false;
      }

      function enterPiP(v) {
        // Sites can switch picture in picture off for their player (YouTube's Shorts, some news
        // sites). Browsa lets you have it anyway, like Arc and Safari's own button.
        if (v.hasAttribute('disablepictureinpicture')) v.removeAttribute('disablepictureinpicture');
        function legacy() {
          if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture'))
            v.webkitSetPresentationMode('picture-in-picture');
        }
        if (v.requestPictureInPicture) v.requestPictureInPicture().catch(legacy);
        else legacy();
      }
      function exitPiP() {
        if (document.pictureInPictureElement && document.exitPictureInPicture) {
          document.exitPictureInPicture().catch(function () {});
          return;
        }
        media.forEach(function (m) {
          if (m instanceof HTMLVideoElement && m.webkitPresentationMode === 'picture-in-picture') m.webkitSetPresentationMode('inline');
        });
      }
      window.__browsaMedia = function (action) {
        collect();
        var v = mainVideo();
        if (action === 'playpause') {
          var m = mainMedia();
          if (!m) return;
          if (running(m)) m.pause(); else { var p = m.play(); if (p) p.catch(function () {}); }
        } else if (action === 'enter') {
          if (v && !inPiP(v)) enterPiP(v);
        } else if (action === 'exit') {
          exitPiP();
        } else if (action === 'toggle') {
          if (v && inPiP(v)) exitPiP(); else if (v) enterPiP(v);
        }
      };

      ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'loadedmetadata', 'resize',
       'enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged'].forEach(function (type) {
        document.addEventListener(type, function (e) {
          if (e.target instanceof HTMLMediaElement) media.add(e.target);
          soon();
        }, true);
      });
      document.addEventListener('input', function (e) {
        if (!e.isTrusted) return;
        var el = e.target && e.target.isContentEditable ? e.target.closest('[contenteditable]') || e.target : e.target;
        if (!editable(el)) return;
        fields.add(el);
        report();
      }, true);
      document.addEventListener('submit', function (e) {
        fields.forEach(function (f) { if (e.target.contains(f)) fields.delete(f); });
        report();
      }, true);
      window.addEventListener('pagehide', function () {
        last = '';
        post({ audible: false, typed: false, video: false, playing: false, played: false, watching: false, pip: false });
      });
      window.addEventListener('pageshow', function (e) { if (e.persisted) { last = '-'; report(); } });
    })();
    """
}
#endif
