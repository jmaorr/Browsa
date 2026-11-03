# Browsa on macOS: viability spike

Tested 2026-11-03 on macOS 26.7.1 with Xcode 27.2. The test app is a bare AppKit and WKWebView browser,
signed with an Apple Development certificate and running in the App Sandbox, as an App Store build would.

## Verdict

Viable as a browser, but native passkeys depend on an Apple approval that the current developer account
probably can't request.

| Area | Result | Needs from Apple |
| --- | --- | --- |
| Password sign-in | Google's first sign-in screen loads. The step after Next is untested. | Nothing |
| Native passkeys and security keys | Blocked without the entitlement | Managed entitlement, requested by an organization's Account Holder |
| Passkeys from an extension | Reported working elsewhere, not tested here | Nothing |
| Extensions | Manifest V3 core APIs work in the sandbox. Real third-party extensions are untested. | Nothing |
| Default browser | `http` and `https` URL types in Info.plist, per other projects' reports | Nothing |

## Measured

### Passkeys

The probe page at `http://localhost:8765` made WebAuthn requests from a focused window with a click.

- `navigator.credentials.create()` for a passkey, `get()`, and `create()` for a security key all rejected
  within 65 ms with `NotAllowedError`. No system sheet appeared.
- `PublicKeyCredential` still exists, so a site can offer a passkey button that then fails. Until the
  entitlement is granted, the app should hide it so that sites fall back to passwords.
- `isUserVerifyingPlatformAuthenticatorAvailable()` and `isConditionalMediationAvailable()` both returned
  false, while `ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys` returned true.
- Signing with `com.apple.developer.web-browser.public-key-credential` but no provisioning profile gets the
  app killed at launch (exit 137). The key can't be added before Apple grants it.

The positive case can't be tested until Apple grants the entitlement.

### Extensions

The probe extension in `probe-extension/` loaded through `WKWebExtensionController` (macOS 15.4 or later).

- Working: service worker background, content script, messaging, `storage`, `tabs`, `scripting`, `cookies`,
  `alarms`, action popup, and `declarativeNetRequest` blocking a request.
- Present but not exercised: `webRequest`, `webNavigation`, `contextMenus`.
- Missing even when the manifest requests them: `identity`, `offscreen`, `sidePanel`, `tabGroups`, `history`,
  `bookmarks`, `downloads`, `notifications`, `debugger`, `proxy`, `management`, `privacy`.
- `runtime.onInstalled` didn't reach the listener in this run. Barc reports the same and patches around it.
- `runtime.sendNativeMessage` exists, but WebKit passes it to the browser's own delegate, so the app has to
  implement any bridge to another app.

WebKit has no Chrome Web Store install flow. A browser has to fetch and unpack the package itself.

### Sign-in

`https://accounts.google.com/` loads its email screen with both the default and the Safari-style user agent.
Google's "This browser or app may not be secure" check comes after Next, and the spike didn't submit that form.

### Porting

`BrowserKit` builds for macOS, but only because `BrowserCore`'s web code sits inside `#if os(iOS)`. `Suggest`
and the models are portable. The session, web view host and pool code use UIKit and need porting, and the app
shell is 25 SwiftUI files built around the iPhone Duo.

## Apple's requirements for passkeys

From [Apple's entitlement page](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential):

- The request comes from the Account Holder of an organization's developer account, through the
  [macOS Browsers Passkeys form](https://developer.apple.com/contact/request/macos-browsers-passkeys/).
- The app declares `http` and `https`, offers a URL field, search or bookmarks at launch, and goes directly to
  the requested destination.
- Approval arrives as a managed capability, which then has to be in the app's provisioning profile.

Other browser projects report that the form also asks for a registered bundle ID and a link where Apple can
download the browser, and that a Developer ID build needs an embedded Developer ID profile. No project I found
records an approval or how long one takes.

`com.apple.developer.web-browser` is a different entitlement, and Apple's engineer named it for iOS passkeys.
Approval on iOS won't carry over to the Mac.

## Run it

```sh
./build.sh
(cd probe-page && python3 -m http.server 8765 --bind 127.0.0.1) &
open build/BrowsaMacSpike.app --args --url http://localhost:8765/
```

The sandbox can only read inside its container, so to load the probe extension, copy `probe-extension` to
`~/Library/Containers/com.orriginal.browsa.macspike/Data/Documents/` and pass its path with `--ext`.

## Still to test

- Google, Apple and Microsoft password sign-in past the first screen. Try a default and a Safari-style user
  agent: add `--ua default` or `--ua safari`, which is the default.
- Real extensions: uBlock Origin Lite, Bitwarden, 1Password. Barc reports Bitwarden failing in its build, and a
  cmux pull request reports it working with a Safari user agent.
- Whether Apple's Passwords app offers AutoFill inside a WKWebView browser on macOS.
