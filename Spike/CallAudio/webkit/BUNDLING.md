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

## Blockers and open questions for shipping to other people

1. **macOS version.** The build's minimum is macOS 26.7 (`minos 26.7`, SDK 27.2) and WebKit links about a dozen
   Apple-private system frameworks at fixed paths, so a bundled WebKit is tied to the macOS it was built for (Safari
   Technology Preview ships one build per macOS). `LC_DYLD_ENVIRONMENT` can't be made conditional on the OS, so an
   older macOS would load it and very likely crash. Options: Browsa's minimum macOS = the build's; per-OS builds; or
   the launch-time relaunch (Mac/Sources/PatchedWebKit.swift), which can check the OS first but needs
   `allow-dyld-environment-variables` (with the frameworks signed by our team, not `disable-library-validation`).
   Building trunk with a lower deployment target is untested and limited by those private frameworks.
2. **Intel.** The build is arm64 only. Universal doubles build time and size; whether dyld skips a wrong-architecture
   framework on an Intel Mac and falls back is untested.
3. **Notarisation.** Releases sign through Xcode's cloud-managed Developer ID export (tools/release-mac.sh). The export
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
