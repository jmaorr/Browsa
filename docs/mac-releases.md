# Mac releases

Browsa for Mac ships outside the App Store: Developer ID signed, notarised by Apple, and kept up to
date in the app by [Sparkle](https://sparkle-project.org).

## Making a release

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

It publishes nothing. Release notes go in `docs/release-notes/mac/<version>.md`, if you want
them; Sparkle shows them in its update window.

Keep the old zips in the releases folder. `generate_appcast` reads them all to build the appcast's
history and the delta updates.

## Which builds update themselves

Only builds from `release-mac.sh`. The `BrowsaUpdates` Info.plist key is `NO` everywhere else,
so Xcode runs ("Browsa Dev") and `tools/install-mac.sh` builds never start Sparkle and never swap
themselves for a release. With updates on, the app menu has **Check for Updates…** and
Settings > General has the two automatic-update switches. Everything else is Sparkle's own
standard windows.

## The signing key

Sparkle's EdDSA private key lives in the login keychain on Josh's Mac (service
`https://sparkle-project.org`, account `ed25519`). Its public half is `SUPublicEDKey` in `project.yml`.
Without the private key, no installed copy will accept another update, so keep a backup:

```sh
"$HOME/Library/Caches/com.orriginal.browsa.release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" -x browsa-sparkle-key.txt
```

and store that file in 1Password, then delete it.

## Where updates are served (proposal)

The app looks for `https://browsa.app/mac/appcast.xml` and the appcast points downloads at
`https://browsa.app/mac/releases/<file>`. Nothing is published there yet. The proposal:

- **appcast.xml** as a static asset in `website/public/mac/appcast.xml`, committed with each
  release and deployed with the site, with `Cache-Control: no-cache` in `_headers` so new
  releases show up straight away. It is small and its history in git is useful.
- **Zips, deltas and DMGs** in an R2 bucket (say `browsa-releases`) bound to the website Worker,
  which serves `/mac/releases/*` from it. They don't belong in git, and Workers static assets
  would need every past one in each deploy.
- **The Download button** points at `https://browsa.app/mac/releases/Browsa.dmg`
  (`DOWNLOADS.mac` in `website/src/index.js`), so new downloads always get the newest build,
  and `/download/mac` redirects there.

Order matters when publishing: upload the zip, deltas and DMGs first, then deploy the appcast, so
the appcast never points at a file that isn't there.
