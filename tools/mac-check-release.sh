#!/bin/zsh
# Checks a Browsa.app the way a release has to be (tools/release-mac.sh runs it on every release):
#   tools/mac-check-release.sh <Browsa.app> [--any-identity]
# - signature valid (codesign --verify --deep --strict), Developer ID unless --any-identity
# - every executable hardened, none with a local-only exception (allow-dyld-environment-variables,
#   disable-library-validation, get-task-allow); only WebKit's WebContent service may JIT
# - no call recording: no "Record calls for tuning" in the app, no dump code in any bundled WebCore
# - no Chromium (CEF and its helpers went with 1954f68)
# - with a bundled WebKit: the launcher, Browsa-system and a Browsa-webkit-<major> per Frameworks/WebKit-<major>
# Gatekeeper's verdict is printed too: before notarisation it says "Unnotarized Developer ID", which is expected.
set -euo pipefail
app="${1:?usage: mac-check-release.sh <Browsa.app> [--any-identity]}"
any_identity=0; [[ "${2:-}" == --any-identity ]] && any_identity=1
fail=0
bad() { echo "FAIL $*" >&2; fail=1; }
ok() { echo "ok   $*"; }

codesign --verify --deep --strict "$app" 2>/dev/null && ok "signature verifies (deep, strict)" || bad "codesign --verify --deep --strict"
authority=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if [[ "$authority" == "Developer ID Application:"* ]]; then ok "signed: $authority"
elif (( any_identity )); then ok "signed: $authority (not Developer ID, allowed here)"
else bad "signed with $authority, not Developer ID"; fi

# Every Mach-O executable in the bundle.
executables=()
while IFS= read -r -d '' f; do
  kind=$(file -b "$f")
  [[ "$kind" == *Mach-O* && "$kind" == *executable* ]] && executables+=("$f")
done < <(find "$app" -type f -perm -u+x -print0)
for exe in $executables; do
  rel="${exe#$app/}"
  info=$(codesign -dv --verbose=2 "$exe" 2>&1 || true)
  ents=$(codesign -d --entitlements - --xml "$exe" 2>/dev/null || true)
  [[ "$info" == *"(runtime)"* ]] || bad "$rel: no Hardened Runtime"
  exe_authority=$(sed -n 's/^Authority=//p' <<< "$info" | head -1)
  [[ "$exe_authority" == "$authority" ]] || bad "$rel: signed by ${exe_authority:-nobody}, not $authority"
  for key in allow-dyld-environment-variables disable-library-validation get-task-allow allow-unsigned-executable-memory; do
    [[ "$ents" == *"$key"* ]] && bad "$rel: has $key"
  done
  if [[ "$ents" == *"allow-jit"* && "$rel" != *"com.apple.WebKit.WebContent.xpc"* ]]; then bad "$rel: has allow-jit"; fi
done
ok "${#executables} executables checked for Hardened Runtime and entitlements"
for wc in "$app"/Contents/Frameworks/WebKit-*/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc(N); do
  (( $(codesign -d --entitlements - --xml "$wc" 2>/dev/null | grep -c allow-jit || true) > 0 )) && ok "${wc#$app/}: allow-jit kept" || bad "${wc#$app/}: lost allow-jit"
done

for exe in "$app"/Contents/MacOS/*; do
  grep -q "Record calls for tuning" "$exe" && bad "${exe#$app/}: has call recording"
  grep -q "recordCallsForTuning" "$exe" && bad "${exe#$app/}: reads the call recording setting"
done
ok "no call recording in the app's executables"
for wc in "$app"/Contents/Frameworks/WebKit-*/WebCore.framework/Versions/A/WebCore(N); do
  (( $(strings -a "$wc" | grep -c BROWSA_CALL_AUDIO_DUMP || true) == 0 )) && ok "${wc#$app/}: no call dump code" || bad "${wc#$app/}: has call dump code"
done
[[ -z "$(find "$app" -iname '*Chromium*' -o -iname 'Browsa Helper*' | head -1)" ]] && ok "no Chromium" || bad "Chromium is in the app"

majors=("$app"/Contents/Frameworks/WebKit-*(N))
if (( ${#majors} )); then
  [[ -x "$app/Contents/MacOS/Browsa-system" ]] || bad "bundled WebKit but no Browsa-system"
  for m in $majors; do
    major="${m##*WebKit-}"
    exe="$app/Contents/MacOS/Browsa-webkit-$major"
    [[ -x "$exe" ]] || { bad "no Browsa-webkit-$major"; continue; }
    (( $(otool -l "$exe" | grep -c "DYLD_FRAMEWORK_PATH=@executable_path/../Frameworks/WebKit-$major" || true) > 0 )) && ok "Browsa-webkit-$major points at WebKit-$major" || bad "Browsa-webkit-$major doesn't point at WebKit-$major"
    echo "     WebKit-$major: $(cat "$app/Contents/Resources/BROWSA_WEBKIT-$major.txt" 2>/dev/null || echo 'no label'), $(du -sh "$m" | cut -f1)"
  done
else
  echo "     no bundled WebKit (Apple's WebKit everywhere)"
fi

echo "     Gatekeeper: $(spctl --assess --type execute -vv "$app" 2>&1 | tr '\n' ' ')"
echo "     size on disk: $(du -sh "$app" | cut -f1)"
(( fail == 0 )) && echo "release checks passed: $app" || { echo "release checks FAILED: $app" >&2; exit 1; }
