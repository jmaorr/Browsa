// Starts Browsa again on its own WebKit before main() (see PatchedWebKit.swift). It has to be this early: once the
// app has checked in with macOS, the "open a window" and "open this link" messages it gets at launch belong to
// this program image, and starting again after that loses them (the app came up with no window and no tab).
extern void BrowsaPatchedWebKitRelaunch(void);

__attribute__((constructor)) static void browsaPatchedWebKitStart(void) {
    BrowsaPatchedWebKitRelaunch();
}
