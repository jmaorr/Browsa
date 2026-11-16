// Browsa's main executable when Browsa ships with its own WebKit inside the app (Spike/CallAudio/webkit/BUNDLING.md).
// It decides, before anything else loads, which real executable to run in this same process:
//   Contents/MacOS/Browsa-webkit-<major>  linked with LC_DYLD_ENVIRONMENT -> Contents/Frameworks/WebKit-<major>, the
//                                         WebKit built for that macOS major (one per supported major: 26, 27, ...)
//   Contents/MacOS/Browsa-webkit          the single-build layout: -> Contents/Frameworks
//   Contents/MacOS/Browsa-system          the same app without it (Apple's WebKit)
// Both are signed normally with the app's identity and entitlements, so neither needs a Hardened Runtime exception,
// and exec keeps the process (camera and mic stay Browsa's; the launch's Apple events reach the new image, since
// nothing here checks in with macOS).
//
// A bundled WebKit is used when Settings hasn't switched it off (defaults key patchedWebKit) and there is one for the
// running macOS major: Contents/Frameworks/WebKit-<major> with Browsa-webkit-<major> (its minimum version, if not
// <major>.0, in Contents/Resources/WebKit-<major>.minimum), or the single-build layout described by
// Contents/Resources/BrowsaWebKitOS.txt ("<minimum version> <highest major>", e.g. "26.0 26"). Each is built against
// one macOS major and its private frameworks. BROWSA_OS_VERSION_OVERRIDE pretends to be another macOS (tests). The
// choice goes to the app as BROWSA_BUNDLED_WEBKIT=<used|old-os|new-os|off|missing>.
#include <CoreFoundation/CoreFoundation.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static int version_cmp(const char* a, const char* b) {
    for (;;) {
        long x = strtol(a, (char**)&a, 10), y = strtol(b, (char**)&b, 10);
        if (x != y) return x < y ? -1 : 1;
        if (*a != '.' && *b != '.') return 0;
        if (*a == '.') a++;
        if (*b == '.') b++;
    }
}

int main(int argc, char* argv[]) {
    (void)argc;
    char self[PATH_MAX], real[PATH_MAX];
    uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size) || !realpath(self, real)) return 1;
    char macos[PATH_MAX], contents[PATH_MAX], path[PATH_MAX];
    strlcpy(macos, dirname(real), sizeof(macos));
    snprintf(contents, sizeof(contents), "%s/..", macos);

    const char* reason = "used";
    char chosen[PATH_MAX] = "Browsa-webkit";
    struct stat st;

    CFStringRef bundle = CFStringCreateWithCString(NULL, "com.orriginal.browsa", kCFStringEncodingUTF8);
    CFBundleRef main = CFBundleGetMainBundle();
    if (main && CFBundleGetIdentifier(main)) { CFRelease(bundle); bundle = (CFStringRef)CFRetain(CFBundleGetIdentifier(main)); }
    CFPropertyListRef on = CFPreferencesCopyAppValue(CFSTR("patchedWebKit"), bundle);
    if (on && CFGetTypeID(on) == CFBooleanGetTypeID() && !CFBooleanGetValue((CFBooleanRef)on)) reason = "off";
    if (on) CFRelease(on);
#ifdef BROWSA_CALL_RECORDING
    // Development builds: Settings › Audio › Record calls for tuning makes the capture unit record each call (WebKit's
    // services only get __XPC_ variables that were there when this process started, so it has to be set here).
    CFPropertyListRef record = CFPreferencesCopyAppValue(CFSTR("recordCallsForTuning"), bundle);
    if (record && CFGetTypeID(record) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)record)) {
        setenv("__XPC_BROWSA_CALL_AUDIO_DUMP", "1", 1);
        setenv("__XPC_BROWSA_CALL_AUDIO_DUMP_MINUTES", "30", 1);
    }
    if (record) CFRelease(record);
#else
    // Release builds: no recording, whatever the environment held when Browsa was opened.
    unsetenv("BROWSA_CALL_AUDIO_DUMP");
    unsetenv("BROWSA_CALL_AUDIO_DUMP_MINUTES");
    unsetenv("__XPC_BROWSA_CALL_AUDIO_DUMP");
    unsetenv("__XPC_BROWSA_CALL_AUDIO_DUMP_MINUTES");
#endif
    CFRelease(bundle);
    const char* env = getenv("BROWSA_PATCHED_WEBKIT");
    if (env && !strcmp(env, "0")) reason = "off";

    char os[64] = "";
    const char* override = getenv("BROWSA_OS_VERSION_OVERRIDE");
    if (override) strlcpy(os, override, sizeof(os));
    else { size_t n = sizeof(os); sysctlbyname("kern.osproductversion", os, &n, NULL, 0); }
    const long major = atol(os);

    if (!strcmp(reason, "used")) {
        // One build per macOS major: WebKit-<major>.
        snprintf(path, sizeof(path), "%s/Frameworks/WebKit-%ld/WebKit.framework/Versions/A/WebKit", contents, major);
        if (!stat(path, &st)) {
            char minimum[64];
            snprintf(minimum, sizeof(minimum), "%ld.0", major);
            snprintf(path, sizeof(path), "%s/Resources/WebKit-%ld.minimum", contents, major);
            FILE* f = fopen(path, "r");
            if (f) { if (fscanf(f, "%63s", minimum) != 1) snprintf(minimum, sizeof(minimum), "%ld.0", major); fclose(f); }
            if (version_cmp(os, minimum) < 0) reason = "old-os";
            snprintf(chosen, sizeof(chosen), "Browsa-webkit-%ld", major);
        } else {
            // The single-build layout.
            snprintf(path, sizeof(path), "%s/Frameworks/WebKit.framework/Versions/A/WebKit", contents);
            if (stat(path, &st)) {
                // No build for this major: newer than any we have, or older.
                reason = "missing";
                for (long m = major + 1; m < major + 10; m++) {
                    snprintf(path, sizeof(path), "%s/Frameworks/WebKit-%ld", contents, m);
                    if (!stat(path, &st)) { reason = "old-os"; break; }
                }
                for (long m = major - 1; m > major - 10 && !strcmp(reason, "missing"); m--) {
                    snprintf(path, sizeof(path), "%s/Frameworks/WebKit-%ld", contents, m);
                    if (!stat(path, &st)) reason = "new-os";
                }
            } else {
                char minimum[64] = "0", top[16] = "999";
                snprintf(path, sizeof(path), "%s/Resources/BrowsaWebKitOS.txt", contents);
                FILE* f = fopen(path, "r");
                if (f) { if (fscanf(f, "%63s %15s", minimum, top) < 1) strlcpy(minimum, "999", sizeof(minimum)); fclose(f); }
                else strlcpy(minimum, "999", sizeof(minimum));  // no range given: don't guess
                if (version_cmp(os, minimum) < 0) reason = "old-os";
                else if (major > atol(top)) reason = "new-os";
            }
        }
    }

    setenv("BROWSA_BUNDLED_WEBKIT", reason, 1);
    snprintf(path, sizeof(path), "%s/%s", macos, strcmp(reason, "used") ? "Browsa-system" : chosen);
    execv(path, argv);
    // The chosen one is missing: try the other before giving up.
    snprintf(path, sizeof(path), "%s/Browsa-system", macos);
    execv(path, argv);
    perror("Browsa");
    return 1;
}
