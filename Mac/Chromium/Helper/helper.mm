// The Chromium helper process (renderer, GPU, network, plugins): one binary, copied into the
// "Browsa Chromium Helper (GPU).app" etc. bundles CEF looks for next to its framework.

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char *argv[]) {
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  CefMainArgs args(argc, argv);
  return CefExecuteProcess(args, nullptr, nullptr);
}
