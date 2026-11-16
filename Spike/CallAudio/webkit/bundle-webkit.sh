#!/bin/zsh
# Feasibility: puts a Browsa WebKit build INSIDE a Browsa app bundle, so it runs on it with no launcher, no environment
# variables and no Hardened Runtime exceptions. The app has to be linked with
#   OTHER_LDFLAGS = $(inherited) -Wl,-dyld_env,DYLD_FRAMEWORK_PATH=@executable_path/../Frameworks
#                   -Wl,-dyld_env,DYLD_LIBRARY_PATH=@executable_path/../Frameworks
# (LC_DYLD_ENVIRONMENT: part of the signed executable, read by dyld before anything loads; if a framework isn't in
# Contents/Frameworks dyld uses the system's, so removing the bundled WebKit falls back by itself).
#
#   bundle-webkit.sh <app> <webkit build folder> [signing identity] [--no-inspector]
#   BUNDLE_MAJOR=26 bundle-webkit.sh ...   puts it in Contents/Frameworks/WebKit-26 (one build per macOS major; the app's
#                                          Browsa-webkit-26 executable is linked with -dyld_env ...=@executable_path/../Frameworks/WebKit-26),
#                                          its label in Resources/BROWSA_WEBKIT-26.txt and, with BUNDLE_MINIMUM_OS=26.0,
#                                          Resources/WebKit-26.minimum
#   BUNDLE_STRIP=1          strips local symbols from every bundled binary (release: keep the build's dSYMs instead)
#   BUNDLE_SKIP_APP_SIGN=1  leaves the app itself unsigned (tools/mac-bundle-webkit.sh signs it once at the end)
#
# WebKit's XPC services (GPU, Networking, WebContent) become real copies in WebKit.framework/Versions/A/XPCServices;
# their own LC_DYLD_ENVIRONMENT is rewritten for that place (set-dyld-env.py). Headers, modules and test frameworks
# are left out. Everything is signed inside out with Hardened Runtime and a timestamp where the identity allows.
set -euo pipefail
here="${0:A:h}"
app="${1:?app}"; fw="${2:?webkit build folder}"; identity="${3:-Apple Development}"
inspector=1; [[ "${4:-}" == --no-inspector ]] && inspector=0
major="${BUNDLE_MAJOR:-}"
dest="$app/Contents/Frameworks${major:+/WebKit-$major}"
mkdir -p "$dest"

frameworks=(JavaScriptCore WebCore WebGPU WebKit WebKitLegacy _WebKit_SwiftUI)
(( inspector )) && frameworks+=(WebInspectorUI)
for f in $frameworks; do
  rm -rf "$dest/$f.framework"
  cp -cR "$fw/$f.framework" "$dest/"
  # Build-time only.
  rm -rf "$dest/$f.framework/Headers" "$dest/$f.framework/PrivateHeaders" "$dest/$f.framework/Modules" \
         "$dest/$f.framework/Versions/A/Headers" "$dest/$f.framework/Versions/A/PrivateHeaders" "$dest/$f.framework/Versions/A/Modules"
done
# JavaScriptCore's jsc shell is a developer tool, not part of the engine.
rm -rf "$dest/JavaScriptCore.framework/Versions/A/Helpers" "$dest/JavaScriptCore.framework/Helpers"
for f in libwebrtc.dylib libANGLE-shared.dylib; do cp -c "$fw/$f" "$dest/$f"; done
# Only code goes in Frameworks. ANGLE's shaders are compiled into libANGLE and the media quirk scripts into WebCore,
# so the loose .metallib / .js files in the build folder aren't needed. The build's label goes with the resources.
rm -f "$dest"/{ANGLEMetalLib.metallib,CNNCaptionQuirk.js,YouTubeCaptionQuirk.js,minidom.js,BROWSA_WEBKIT.txt}
[[ -e "$fw/BROWSA_WEBKIT.txt" ]] && cp "$fw/BROWSA_WEBKIT.txt" "$app/Contents/Resources/BROWSA_WEBKIT${major:+-$major}.txt"
[[ -n "$major" && -n "${BUNDLE_MINIMUM_OS:-}" ]] && echo "$BUNDLE_MINIMUM_OS" > "$app/Contents/Resources/WebKit-$major.minimum"

