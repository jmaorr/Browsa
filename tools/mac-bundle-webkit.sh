#!/bin/zsh
# Puts Browsa's own WebKit builds inside a built Browsa.app (the release path: tools/release-mac.sh calls this on the
# archived app before the Developer ID export). See Spike/CallAudio/webkit/BUNDLING.md.
#
#   tools/mac-bundle-webkit.sh <Browsa.app> <signing identity> <major>=<webkit build folder> [...]
#   e.g. tools/mac-bundle-webkit.sh Browsa.app "Apple Development" 26=~/Developer/BrowsaWebKit-release/WebKitBuild-release-26.0/Release
#
# Afterwards the app's executables are:
#   Contents/MacOS/Browsa                 the launcher (Spike/CallAudio/webkit/launcher/main.c), universal: picks one of
#   Contents/MacOS/Browsa-webkit-<major>  the app, arm64, with LC_DYLD_ENVIRONMENT -> Contents/Frameworks/WebKit-<major>
#   Contents/MacOS/Browsa-system          the app as built (Apple's WebKit: other majors, Intel, or switched off)
# and each WebKit sits in Contents/Frameworks/WebKit-<major>, stripped (its dSYMs go next to the app, in
# <app>/../dSYMs/WebKit-<major>, for the archive). Every executable carries the app's identifier, entitlements and
# Hardened Runtime and no exception entitlement; WebKit's WebContent service gets allow-jit, nothing else.
#
# Refuses a WebKit with the call dump compiled in (BrowsaCallAudioRecording.h) or labelled anything but "release",
# an app signed with local-only entitlements, and a call-recording build of the app.
set -euo pipefail
repo="${0:A:h:h}"
webkit_dir="$repo/Spike/CallAudio/webkit"
app="${1:?usage: mac-bundle-webkit.sh <Browsa.app> <identity> <major>=<webkit build folder> ...}"
identity="${2:?identity}"
shift 2
(( $# )) || { echo "no WebKit builds given" >&2; exit 1; }
app="${app:A}"
macos="$app/Contents/MacOS"
exe_name=$(defaults read "$app/Contents/Info.plist" CFBundleExecutable)
bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier)
[[ -f "$macos/$exe_name" && ! -e "$macos/Browsa-system" ]] || { echo "$app isn't a freshly built Browsa (already bundled?)" >&2; exit 1; }

# What the app was signed with, before anything is changed: its entitlements go on every executable.
ents=$(mktemp -d)
trap 'rm -rf "$ents"' EXIT
codesign -d --entitlements - --xml "$macos/$exe_name" > "$ents/app.plist" 2>/dev/null
for key in com.apple.security.cs.allow-dyld-environment-variables com.apple.security.cs.disable-library-validation com.apple.security.get-task-allow; do
  grep -q "$key" "$ents/app.plist" && { echo "the app is signed with $key: not a release build" >&2; exit 1; }
done
grep -q "Record calls for tuning" "$macos/$exe_name" && { echo "the app has call recording compiled in: not a release build" >&2; exit 1; }

for spec in "$@"; do
  major="${spec%%=*}"; fw="${${spec#*=}:A}"
  [[ "$major" =~ '^[0-9]+$' && -d "$fw/WebKit.framework" ]] || { echo "bad WebKit build: $spec" >&2; exit 1; }
  grep -q "^release $major.0 " "$fw/BROWSA_WEBKIT.txt" 2>/dev/null || { echo "$fw isn't a release build for macOS $major (Spike/CallAudio/webkit/build-release-webkit.sh)" >&2; exit 1; }
  (( $(strings "$fw/WebCore.framework/Versions/A/WebCore" | grep -c BROWSA_CALL_AUDIO_DUMP || true) == 0 )) || { echo "$fw has the call dump compiled in" >&2; exit 1; }
done

echo "==> Executables"
mv "$macos/$exe_name" "$macos/Browsa-system"
for spec in "$@"; do
  major="${spec%%=*}"
  # The bundled WebKit is Apple silicon only, so this executable is too.
  if lipo -info "$macos/Browsa-system" | grep -q "^Non-fat"; then cp "$macos/Browsa-system" "$macos/Browsa-webkit-$major"
  else lipo -thin arm64 "$macos/Browsa-system" -output "$macos/Browsa-webkit-$major"; fi
  python3 "$webkit_dir/set-dyld-env.py" "$macos/Browsa-webkit-$major" \
    "DYLD_FRAMEWORK_PATH=@executable_path/../Frameworks/WebKit-$major" "DYLD_LIBRARY_PATH=@executable_path/../Frameworks/WebKit-$major" >/dev/null
done
minos=$(otool -l "$macos/Browsa-system" | awk '/LC_BUILD_VERSION/ {f=1} f && /minos/ {print $2; exit}')
# Release: no -DBROWSA_CALL_RECORDING, so the launcher strips any call dump request.
clang -O2 -arch arm64 -arch x86_64 -mmacosx-version-min="$minos" -framework CoreFoundation \
  "$webkit_dir/launcher/main.c" -o "$macos/$exe_name"

echo "==> WebKit"
for spec in "$@"; do
  major="${spec%%=*}"; fw="${${spec#*=}:A}"
  BUNDLE_MAJOR="$major" BUNDLE_MINIMUM_OS="$major.0" BUNDLE_STRIP=1 BUNDLE_SKIP_APP_SIGN=1 \
    "$webkit_dir/bundle-webkit.sh" "$app" "$fw" "$identity"
  mkdir -p "${app:h}/dSYMs/WebKit-$major"
  for d in "$fw"/{JavaScriptCore,WebCore,WebGPU,WebKit,WebKitLegacy,_WebKit_SwiftUI,WebInspectorUI}.framework.dSYM \
           "$fw"/libwebrtc.dylib.dSYM "$fw"/libANGLE-shared.dylib.dSYM "$fw"/com.apple.WebKit.{GPU,Networking,WebContent}.xpc.dSYM; do
    [[ -d "$d" ]] && cp -cR "$d" "${app:h}/dSYMs/WebKit-$major/"
  done
done

echo "==> Signing the app"
ts=(--timestamp); [[ "$identity" == "Apple Development"* || "$identity" == "-" ]] && ts=(--timestamp=none)
sign() { codesign --force --options runtime $ts --sign "$identity" --identifier "$bundle_id" --entitlements "$ents/app.plist" "$@"; }
for exe in "$macos"/Browsa-webkit-* "$macos/Browsa-system"; do sign "$exe"; done
sign "$app"
codesign --verify --deep --strict "$app"
echo "==> $app: $(du -sh "$app" | cut -f1)"
