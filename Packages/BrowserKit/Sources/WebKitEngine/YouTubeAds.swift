#if canImport(WebKit)
import Foundation
import WebKit

// YouTube ads, part of the ad blocker.
//
// Adapted from Search (github.com/driceroland/Search, Sources/Search/YouTubeAds.swift):
// Copyright (c) 2026 Office Commun. MIT License:
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
//   associated documentation files (the "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//   copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the
//   following conditions: The above copyright notice and this permission notice shall be included in all
//   copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
//   LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
//   EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
//   IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
//   THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// Why: the filter rules stop YouTube's ad requests, but YouTube announces its ads in the player's own data
// and plays them from the same servers as the video, so the player still waits out the ad's length on a
// blank screen. Two scripts fix that, only on YouTube's own hosts:
//
// - In the page's world, before YouTube's scripts run: takes the ad schedule (adPlacements, adSlots,
//   playerAds, adBreakHeartbeatParams) out of ytInitialPlayerResponse and every /youtubei/v1/player answer,
//   so the player never schedules an ad. Answers of any other shape pass through untouched, so a change at
//   YouTube leaves videos playing, with ads, rather than broken. It also answers YouTube's ad-blocker probes
//   (ad id, ad reports, which the filter rules block anyway) with an empty 200 so nothing fails, keeps the
//   "ad blockers violate" wall from replacing a playable answer, and restarts a watch-page video once if
//   YouTube holds it at 0:00 for the pre-roll that was taken out. The restart runs on the first page and
//   on every in-page navigation (yt-navigate-finish): the player streams over SABR, whose first answer
//   carries a server backoff the length of the cut ad, and asking the player for the video again starts a
//   stream without it. Playlists are left alone, since the player would drop the playlist.
// - In Browsa's own world (pages can't see it): if an ad plays anyway, it is muted and played at 16x while
//   the player says `ad-showing`, then sound and speed are put back. It never seeks.
//
// Both run only while the ad blocker is on with the Ads group, and not on sites in the "don't block" list.
enum YouTubeAds {
    /// Exact hosts: accounts.youtube.com and the like have no player.
    static let hosts = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]

    @MainActor static let world = WKContentWorld.world(name: "browsa.youtube")

    /// The two scripts, or none on hosts the person has allowlisted.
    @MainActor
    static func scripts(skipping allowlist: Set<String>) -> [WKUserScript] {
        let active = hosts.filter { host in
            !allowlist.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        guard !active.isEmpty else { return [] }
        return [
            WKUserScript(source: page(hosts: active), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
            WKUserScript(source: skipper(hosts: active), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world),
        ]
    }

    static func hostList(_ hosts: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: hosts)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// The requests the page script answers itself: Google's ad id and YouTube's ad reports.
    /// Only what the filter rules block anyway; the video's own reports go out as before.
    static let standInPattern = #"/^https?:\/\/(?:googleads\.g\.doubleclick\.net\/pagead\/id|(?:[^\/]+\.)?youtube\.com(?:\/api\/stats\/ads|\/pagead\/|\/ptracking|\/api\/stats\/qoe\?.*adformat=))/"#

    static func page(hosts: [String]) -> String {
        """
        (function () {
          'use strict';
          if (\(hostList(hosts)).indexOf(location.hostname) < 0) return;
          // Taken now, before the page runs: what the page puts in their
          // place later is never what this calls.
          var apply = Reflect.apply, owns = Object.prototype.hasOwnProperty,
              define = Object.defineProperty, isArray = Array.isArray;
          var ads = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams'];
          var marks = ['responseContext', 'playabilityStatus', 'streamingData', 'videoDetails'];
          // Videos whose ad schedule was taken out, by id.
          var cutIds = Object.create(null);
          function plain(o) { return o !== null && typeof o === 'object' && !isArray(o); }
          function youtubes(o) {
            for (var i = 0; i < marks.length; i++) if (apply(owns, o, [marks[i]])) return true;
            return false;
          }
          // Whether it took anything out.
          function strip(o) {
            if (!plain(o) || !youtubes(o)) return false;
            var cut = false;
            for (var i = 0; i < ads.length; i++) if (apply(owns, o, [ads[i]])) { delete o[ads[i]]; cut = true; }
            if (cut && plain(o.videoDetails) && typeof o.videoDetails.videoId === 'string') cutIds[o.videoDetails.videoId] = true;
            return cut;
          }
          // The wall, written over an answer that said OK: the answer keeps
          // its status and its video. Any other status is taken as written.
          var wall = 'bkaEnforcementMessageViewModel';
          function walled(v) {
            return plain(v) && plain(v.errorScreen) && apply(owns, v.errorScreen, ['enforcementMessageViewModel']);
          }
          function hold(o) {
            var aux = o.auxiliaryUi, shown = plain(aux) && plain(aux.messageRenderers) && aux.messageRenderers;
            if (!shown || !apply(owns, shown, [wall]) || !apply(owns, o, ['playabilityStatus'])) return;
            var status = o.playabilityStatus, details = o.videoDetails, refused = false;
            define(o, 'playabilityStatus', {
              get: function () { return status; },
              set: function (v) { if (walled(v)) refused = true; else status = v; },
              enumerable: true, configurable: true
            });
            define(o, 'videoDetails', {
              get: function () { return details; },
              set: function (v) { if (v !== undefined || !refused) details = v; },
              enumerable: true, configurable: true
            });
          }
          function one(o) {
            if (!plain(o)) return;
            strip(o);
            if (youtubes(o)) hold(o);
            if (apply(owns, o, ['playerResponse']) && plain(o.playerResponse)) {
              strip(o.playerResponse);
              if (youtubes(o.playerResponse)) hold(o.playerResponse);
            }
          }
          // Whatever happens in here, the page gets back what it asked for.
          function prune(value) {
            try {
              if (isArray(value)) {
                for (var i = 0; i < value.length && i < 8; i++) one(value[i]);
              } else {
                one(value);
              }
            } catch (e) {}
            return value;
          }
          try {
            var parse = JSON.parse;
            if (typeof parse === 'function') {
              define(JSON, 'parse', {
                value: ({ parse(text, reviver) { return prune(apply(parse, JSON, arguments)); } }).parse,
                writable: true, enumerable: false, configurable: true
              });
            }
          } catch (e) {}
          try {
            var json = typeof Response === 'function' && Response.prototype.json;
            var then = Promise.prototype.then;
            if (typeof json === 'function') {
              define(Response.prototype, 'json', {
                value: ({ json() { return apply(then, apply(json, this, []), [prune]); } }).json,
                writable: true, enumerable: true, configurable: true
              });
            }
          } catch (e) {}
          // The ad id and the ad reports the filter rules block, answered here with
          // an empty 200 instead of failing: YouTube counts a failure as a
          // blocker. Nothing is sent.
          var tested = \(standInPattern);
          function answered(u) {
            try { return tested.test(String(new URL(u, location.href))); } catch (e) { return false; }
          }
          try {
            var fetch = window.fetch;
            if (typeof fetch === 'function') {
              window.fetch = ({ fetch(input, init) {
                var u = typeof input === 'string' || input instanceof URL ? input : input && input.url;
                if (u && answered(u)) return Promise.resolve(new Response('', { status: 200, statusText: 'OK' }));
                return apply(fetch, this, arguments);
              } }).fetch;
            }
          } catch (e) {}
          try {
            var X = XMLHttpRequest.prototype, open = X.open, send = X.send, asked = new WeakMap();
            X.open = ({ open(method, u) {
              if (answered(u)) asked.set(this, String(new URL(u, location.href))); else asked.delete(this);
              return apply(open, this, arguments);
            } }).open;
            X.send = ({ send() {
              var u = asked.get(this);
              if (!u) return apply(send, this, arguments);
              var request = this;
              define(request, 'readyState', { value: 4 });
              define(request, 'status', { value: 200 });
              define(request, 'statusText', { value: 'OK' });
              define(request, 'responseText', { value: '' });
              define(request, 'response', { value: '' });
              define(request, 'responseURL', { value: u });
              setTimeout(function () {
                request.dispatchEvent(new Event('readystatechange'));
                request.dispatchEvent(new ProgressEvent('load'));
                request.dispatchEvent(new ProgressEvent('loadend'));
              }, 0);
            } }).send;
          } catch (e) {}
          try {
            var beacon = navigator.sendBeacon;
            if (typeof beacon === 'function') {
              navigator.sendBeacon = ({ sendBeacon(u) {
                return answered(u) ? true : apply(beacon, this, arguments);
              } }).sendBeacon;
            }
          } catch (e) {}
          // The first page's data is a script's `var ytInitial… = {…}`: a
          // setter already there is what that assignment goes through.
          ['ytInitialPlayerResponse', 'ytInitialData'].forEach(function (name) {
            try {
              if (apply(owns, window, [name])) return;
              var held;
              define(window, name, {
                get: function () { return held; },
                set: function (value) {
                  if (name === 'ytInitialPlayerResponse') {
                    try { strip(value); } catch (e) {}
                  }
                  held = prune(value);
                },
                enumerable: true, configurable: true
              });
            } catch (e) {}
          });
          // A video whose pre-roll was taken out is held at 0:00 for the ad's
          // length anyway: YouTube's stream server waits it out. Asking the
          // player for the video again starts a stream without the wait. Once
          // per page or in-page navigation, only for a video whose ads were
          // cut, and not in playlists (the player would drop the playlist).
          function seconds(t) {
            if (!t) return 0;
            if (/^\\d+$/.test(t)) return +t;
            var m = /^(?:(\\d+)h)?(?:(\\d+)m)?(?:(\\d+)s)?$/.exec(t);
            return m ? (+(m[1] || 0)) * 3600 + (+(m[2] || 0)) * 60 + (+(m[3] || 0)) : 0;
          }
          function restart() {
            try {
              if (location.pathname !== '/watch' || location.hostname.indexOf('music.') === 0) return;
              var query = new URLSearchParams(location.search), id = query.get('v');
              if (!id || query.get('list') || !cutIds[id]) return;
              delete cutIds[id];
              var at = seconds(query.get('t') || query.get('start')), href = location.href;
              var until = Date.now() + 10000;
              (function look() {
                if (location.href !== href || Date.now() > until) return;
                var player = document.getElementById('movie_player'), data = null;
                try { data = player && typeof player.getVideoData === 'function' ? player.getVideoData() : null; } catch (e) {}
                // After an in-page navigation the player can still hold the last video.
                if (player && typeof player.loadVideoById === 'function' && (!data || data.video_id === id)) {
                  // Already playing: nothing held.
                  var video = player.querySelector('video');
                  if (video && !video.paused && video.currentTime > 0) return;
                  try { player.loadVideoById(id, at); } catch (e) {}
                  return;
                }
                setTimeout(look, 100);
              })();
            } catch (e) {}
          }
          try {
            document.addEventListener('DOMContentLoaded', restart, { once: true });
            document.addEventListener('yt-navigate-finish', restart);
          } catch (e) {}
        })();
        """
    }

    static func skipper(hosts: [String]) -> String {
        """
        (function () {
          'use strict';
          if (\(hostList(hosts)).indexOf(location.hostname) < 0) return;
          var held = new WeakMap();
          function look(event) {
            var video = event.target;
            if (!(video instanceof HTMLVideoElement)) return;
            var player = video.closest('.html5-video-player');
            var ad = !!player && player.classList.contains('ad-showing');
            var was = held.get(video);
            try {
              if (ad) {
                if (!was) {
                  was = { muted: video.muted, rate: video.playbackRate };
                  held.set(video, was);
                  video.muted = true;
                }
                if (video.playbackRate !== 16) video.playbackRate = 16;
              } else if (was) {
                held.delete(video);
                video.playbackRate = was.rate;
                video.muted = was.muted;
              }
            } catch (e) {}
          }
          ['playing', 'timeupdate', 'durationchange', 'emptied'].forEach(function (type) {
            document.addEventListener(type, look, true);
          });
        })();
        """
    }
}
#endif
