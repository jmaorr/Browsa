# browsa.app

The Browsa website and privacy policy: a static site in `public/`, served by a small Cloudflare
Worker (`src/index.js`) that also redirects www to the bare domain.

```sh
npx wrangler dev      # preview locally
npx wrangler deploy   # publish to browsa.app
```

## Pages

- `/` iPhone Duo, `/mac/` Browsa for Mac, `/mac/developers/` building for it, `/download/` both.
- The Mac pages draw the window in HTML and CSS (`desktop.js`, `desktop.css`) instead of using
  footage, so they never go stale. A frame with `data-mw` gets a window; `data-scene` picks what
  it shows and `data-cycle="sidebar focus"` loops through scenes. Swap one for a `<video>` when
  there's a clip; the film placeholder on `/mac/` has a comment showing how.
- Sizes in the window are the app's own points (one `--u` is a point of a 1280 × 800 window), so
  when the Mac UI changes, change the matching number in `desktop.css`.
- The feature bento near the bottom of `/mac/` draws corners of the real window (sidebar, favourites,
  Downloads panel) with real sites' icons from `public/media/fav/`. The ad, cookie and Reader tiles
  use real page captures in `public/media/bento/`, made on a Mac with an offscreen WKWebView. Ads
  don't load on that network, so the ad in the Verge tile is drawn into the page's real ad slot.
- The pages inside it (`desktop-sites.js`): Wander & Salt, a made-up travel journal; Tern, a
  made-up developer docs site; Supper, the real agent demo (`public/demo`), shown as captures in
  `media/hero/supper-0..4.webp` (682 × 788pt, the page with the panel open; recapture them if the
  demo changes); and the Library, drawn from `Mac/Sources/Library/LibraryPage.swift` with the
  verified extensions' icons in `media/ext/`. The film is `media/browsa-mac.mp4` (the 36 s web cut,
  re-encoded at 1600 wide) with `media/browsa-mac.webp` as its poster.

## Download links

Every Download button is set in one place: `DOWNLOADS` at the top of `src/index.js`. While a link
is `null`, the pages show their coming-soon state (the static HTML). Set a URL and the Worker
points every `data-download` button there with its live label, and removes the `data-soon` notes.
`/download/mac` and `/download/ios` always redirect to the current link.

The Mac link is automatic: once `tools/publish-mac.sh` has put `Browsa.dmg` in the
`browsa-releases` R2 bucket, the buttons point at `/mac/releases/Browsa.dmg`, the newest build.
The Worker also serves the Sparkle appcast (`/mac/appcast.xml`) and every release file from that
bucket. See `docs/mac-releases.md`.

## Usage counts

The Worker counts Mac update checks (by app version) and downloads (by file) in Workers Analytics
Engine, dataset `browsa_usage`, with no IP, user agent, location or ID. Sparkle checks about once a
day, so update checks per day are a rough count of Macs running Browsa. Read them with
`scripts/usage.sh [days]` (needs `CLOUDFLARE_ACCOUNT_ID` and an API token with Account Analytics
Read). The dataset is created on the first write after deploy; it keeps three months.

The same counts go to PostHog (project "Browsa", US cloud) as `update-check`, `download` and
`update` events with a `version` property, for the Browsa Usage dashboard there. The Worker sends
them, so PostHog never sees a visitor's IP, and every event has the same `distinct_id` and no
person profile. Turn it on with `npx wrangler secret put POSTHOG_TOKEN` (the project token from
PostHog's project settings); without it nothing is sent.

`scripts/build-clips.sh` rebuilds the clips and stills in `public/media` from raw simulator captures.

When the app's network behaviour changes, update `public/privacy/index.html` and its date.

## Licenses

The MIT license on this repository doesn't cover `public/vendor/transitions/`, which is
[Transitions.dev](https://transitions.dev/)'s UI generation runtime under its own license
(`LICENSE.txt` in that folder), with one small change so it works under the site's content security
policy. Clips and stills show third-party websites, which belong to their owners.
