# YouTube ad check

Checks that Browsa's YouTube ad blocking still lets videos play straight away. YouTube changes how it
serves ads often, so this breaks without any change on our side.

```sh
tools/youtube-ad-check/run.sh                 # newest ads.json from an installed Browsa
tools/youtube-ad-check/run.sh path/to/ads.json
tools/youtube-ad-check/run.sh --verbose       # every probe, plus the page's console errors
```

## When to run it

- After YouTube changes something (a new player, people mention ad blockers breaking).
- Before each Mac release.
- When someone reports YouTube sitting on its spinner, or a black player, with blockers on.

## What it does

`run.sh` compiles `main.swift` together with the app's own `WebKitEngine/YouTubeAds.swift` and
`BrowserCore/YouTubeAdRules.swift`, so it always tests the current code. Each case runs in a fresh offscreen
WKWebView set up like Browsa's: Safari's user agent, a non-persistent data store (no cookies, no account),
the Ads rule list with the YouTube rules appended, and both YouTube scripts. The page is muted in the
engine, so nothing is ever heard. The rule list is the newest `Filters/ads.json` of any installed Browsa,
else the bundled starter list.

| Case | What it is |
| --- | --- |
| direct | Loads a watch page |
| repeat | Loads it again in the same web view |
| search-click | Clicks a search result (YouTube's in-page navigation) |
| related-click | Clicks a related video on a watch page |
| playlist-mix | Loads a Mix (`&list=`); the playlist must be kept |
| mix-next | Loads a Mix, then presses Next twice: each must open the Mix's next item quickly. Known: often waits 4 to 12 s, since YouTube gives the restarted stream a wait of its own |
| playlist-next | The same with a user playlist (`list=PL…`) |
| search-mix | Clicks a Mix in search results (in-page navigation into a Mix). Known: waits out the ad, since the page hands the player no playlist to give back |

PASS means the video plays within 6 s of a click or Next, or 8 s from the start of a page load, with no
ad showing (without the fix the wait is the ad's length, usually 12 to 30 s), and on a playlist the
playlist is kept: the page's playlist panel is drawn and holds the video, the player's playlist id and
index match it, and Next opens the panel's next item. A case marked `known` is reported as `FAIL (known)`
and doesn't fail the run. The exit code is non-zero when a case that should pass fails. A case where
YouTube served no ad is run again, up to three times.

Flags: `ads-cut` means YouTube sent an ad and the script took it out. `server-wait-Ns` is the wait the
stream server (SABR) asked for, which is the cut ad's length; the script gets round it by asking the player
for the video again. `ad-showing` means an ad played. `ad-data-left` means ads got past the script.
`list-ok` / `list-lost`: the playlist was kept or dropped. `next-ok`: every Next opened the playlist's
next item with the playlist kept; `next-lost`: it played but the playlist was dropped; `next-stuck`: Next
didn't play the playlist's next item. Next cases are timed by their slowest Next. A case
marked `no ad served` proves nothing, since YouTube sent no ad that time: run it again.
