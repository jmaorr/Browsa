// Browsa's main executable when Browsa ships with its own WebKit inside the app (Spike/CallAudio/webkit/BUNDLING.md).
// It decides, before anything else loads, which of two real executables to run in this same process:
//   Contents/MacOS/Browsa-webkit   linked with LC_DYLD_ENVIRONMENT -> Contents/Frameworks (the bundled WebKit)
//   Contents/MacOS/Browsa-system   the same app without it (Apple's WebKit)
// Both are signed normally with the app's identity and entitlements, so neither needs a Hardened Runtime exception,
// and exec keeps the process (camera and mic stay Browsa's; the launch's Apple events reach the new image, since
// nothing here checks in with macOS).
//
// The bundled WebKit is used when it's there, Settings hasn't switched it off (defaults key patchedWebKit), and the
// running macOS is within the range in Contents/Resources/BrowsaWebKitOS.txt ("<minimum version> <highest major>",
// e.g. "26.7 26"): it's built against one macOS and its private frameworks. BROWSA_OS_VERSION_OVERRIDE pretends to be
// another macOS (tests). The choice goes to the app as BROWSA_BUNDLED_WEBKIT=<used|old-os|new-os|off|missing>.
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
    snprintf(path, sizeof(path), "%s/Frameworks/WebKit.framework/Versions/A/WebKit", contents);
    struct stat st;
    if (stat(path, &st)) reason = "missing";

    if (!strcmp(reason, "used")) {
        CFStringRef bundle = CFStringCreateWithCString(NULL, "com.orriginal.browsa", kCFStringEncodingUTF8);
        CFBundleRef main = CFBundleGetMainBundle();
        if (main && CFBundleGetIdentifier(main)) { CFRelease(bundle); bundle = (CFStringRef)CFRetain(CFBundleGetIdentifier(main)); }
        CFPropertyListRef on = CFPreferencesCopyAppValue(CFSTR("patchedWebKit"), bundle);
        if (on && CFGetTypeID(on) == CFBooleanGetTypeID() && !CFBooleanGetValue((CFBooleanRef)on)) reason = "off";
        if (on) CFRelease(on);
        CFRelease(bundle);
        const char* env = getenv("BROWSA_PATCHED_WEBKIT");
        if (env && !strcmp(env, "0")) reason = "off";
    }

    if (!strcmp(reason, "used")) {
        char os[64] = "", minimum[64] = "0", top[16] = "999";
        const char* override = getenv("BROWSA_OS_VERSION_OVERRIDE");
        if (override) strlcpy(os, override, sizeof(os));
        else { size_t n = sizeof(os); sysctlbyname("kern.osproductversion", os, &n, NULL, 0); }
        snprintf(path, sizeof(path), "%s/Resources/BrowsaWebKitOS.txt", contents);
        FILE* f = fopen(path, "r");
        if (f) { if (fscanf(f, "%63s %15s", minimum, top) < 1) strlcpy(minimum, "999", sizeof(minimum)); fclose(f); }
        else strlcpy(minimum, "999", sizeof(minimum));  // no range given: don't guess
        if (version_cmp(os, minimum) < 0) reason = "old-os";
        else if (atol(os) > atol(top)) reason = "new-os";
    }

    setenv("BROWSA_BUNDLED_WEBKIT", reason, 1);
    snprintf(path, sizeof(path), "%s/%s", macos, strcmp(reason, "used") ? "Browsa-system" : "Browsa-webkit");
    execv(path, argv);
    // The chosen one is missing: try the other before giving up.
    snprintf(path, sizeof(path), "%s/Browsa-system", macos);
    execv(path, argv);
    perror("Browsa");
    return 1;
}
