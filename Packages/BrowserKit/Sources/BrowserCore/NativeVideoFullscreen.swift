#if os(iOS)
import WebKit

/// Sends a site's own fullscreen button to the system video player, as Safari on iPhone does.
///
/// Element fullscreen is off on iOS (see `WebViewPool`), so `requestFullscreen` doesn't exist.
/// Sites that check for it then do one of two things: call the video's
/// `webkitEnterFullscreen()` (the system player, which is what we want), or, more often with a
/// desktop site, blow their player up to fill the page with CSS, which is what Browsa showed.
/// This script answers `requestFullscreen` on any element by handing the video in it (or the
/// main video on the page) to the system player, with picture in picture, AirPlay and the system
/// scrubber, and says fullscreen is available (while the page has a video) so sites take that path. It runs in every frame,
/// because embedded players (YouTube, Vimeo) live in iframes.
@MainActor enum NativeVideoFullscreen {
    static let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    private static let source = """
    (function () {
      if (window.__browsaNativeVideo) return;
      window.__browsaNativeVideo = true;
      if (!window.HTMLVideoElement || !HTMLVideoElement.prototype.webkitEnterFullscreen) return;
      var slice = Array.prototype.slice;
      function area(v) { var r = v.getBoundingClientRect(); return r.width * r.height; }
      // The video in the element the site wanted fullscreen, or failing that the main one on the
      // page: playing first, then the biggest.
      function videoFor(el) {
        if (el instanceof HTMLVideoElement) return el;
        var list = el && el.querySelectorAll ? slice.call(el.querySelectorAll('video')) : [];
        if (!list.length) list = slice.call(document.querySelectorAll('video'));
        list = list.filter(function (v) { return area(v) > 0; });
        list.sort(function (a, b) { return (a.paused - b.paused) || (area(b) - area(a)); });
        return list[0] || null;
      }
      function enter() {
        var v = videoFor(this);
        if (v) {
          try { v.webkitEnterFullscreen(); return Promise.resolve(); } catch (e) {}
        }
        return Promise.reject(new TypeError('Fullscreen is not available for this element'));
      }
      function playing() {
        return slice.call(document.querySelectorAll('video')).filter(function (v) { return v.webkitDisplayingFullscreen; })[0] || null;
      }
      function exit() {
        var v = playing();
        if (v) v.webkitExitFullscreen();
        return Promise.resolve();
      }
      function define(proto, names, descriptor) {
        names.forEach(function (n) {
          try { Object.defineProperty(proto, n, Object.assign({ configurable: true }, descriptor)); } catch (e) {}
        });
      }
      define(Element.prototype, ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'],
             { value: enter, writable: true });
      define(Document.prototype, ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen'],
             { value: exit, writable: true });
      // Only while there's a video to hand over, so games, slides and maps still see no
      // fullscreen and keep their own fallback.
      define(Document.prototype, ['fullscreenEnabled', 'webkitFullscreenEnabled'],
             { get: function () { return !!document.querySelector('video'); } });
    })();
    """
}
#endif
