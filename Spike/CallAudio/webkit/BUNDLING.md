# Browsa's WebKit inside the app (feasibility, 2026-11-16)

Goal: ship Browsa with its own WebKit build (call audio in WebKit's capture unit) inside the app bundle, running on it
with no launcher, no environment variables and no Hardened Runtime exceptions.

## Mechanism: LC_DYLD_ENVIRONMENT, the way WebKit's own relocatable builds work

WebKit's dev builds are already "relocatable" (`WK_RELOCATABLE_FRAMEWORKS = YES` in DebugRelease.xcconfig): every
XPC service carries `LC_DYLD_ENVIRONMENT` load commands (`DYLD_FRAMEWORK_PATH=@executable_path/../../..`, from
`RelocatableFrameworksLinkerFlags.xcconfig`) that dyld reads from the signed executable itself. Safari Technology
Preview's staged frameworks use the same family of settings (`WK_OVERRIDE_FRAMEWORKS_DIR`, `USE_STAGING_INSTALL_PATH`).

For the app: link Browsa with

    OTHER_LDFLAGS = $(inherited) -Wl,-dyld_env,DYLD_FRAMEWORK_PATH=@executable_path/../Frameworks
                    -Wl,-dyld_env,DYLD_LIBRARY_PATH=@executable_path/../Frameworks

and put WebKit, WebCore, JavaScriptCore, WebGPU, WebKitLegacy, _WebKit_SwiftUI, WebInspectorUI, libwebrtc and
libANGLE in `Contents/Frameworks`. dyld then takes those in place of the system's, in the app and (through the
services' own load commands) in WebKit's GPU, Networking and WebContent processes. If they're missing, dyld uses the
system WebKit: the fallback costs nothing.

`bundle-webkit.sh <app> <webkit build folder> [identity]` assembles and signs a test bundle; `set-dyld-env.py`
rewrites the services' `LC_DYLD_ENVIRONMENT` for their place inside `WebKit.framework/Versions/A/XPCServices`
(seven levels up instead of three; there was header room). A release pipeline should instead build WebKit with the
deployed layout (`DEPLOYMENT_LOCATION = YES`, where `WK_PATH_FROM_SERVICE_EXECUTABLE_TO_FRAMEWORKS` already resolves to
`../..` from the framework), so no binary is edited.

## What was checked ("Browsa Bundled", com.orriginal.browsa.bundled, ~/Developer/Browsa/derived/bundled)

- Signed inside out with Hardened Runtime (`flags=0x10000(runtime)`), the app's normal entitlements and **neither**
  `allow-dyld-environment-variables` nor `disable-library-validation`; `codesign --verify --deep --strict` passes.
  (Signed with the team's Apple Development certificate: same team as Developer ID, so library validation behaves the
  same; Developer ID + notarisation not tried, see below.)
- Opened through LaunchServices: the app maps `Contents/Frameworks/WebKit.framework` etc., with no relaunch; the GPU,
  Networking and WebContent processes run from `Contents/Frameworks/WebKit.framework/Versions/A/XPCServices` and map
  the bundled WebCore, JavaScriptCore and libwebrtc (so the call audio unit in the GPU process is Browsa's). Windows
  open; Meet loads in an ordinary tab.
- Bundled WebKit removed (and the app re-signed): starts on the system WebKit by itself.
- Helper entitlements needed: WebContent `com.apple.security.cs.allow-jit`; GPU and Networking none. The build's
  `get-task-allow` and `fatal-exceptions` are dropped. No Apple-private entitlements are involved.

## Size

| | on disk | zipped |
|---|---|---|
| as built (symbols, no headers) | 284 MB | |
| stripped (`strip -x`) | 155 MB | 57 MB |
| of which Web Inspector | 19 MB | |

(CEF, for Chromium call tabs, is another 326 MB unzipped today.)

## Support matrix (Chromium call tabs removed, 1954f68)

| Mac | WebKit | Call audio |
|---|---|---|
| macOS 26.7 or later 26.x, Apple silicon | Browsa's, bundled | Browsa's (WebRTC processing in the capture unit, join warm-up, gain only while you talk) |
| macOS 26.0-26.6 | Browsa's, bundled (the 26.x build targets 26.0) | Browsa's |
| Intel | Apple's | macOS voice processing |
| macOS 27.x | Browsa's once a 27 build ships (built here with Xcode 27.2's SDK; untested until a Mac on 27 runs it) | Browsa's, else macOS voice processing |
| a newer major before a build for it, or older than 26 | Apple's | macOS voice processing |

The in-page call audio script is off by default everywhere (an experimental option on Apple's WebKit).

## Sizes (zipped = what a download would be)

| | on disk | zipped |
|---|---|---|
| public 1.0 (before call tabs) | | 16 MB |
| today's app with Chromium, no bundled WebKit | 361 MB | 156 MB |
| with Chromium + bundled WebKit (unstripped) | 661 MB | 234 MB |
| no Chromium, no bundled WebKit | 30 MB | 15 MB |
| no Chromium + bundled WebKit (unstripped) | 328 MB | 93 MB |
| **no Chromium + bundled WebKit, stripped (release estimate)** | **181 MB** | **73 MB** |

## Older (and newer) macOS: a launcher that picks, with no exception

`LC_DYLD_ENVIRONMENT` can't depend on the OS, so the app gets a tiny main executable (`launcher/main.c`, 51 KB,
universal) that runs before anything else and `exec`s one of two real executables in the same process:

- `Contents/MacOS/Browsa-webkit`: the app linked with the `-dyld_env` flags (bundled WebKit)
- `Contents/MacOS/Browsa-system`: the same app without them (Apple's WebKit)

It picks `Browsa-webkit` when the bundled WebKit is there, Settings hasn't switched it off (`patchedWebKit`), and the
running macOS is within `Contents/Resources/BrowsaWebKitOS.txt` ("26.7 26": at least the build's minimum, and not a
newer major than it was built for). The reason goes to the app as `BROWSA_BUNDLED_WEBKIT=used|old-os|new-os|off|missing`.
`BROWSA_OS_VERSION_OVERRIDE` simulates another macOS. All three executables carry the app's identifier, entitlements
and Hardened Runtime, and **no exception**; exec keeps the process, so camera and mic stay Browsa's and launch events
arrive (nothing has checked in with macOS yet).

Checked on "Browsa Bundled (launcher)": macOS 26.7.2 → bundled WebKit (app and its three helpers from inside the app);
simulated 26.0 → `old-os`, Apple's WebKit; simulated 27.0 → `new-os`, Apple's WebKit; windows and a link given at launch
come through. Cost: a second copy of the app executable (16 MB, ~6 MB zipped); moving the app's code into a framework
would make both executables tiny. (The alternative, the launch-time relaunch in PatchedWebKit.swift, needs
`allow-dyld-environment-variables`; with everything signed by our team, library validation could stay on.)

## Signing for release (tools/release-mac.sh)

The release archives with automatic signing, then `xcodebuild -exportArchive` (method developer-id, destination
upload) re-signs everything with the cloud-managed Developer ID certificate and uploads it to Apple's notary service;
`-exportNotarizedApp` fetches and staples. There is no Developer ID certificate on this Mac, so the re-sign can't be
reproduced locally. Unverified: whether that export keeps the WebContent service's `allow-jit` and the extra
executables' entitlements. The bundling would have to move into the build (a script phase that copies and signs with
`$EXPANDED_CODE_SIGN_IDENTITY` before archiving), so the archive contains it. A notarisation attempt uploads the whole
app as one zip: Browsa (launcher + two executables), Sparkle, the Chromium framework for call tabs, and the bundled
WebKit (7 frameworks, libwebrtc, libANGLE, 3 XPC services). It goes to Apple only, is not published, and is
needed once to learn whether the JIT entitlement survives.

## Intel

The build is arm64 only. A universal WebKit (`ARCHS="arm64 x86_64"`) roughly doubles a clean build (about 2 hours
instead of 1 on Apple silicon) and the bundled size (about 300 MB stripped, 110 MB zipped, instead of 155 / 57). Other
options: an Intel download without the bundled WebKit (the launcher sees no WebKit and uses Apple's), or a separate
x86_64 build. An Intel Mac (or a long run under Rosetta) is needed to test it.

## Blockers and open questions for shipping to other people

1. **macOS version.** (Handled by the launcher above.) The build's minimum is macOS 26.7 (`minos 26.7`, SDK 27.2) and WebKit links about a dozen
   Apple-private system frameworks at fixed paths, so a bundled WebKit is tied to the macOS it was built for (Safari
   Technology Preview ships one build per macOS). `LC_DYLD_ENVIRONMENT` can't be made conditional on the OS, so an
   older macOS would load it and very likely crash. Options: Browsa's minimum macOS = the build's; per-OS builds; or
   the launch-time relaunch (Mac/Sources/PatchedWebKit.swift), which can check the OS first but needs
   `allow-dyld-environment-variables` (with the frameworks signed by our team, not `disable-library-validation`).
   Building trunk with a lower deployment target is untested and limited by those private frameworks.
2. **Intel.** The build is arm64 only. Universal doubles build time and size; whether dyld skips a wrong-architecture
   framework on an Intel Mac and falls back is untested.
3. **Notarisation.** (See above.) Releases sign through Xcode's cloud-managed Developer ID export (tools/release-mac.sh). The export
   re-signs nested code; the WebContent service needs its JIT entitlement kept (sign it in a script phase before
   archiving, or re-sign after export and notarise with notarytool, which needs credentials set up). Not run.
4. **Security updates.** Browsa would carry its own WebKit: every Safari security release means rebasing the patch
   (4 files) onto Apple's release branch, rebuilding and re-testing.

## What a release pipeline would need

- A pinned WebKit source: a fork (e.g. a BrowsaWebKit repo) on a Safari release branch, with `webkit.patch` and the
  three headers applied as commits, tagged per Browsa release.
- A full release build: about an hour on Apple silicon from clean (incremental WebCore rebuilds take under a minute),
  per macOS target and architecture; built with the deployed layout and stripped; dSYMs kept for crash reports.
- Bundling and signing as in `bundle-webkit.sh`, then the existing archive → Developer ID export → notarise → Sparkle
  steps. Sparkle deltas keep updates small when only Browsa changes.
- The bench (tools/audio-bench) run against each new WebKit before release.

## One build per macOS major (2026-11-16)

Trunk WebKit at-desk builds target the host's macOS (26.7 here). Built with `MACOSX_DEPLOYMENT_TARGET=26.0
WK_MACOSX_DEPLOYMENT_TARGET=26.0` (separate output folder, `WEBKIT_OUTPUTDIR=WebKitBuild-26.0`), everything compiles
for 26.0 except two Swift files that use newer point-release APIs; both now have guards in `webkit.patch`:
`MockPhoneNumberPossessionManager.swift` (base64url options, macOS 26.4: replaced by an equivalent) and
`CredentialUpdaterShim.swift` (passkey signal APIs, macOS 26.2: skipped below it). All frameworks, libwebrtc, ANGLE
and the three services then say `minos 26.0`. Swift checks availability at compile time; Objective-C/C++ uses of
newer APIs that aren't guarded would only show up at run time, so a run on a real 26.0 Mac (or a 26.0 VM on this
Mac) is still needed. A macOS 27 build is the same with 27.0, with this Mac's Xcode 27.2 SDK; a Mac on 27 must test it
(a VM can't run a newer macOS than its host).

App layout: each major's WebKit in `Contents/Frameworks/WebKit-<major>` with an executable `Browsa-webkit-<major>`
linked to it (`-dyld_env DYLD_FRAMEWORK_PATH=@executable_path/../Frameworks/WebKit-<major>`), its minimum in
`Resources/WebKit-<major>.minimum`, its label in `Resources/BROWSA_WEBKIT-<major>.txt`; the launcher picks by the
running major (`BUNDLE_MAJOR=26 BUNDLE_MINIMUM_OS=26.0 bundle-webkit.sh ...` assembles one). Checked on "Browsa Bundled
(per-major)" with the 26.0 build: real 26.7.2 and simulated 26.0 → the 26 build (helpers inside the app); simulated
25.6 → old-os, simulated 27.0 (no 27 build yet) → new-os, both Apple's WebKit. Each major adds one WebKit
(155 MB stripped, ~57 MB zipped) and one executable (16 MB); with one major the app is 181 MB / 73 MB zipped. With
several, downloading the matching WebKit on first run keeps the app small.

### The macOS 27 build (2026-11-16)

`WEBKIT_OUTPUTDIR=WebKitBuild-27.0 build-webkit --release MACOSX_DEPLOYMENT_TARGET=27.0 WK_MACOSX_DEPLOYMENT_TARGET=27.0`
built cleanly with this Mac's Xcode 27.2 (no further source changes); every binary says `minos 27.0`. "Browsa Bundled
(per-major)" now carries `WebKit-26` and `WebKit-27` with `Browsa-webkit-26` / `Browsa-webkit-27`: on this Mac (26.7.2)
the launcher picks the 26 build; with `BROWSA_OS_VERSION_OVERRIDE=27.0` it picks the 27 build, which even loaded and
opened windows on 26.7 without a crash report. So dyld does **not** refuse a build for a newer macOS: the launcher's
version check is the only guard, and a real test of the 27 build needs a Mac on 27.

Two majors: 628 MB unstripped; stripped about 350 MB on disk and ~136 MB zipped (each major adds a 155 MB / ~57 MB
WebKit and a 16 MB executable), which is the point where downloading the matching WebKit on first run pays off.

## Call recordings stay out of release builds

"Record calls for tuning" (Settings › Audio, Development) and the WebKit dump behind it (`BROWSA_CALL_AUDIO_DUMP`)
are for development only:

- App: `CallRecordings.swift`, its Settings section and the launch hook compile only under `DEBUG` or the
  `BROWSA_CALL_RECORDING` condition (`tools/install-mac.sh --patched-webkit` sets it for the local daily). Without
  it, the relaunch strips every `BROWSA_CALL_AUDIO_DUMP*` / `__XPC_BROWSA_CALL_AUDIO_DUMP*` variable.
- Launcher (`launcher/main.c`): reads the recording preference only when built with `-DBROWSA_CALL_RECORDING`;
  otherwise it unsets the same variables before WebKit starts.
- WebKit: `BrowsaCallAudioInternalUnit.h` reads the dump variable only when `BrowsaCallAudioRecording.h` is in the
  tree (it defines `BROWSA_CALL_AUDIO_RECORDING 1`). **Build release WebKit from a clean tree without that header**
  (and check: `strings WebCore | grep -c BROWSA_CALL_AUDIO_DUMP` gives 0). The WebKit builds made before 16 Nov 2026
  all contain the dump code, gated only by the variable, so they must not be bundled.

## In the release path (2026-11-16)

The steps above now run from `tools/release-mac.sh`, opt-in with `BROWSA_BUNDLE_WEBKIT="26=<build> 27=<build>"`
(docs/mac-releases.md): release WebKit builds from `build-release-webkit.sh` (clean tree, no recording header,
checked), bundled into the archived app by `tools/mac-bundle-webkit.sh` (launcher, `Browsa-system`,
`Browsa-webkit-<major>` made by adding the load commands to a copy of the app's executable, stripped WebKit, dSYMs
into the archive), then the usual Developer ID export. `tools/release-mac.sh --local` stops after a Developer ID
export to disk, so nothing goes to the notary service. `tools/mac-check-release.sh` checks the result. The launcher
now also sends Intel Macs (and Rosetta) to `Browsa-system` (`BROWSA_BUNDLED_WEBKIT=intel`), since the WebKit builds
are arm64 only.

Measured on the release path (Browsa 1.1 test build, e10e7ca, not notarised):

| | on disk | zipped |
|---|---|---|
| no bundled WebKit (Developer ID export) | 26 MB | 17 MB |
| WebKit-26 only (Developer ID export) | 186 MB | 80 MB |
| WebKit-26 + WebKit-27 (archive-signed; export blocked, see the report) | 346 MB | 144 MB |

The Developer ID export keeps the WebContent service's `allow-jit` and signs every executable (launcher,
`Browsa-system`, `Browsa-webkit-26`, WebKit's services) with Developer ID and Hardened Runtime.
