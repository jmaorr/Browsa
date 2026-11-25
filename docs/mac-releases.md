# Mac releases

Browsa for Mac ships outside the App Store: Developer ID signed, notarised by Apple, and kept up to
date in the app by [Sparkle](https://sparkle-project.org).

## Launch checklist (1.0)

In this order, so nothing points at a page that isn't there yet:

1. **Deploy the website** from main (`wrangler deploy` in `website/`). This makes live, for the
   first time: `/mac/`, `/mac/developers/`, `/download/` (and `/download/mac`, `/download/ios`),
   the `/mac/appcast.xml` and `/mac/releases/` routes, and **`/demo/`**, Supper.
2. **Check Supper** at https://browsa.app/demo/: the page loads with all eight photos, and the
   browser console shows no Content-Security-Policy errors. Browsa's Watch a Demo and the Try it
   prompt use this address in every build (SpikeBrowsa too); they only fall back to the copy in the
   app bundle while it can't be reached. Keep `website/public/demo/` and `Mac/Resources/Demo/`
   the same.
3. `tools/release-mac.sh 1.0`
4. `tools/publish-mac.sh 1.0`

## Before shipping the 1Password desktop-app unlock

**Release blocker.** The extension work on `claude/project-thread-himevy` (PR #105) lets 1Password's extension unlock
through the 1Password Mac app, but only after the user adds Browsa in 1Password › Settings › Browser › Add Browser.
Don't release it without the onboarding for that step:

- Detect the refusal: the 1Password helper's reply `BrowserVerificationFailed` with `UnknownBrowser`, seen as it passes
  through `ExtensionNativeHosts`, triggers the guidance. A successful connection dismisses it.
- A card for that moment: "In 1Password, open Settings › Browser › Add Browser and choose Browsa", with a button that
  opens 1Password, and a short clip of the steps.
- New users: a step in the welcome flow when the 1Password app is installed.
- Existing users: the same card on the first refusal after updating, plus a What's New line.
- Releases are Developer ID signed, which 1Password requires; an Apple Development build is always refused.
- Ask 1Password to list Browsa as a known browser (draft in ~/Developer/Browsa/outreach), which would remove the step.

## Making a release

Before you make one, run `tools/youtube-ad-check/run.sh` ([README](../tools/youtube-ad-check/README.md)):
every case but the known one should pass, or YouTube has changed how it serves ads.

```sh
tools/release-mac.sh 1.0.1              # from origin/main
tools/release-mac.sh 1.0.1 <git-ref>    # any branch, tag or commit
```

The script builds a clean export of the ref, then:

1. Archives the Release configuration with `MARKETING_VERSION` set to the version you give,
   `CURRENT_PROJECT_VERSION` set to the commit count (Sparkle needs it to grow every release),
   and `BROWSA_UPDATES=YES`.
2. Signs it with Developer ID and sends it to Apple's notary service, both through the Xcode
   account (team UAU4449Y7J). Xcode uses a cloud-managed Developer ID certificate, so nothing
   has to be in the keychain, and no app-specific password or notarytool profile is needed.
3. Waits for notarisation, staples the ticket and checks Gatekeeper accepts the app.
4. Zips it into `~/Developer/Browsa/releases/mac` (or `BROWSA_RELEASES_DIR`) for Sparkle.
5. Makes the drag-to-Applications DMG for first downloads in `dmg/` underneath, as
   `Browsa-<version>.dmg` and a copy called `Browsa.dmg`, which is always the newest. The window
   art is `Mac/Distribution/dmg-background.tiff` (600×360 pt, @1x and @2x in one file), adapted
   from the Toolkit app's. It needs `brew install create-dmg`, and the first run asks to let the
   terminal control Finder. The DMG itself isn't signed or notarised; the app inside is, with
   its ticket stapled, which is what Gatekeeper checks.
6. Runs Sparkle's `generate_appcast`, which signs the zip with the EdDSA key, makes delta updates
   from the previous zips, and rewrites `appcast.xml`.

It publishes nothing. Release notes go in `docs/release-notes/mac/<version>.md`; Sparkle shows them in
its update window. Write them before you run the script: [docs/release-notes/mac/README.md](release-notes/mac/README.md)
has the template, the tone, and `tools/mac-changelog.sh` to list what changed since the last release.

Keep the old zips in the releases folder. `generate_appcast` reads them all to build the appcast's
history and the delta updates.

## Browsa's WebKit inside the app (opt-in)

Browsa's call audio (the Browsa Audio Engine) lives in its own WebKit build. A release carries it only when
asked; without `BROWSA_BUNDLE_WEBKIT` the app is exactly as before and uses Apple's WebKit everywhere. The
details and the reasoning are in `Spike/CallAudio/webkit/BUNDLING.md`. (The Chromium call tabs are gone,
1954f68: the app carries no CEF.)

1. A clean WebKit source tree at `Spike/CallAudio/webkit/WEBKIT_COMMIT` (upstream WebKit plus Browsa's own
   fixes; `Spike/CallAudio/webkit/prepare-webkit-tree.sh <tree>` makes one from a fresh clone), with `webkit.patch` applied and
   the two headers from `Spike/CallAudio/core` copied in (that folder's README), and **without**
   `BrowsaCallAudioRecording.h`, so no call recording code is compiled in. For example a worktree:
   `git -C ~/Developer/Browsa/webkit/source worktree add --detach ~/Developer/Browsa/webkit/release <commit>`.
2. One release WebKit per macOS major (about an hour and 30 GB each, Apple silicon only):

   ```sh
   Spike/CallAudio/webkit/build-release-webkit.sh ~/Developer/Browsa/webkit/release 26
   Spike/CallAudio/webkit/build-release-webkit.sh ~/Developer/Browsa/webkit/release 27
   ```

   Each lands in `<tree>/WebKitBuild-release-<major>.0/Release`, targets `<major>.0`, is checked for the
   right minimum macOS and for having no dump code, and is labelled `release <major>.0 …`.
3. Release with them:

   ```sh
   BROWSA_BUNDLE_WEBKIT="26=$HOME/Developer/Browsa/webkit/release/WebKitBuild-release-26.0/Release 27=$HOME/Developer/Browsa/webkit/release/WebKitBuild-release-27.0/Release" \
     tools/release-mac.sh --local 1.1 origin/main     # first: local only, nothing sent to Apple
   BROWSA_BUNDLE_WEBKIT="…same…" tools/release-mac.sh 1.1 origin/main
   ```

After archiving, `tools/mac-bundle-webkit.sh` turns the archived app into: a small launcher as
`Contents/MacOS/Browsa` that picks, before anything loads, `Browsa-webkit-<major>` (the app, arm64, pointed
at `Contents/Frameworks/WebKit-<major>` by load commands in the signed executable) when this macOS major has a
bundled WebKit, or `Browsa-system` (Apple's WebKit) otherwise: another major, an Intel Mac, or the engine
switched off in Settings. Each WebKit is stripped; its dSYMs go into the archive. Every executable keeps the
app's identity, entitlements and Hardened Runtime, with no exception entitlement; only WebKit's WebContent
service may JIT. It refuses a WebKit with the dump compiled in, and an app with call recording or local-only
entitlements. Then the export re-signs everything with Developer ID as before.

`tools/mac-check-release.sh <app>` checks the result (the release runs it on every release, bundled or not):
signature, Developer ID on every executable, Hardened Runtime, entitlements, no call recording, no Chromium,
and each bundled WebKit's executable and label.

`--local` stops after the Developer ID export to disk (the cloud-managed certificate signs it; nothing goes to
the notary service), checks it and zips it in `~/Library/Caches/com.orriginal.browsa.release-local`. Gatekeeper
rejects that copy as "Unnotarized Developer ID", which is expected.

Still to do before shipping it: the first notarisation of a bundled app (does the notary service accept it, and
does the WebContent service keep its JIT entitlement after Apple's checks), and runs on a Mac on macOS 26.0 and on
macOS 27. Each major adds about 57 MB to the download.

## Which builds update themselves

Only builds from `release-mac.sh`. The `BrowsaUpdates` Info.plist key is `NO` everywhere else,
so Xcode runs ("Browsa Dev") and `tools/install-mac.sh` builds never start Sparkle and never swap
themselves for a release. With updates on, the app menu has **Check for Updates…** and
Settings > General has the two automatic-update switches. Everything else is Sparkle's own
standard windows.

## Testing an update

The feed URL is the `BROWSA_FEED_URL` build setting, so a test can point Sparkle somewhere else.
Build two versions under a throwaway bundle ID (so they never touch the real app's data), serve a
feed locally and update one to the other:

```sh
xcodebuild … archive MARKETING_VERSION=0.0.1 CURRENT_PROJECT_VERSION=1000 BROWSA_UPDATES=YES \
  PRODUCT_BUNDLE_IDENTIFIER=com.orriginal.browsa.updatetest BROWSA_APP_NAME="Browsa Update Test" \
  BROWSA_FEED_URL=http://127.0.0.1:8798/appcast.xml
```

(and 0.0.2 / 1001 the same way), export both with Developer ID, zip 0.0.2 into a folder, run
`generate_appcast --download-url-prefix http://127.0.0.1:8798/` on it and serve it with
`python3 -m http.server 8798 --bind 127.0.0.1`. Last run 2026-11-09: 0.0.1 offered 0.0.2,
downloaded it on Install Update, and relaunched as 0.0.2 with its signature intact.

## The signing key

Sparkle's EdDSA private key lives in the login keychain of the Mac that makes releases (service
`https://sparkle-project.org`, account `ed25519`). Its public half is `SUPublicEDKey` in `project.yml`.
Without the private key, no installed copy will accept another update, so keep a backup:

```sh
"$HOME/Library/Caches/com.orriginal.browsa.release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" -x browsa-sparkle-key.txt
```

and store that file in 1Password, then delete it.

## Publishing

```sh
tools/publish-mac.sh 1.0.1
```

uploads the release to the `browsa-releases` R2 bucket, under `mac/`. The website Worker
(`website/src/index.js`, binding `RELEASES`) serves it:

- `https://browsa.app/mac/appcast.xml`: the Sparkle feed, revalidated on every request.
- `https://browsa.app/mac/releases/<file>`: zips, deltas and DMGs. Versioned files are cached
  for a year, since they never change.
- `https://browsa.app/mac/releases/Browsa.dmg`: always the newest build, cached for an hour.
  Every Mac Download button on the site, and `/download/mac`, point here once it exists. Until
  the first release is published the buttons keep their "coming soon" state.

The script uploads the zip, deltas and DMGs first and the appcast last, so the appcast never
points at a file that isn't there. Publishing doesn't need a site deploy. Files stay in the
bucket, so an older version can still be downloaded by its versioned name.