# Real XPC services inside WebKit.framework (the build has symlinks to the top-level ones).
xpcdir="$dest/WebKit.framework/Versions/A/XPCServices"
rm -rf "$xpcdir"; mkdir -p "$xpcdir"
for s in GPU Networking WebContent; do
  cp -cR "$fw/com.apple.WebKit.$s.xpc" "$xpcdir/"
  exe=$(ls "$xpcdir/com.apple.WebKit.$s.xpc/Contents/MacOS/"* | head -1)
  # MacOS -> Contents -> X.xpc -> XPCServices -> A -> Versions -> WebKit.framework -> Frameworks
  python3 "$here/set-dyld-env.py" "$exe" "DYLD_FRAMEWORK_PATH=@executable_path/../../../../../../.." "DYLD_LIBRARY_PATH=@executable_path/../../../../../../.."
done
rm -f "$dest/WebKit.framework/XPCServices"
ln -s Versions/Current/XPCServices "$dest/WebKit.framework/XPCServices"

# Xcode's export refuses a bundle whose Info.plist names no platform (WebKitLegacy's says [""]).
for plist in "$dest"/*.framework/Versions/A/Resources/Info.plist "$xpcdir"/*.xpc/Contents/Info.plist; do
  platforms=$(plutil -extract CFBundleSupportedPlatforms json -o - "$plist" 2>/dev/null || echo none)
  if [[ "$platforms" != *MacOSX* && "$platforms" != *macosx* ]]; then
    plutil -replace CFBundleSupportedPlatforms -json '["MacOSX"]' "$plist"
    plutil -replace DTPlatformName -string macosx "$plist"
  fi
done

if [[ "${BUNDLE_STRIP:-}" == 1 ]]; then
  for f in $frameworks; do strip -x "$dest/$f.framework/Versions/A/$f"; done
  for f in libwebrtc.dylib libANGLE-shared.dylib; do strip -x "$dest/$f"; done
  for s in GPU Networking WebContent; do strip -x "$xpcdir/com.apple.WebKit.$s.xpc/Contents/MacOS/"*; done
fi

# Signing, inside out. Helpers keep only what they need: WebContent JITs.
ts=(--timestamp); [[ "$identity" == "Apple Development"* || "$identity" == "-" ]] && ts=(--timestamp=none)
sign() { codesign --force --options runtime $ts --sign "$identity" "$@"; }
ents="$(mktemp -d)"
cat > "$ents/webcontent.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.allow-jit</key><true/></dict></plist>
P
for s in GPU Networking; do sign "$xpcdir/com.apple.WebKit.$s.xpc"; done
sign --entitlements "$ents/webcontent.plist" "$xpcdir/com.apple.WebKit.WebContent.xpc"
for f in libwebrtc.dylib libANGLE-shared.dylib; do [[ -e "$dest/$f" ]] && sign "$dest/$f"; done
for f in $frameworks; do sign "$dest/$f.framework"; done
if [[ "${BUNDLE_SKIP_APP_SIGN:-}" == 1 ]]; then rm -rf "$ents"; du -sh "$dest" | sed 's/^/size /'; exit 0; fi
# The app last, with the entitlements it was built with.
appents="$ents/app.plist"
codesign -d --entitlements - --xml "$app" > "$appents" 2>/dev/null
sign --entitlements "$appents" "$app"
codesign --verify --deep --strict "$app" && echo "signed and verified: $app"
rm -rf "$ents"
du -sh "$dest" "$app" | sed 's/^/size /'
