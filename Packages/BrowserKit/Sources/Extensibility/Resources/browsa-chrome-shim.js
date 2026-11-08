// Browsa's Chrome compatibility layer for WebKit (see ChromeCompatibility.swift).
//
// Browsa puts this file in front of a store extension's background script and pages.
//
// Deliberately small. An earlier version wrapped `chrome` and `browser` in a Proxy to stand in for
// APIs WebKit lacks, but WebKit stops delivering runtime messages to a background whose API object
// is wrapped (found in the 1Password spike, Nov 2026), and WebKit's API objects ignore new
// properties, so there is no safe way to add missing ones from script. Gaps are handled natively
// instead, in WebKitExtensions.
(() => {
  if (globalThis.__browsaShim) return;
  globalThis.__browsaShim = true;
  // Firefox-style extensions only define `browser`; Chrome-style code looks for `chrome`.
  if (!globalThis.chrome && globalThis.browser) {
    try { globalThis.chrome = globalThis.browser; } catch (e) {}
  }
})();
