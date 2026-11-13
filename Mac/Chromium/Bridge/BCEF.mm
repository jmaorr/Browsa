#import "BCEF.h"

#include <cmath>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_version.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"
#include "include/wrapper/cef_library_loader.h"

// MARK: - NSApplication

@interface BCEFApplication () <CefAppProtocol>
@end

@implementation BCEFApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)handling { _handlingSendEvent = handling; }

- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

@end

// MARK: - Message pump

// CEF runs inside AppKit's run loop: it asks for work through OnScheduleMessagePumpWork and we
// call CefDoMessageLoopWork on the main thread, plus a steady timer as a backstop.
static NSTimer *gPumpTimer;
static bool gStarted = false;

static void PumpOnce() {
  if (gStarted) CefDoMessageLoopWork();
}

class BApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString &process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    // Keychain prompts for Chromium's own password store aren't wanted in a spike.
    command_line->AppendSwitch("use-mock-keychain");
    // getDisplayMedia: try macOS's own screen and window picker (ScreenCaptureKit's content sharing
    // picker), which Chromium can use on macOS 15 and later.
    command_line->AppendSwitchWithValue("enable-features", "UseSCContentSharingPicker");
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    double delay = delay_ms <= 0 ? 0 : delay_ms / 1000.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ PumpOnce(); });
  }

 private:
  IMPLEMENT_REFCOUNTING(BApp);
};

static CefScopedLibraryLoader *gLoader;
static CefRefPtr<BApp> gApp;

@implementation BCEFRuntime

+ (BOOL)startWithCachePath:(NSString *)cachePath {
  if (gStarted) return YES;
  gLoader = new CefScopedLibraryLoader();
  if (!gLoader->LoadInMain()) {
    NSLog(@"[cef] could not load the Chromium Embedded Framework");
    return NO;
  }
  NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
  std::vector<std::string> storage;
  for (NSString *a in arguments) storage.push_back(a.UTF8String);
  std::vector<char *> argv;
  for (auto &s : storage) argv.push_back(s.data());
  CefMainArgs mainArgs((int)argv.size(), argv.data());

  CefSettings settings;
  settings.no_sandbox = true;
  settings.external_message_pump = true;
  CefString(&settings.root_cache_path) = cachePath.UTF8String;
  CefString(&settings.cache_path) = [cachePath stringByAppendingPathComponent:@"Default"].UTF8String;
  NSString *helper = [[NSBundle.mainBundle.privateFrameworksPath
      stringByAppendingPathComponent:@"Browsa Helper.app/Contents/MacOS"]
      stringByAppendingPathComponent:@"Browsa Helper"];
  CefString(&settings.browser_subprocess_path) = helper.UTF8String;
  settings.log_severity = LOGSEVERITY_WARNING;

  gApp = new BApp();
  if (!CefInitialize(mainArgs, settings, gApp.get(), nullptr)) {
    NSLog(@"[cef] CefInitialize failed, exit code %d", CefGetExitCode());
    return NO;
  }
  gStarted = true;
  gPumpTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) { PumpOnce(); }];
  [[NSRunLoop mainRunLoop] addTimer:gPumpTimer forMode:NSEventTrackingRunLoopMode];
  return YES;
}

+ (void)shutdown {
  if (!gStarted) return;
  [gPumpTimer invalidate];
  gStarted = false;
  // Spike: tabs aren't closed before quitting, and CefShutdown with live browsers trips a CHECK.
  // The process is exiting anyway.
  delete gLoader;
  gLoader = nullptr;
}

+ (NSString *)version {
  return @CEF_VERSION;
}

@end

// MARK: - Browser

@class BCEFBrowser;

@interface BCEFBrowser ()
- (void)didCreate:(CefRefPtr<CefBrowser>)browser;
- (void)didClose;
@end

/// Resizes the Chromium view with ours: CEF adds it as a subview and leaves sizing to us.
@interface BCEFContainerView : NSView
@end

@implementation BCEFContainerView
- (BOOL)isFlipped { return YES; }
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  for (NSView *v in self.subviews) v.frame = self.bounds;
}
@end

static NSString *NS(const CefString &s) { return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @""; }

class BClient : public CefClient,
                public CefDisplayHandler,
                public CefLifeSpanHandler,
                public CefLoadHandler,
                public CefRequestHandler,
                public CefFindHandler,
                public CefPermissionHandler {
 public:
  explicit BClient(BCEFBrowser *owner) : owner_(owner) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

  // Permissions: Browsa asks (or remembers) and CEF hears back later, on the main thread, exactly once.
  // Camera and mic come twice: first as a permission prompt (the site asking), then as the media
  // request itself (the capture starting); both go to the same Browsa answer.
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString &origin,
                                      uint32_t requested, CefRefPtr<CefMediaAccessCallback> callback) override {
    BOOL audio = (requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) != 0;
    BOOL video = (requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) != 0;
    BOOL screen = (requested & (CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) != 0;
    CefRefPtr<CefMediaAccessCallback> cb = callback;
    NSString *o = NS(origin);
    dispatch_async(dispatch_get_main_queue(), ^{
      id<BCEFBrowserDelegate> d = owner_.delegate;
      if (!d) { cb->Cancel(); return; }
      [d browserRequestsMedia:o audio:audio video:video screen:screen decide:^(BOOL allowed) {
        dispatch_async(dispatch_get_main_queue(), ^{ allowed ? cb->Continue(requested) : cb->Cancel(); });
      }];
    });
    return true;
  }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString &origin, uint32_t requested,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    CefRefPtr<CefPermissionPromptCallback> cb = callback;
    NSString *o = NS(origin);
    BOOL audio = (requested & CEF_PERMISSION_TYPE_MIC_STREAM) != 0;
    BOOL video = (requested & CEF_PERMISSION_TYPE_CAMERA_STREAM) != 0;
    BOOL notify = (requested & CEF_PERMISSION_TYPE_NOTIFICATIONS) != 0;
    dispatch_async(dispatch_get_main_queue(), ^{
      id<BCEFBrowserDelegate> d = owner_.delegate;
      void (^answer)(BOOL) = ^(BOOL allowed) {
        dispatch_async(dispatch_get_main_queue(), ^{ cb->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY); });
      };
      if (!d) { answer(NO); return; }
      if (audio || video) [d browserRequestsMedia:o audio:audio video:video screen:NO decide:answer];
      else if (notify) [d browserRequestsNotifications:o decide:answer];
      else answer(NO);
    });
    return true;
  }

  // Display
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString &url) override {
    if (frame->IsMain()) [owner_.delegate browserAddressChanged:NS(url)];
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &title) override {
    [owner_.delegate browserTitleChanged:NS(title)];
  }
  void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
    [owner_.delegate browserProgressChanged:progress];
  }

  // Load
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading, bool canGoBack, bool canGoForward) override {
    [owner_.delegate browserLoadingChanged:isLoading canGoBack:canGoBack canGoForward:canGoForward];
  }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
    if (frame->IsMain()) [owner_.delegate browserLoadEnded:NS(frame->GetURL()) status:httpStatusCode];
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode errorCode, const CefString &errorText,
                   const CefString &failedUrl) override {
    if (frame->IsMain() && errorCode != ERR_ABORTED)
      [owner_.delegate browserLoadFailed:NS(failedUrl) code:errorCode text:NS(errorText)];
  }

  // Life span
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { [owner_ didCreate:browser]; }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override { [owner_ didClose]; }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString &target_url, const CefString &,
                     WindowOpenDisposition disposition, bool, const CefPopupFeatures &, CefWindowInfo &,
                     CefRefPtr<CefClient> &, CefBrowserSettings &, CefRefPtr<CefDictionaryValue> &, bool *) override {
    // Browsa has no popup windows: every new window becomes a tab.
    BOOL background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    [owner_.delegate browserWantsNewTab:NS(target_url) foreground:!background];
    return true;
  }

  // Request
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                      bool user_gesture, bool) override {
    if (!frame->IsMain()) return false;
    id<BCEFBrowserDelegate> d = owner_.delegate;
    return d ? ![d browserShouldNavigate:NS(request->GetURL()) userGesture:user_gesture] : false;
  }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString &target_url,
                        WindowOpenDisposition disposition, bool) override {
    if (disposition == CEF_WOD_CURRENT_TAB) return false;
    [owner_.delegate browserWantsNewTab:NS(target_url) foreground:disposition != CEF_WOD_NEW_BACKGROUND_TAB];
    return true;
  }

  // Find
  void OnFindResult(CefRefPtr<CefBrowser>, int, int count, const CefRect &, int activeMatchOrdinal,
                    bool finalUpdate) override {
    [owner_.delegate browserFindResult:count active:activeMatchOrdinal final:finalUpdate];
  }

 private:
  __weak BCEFBrowser *owner_;
  IMPLEMENT_REFCOUNTING(BClient);
};

/// Hands DevTools method results back to blocks waiting on them, by message id.
class BDevToolsObserver : public CefDevToolsMessageObserver {
 public:
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id, bool success, const void *result,
                              size_t result_size) override {
    NSNumber *key = @(message_id);
    void (^done)(NSData *) = waiting[key];
    if (!done) return;
    [waiting removeObjectForKey:key];
    done(success ? [NSData dataWithBytes:result length:result_size] : nil);
  }
  NSMutableDictionary<NSNumber *, void (^)(NSData *)> *waiting = [NSMutableDictionary dictionary];
  IMPLEMENT_REFCOUNTING(BDevToolsObserver);
};

static NSData *PNGFromScreenshotResult(NSData *json) {
  if (!json) return nil;
  NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
  NSString *b64 = [obj isKindOfClass:NSDictionary.class] ? obj[@"data"] : nil;
  return b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
}

@implementation BCEFBrowser {
  CefRefPtr<BDevToolsObserver> _devtools;
  CefRefPtr<CefRegistration> _devtoolsRegistration;
  int _nextMessageID;
  BCEFContainerView *_view;
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<BClient> _client;
  NSString *_pendingURL;
  double _pendingZoom;
  BOOL _closing;
}

- (instancetype)initWithURL:(NSString *)url incognito:(BOOL)incognito {
  if ((self = [super init])) {
    _view = [[BCEFContainerView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    _view.autoresizesSubviews = YES;
    _pendingZoom = 1;
    _client = new BClient(self);

    CefWindowInfo info;
    info.SetAsChild((__bridge CefWindowHandle)_view, CefRect(0, 0, 800, 600));
    CefBrowserSettings settings;
    CefRefPtr<CefRequestContext> context;
    if (incognito) {
      // No cache path: kept in memory and gone with the context.
      CefRequestContextSettings contextSettings;
      context = CefRequestContext::CreateContext(contextSettings, nullptr);
    }
    CefBrowserHost::CreateBrowser(info, _client, (url ?: @"about:blank").UTF8String, settings, nullptr, context);
  }
  return self;
}

- (NSView *)view { return _view; }

- (void)didCreate:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  for (NSView *v in _view.subviews) v.frame = _view.bounds;
  if (_pendingURL) { [self loadURL:_pendingURL]; _pendingURL = nil; }
  if (_pendingZoom != 1) self.zoomFactor = _pendingZoom;
  if (_closing) [self close];
}

- (void)didClose {
  _browser = nullptr;
  [self.delegate browserDidClose];
}

- (void)loadURL:(NSString *)url {
  if (!_browser) { _pendingURL = url; return; }
  _browser->GetMainFrame()->LoadURL(url.UTF8String);
}

- (void)reload { if (_browser) _browser->Reload(); }
- (void)reloadIgnoringCache { if (_browser) _browser->ReloadIgnoreCache(); }
- (void)stopLoading { if (_browser) _browser->StopLoad(); }
- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }

// Chromium zoom levels are steps of 20%: factor = 1.2 ^ level.
- (double)zoomFactor {
  if (!_browser) return _pendingZoom;
  return std::pow(1.2, _browser->GetHost()->GetZoomLevel());
}

- (void)setZoomFactor:(double)factor {
  if (!_browser) { _pendingZoom = factor; return; }
  _browser->GetHost()->SetZoomLevel(std::log(factor) / std::log(1.2));
}

- (void)find:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext {
  if (_browser) _browser->GetHost()->Find(text.UTF8String, forward, false, findNext);
}

- (void)stopFinding { if (_browser) _browser->GetHost()->StopFinding(true); }

- (void)executeJavaScript:(NSString *)code {
  if (_browser) _browser->GetMainFrame()->ExecuteJavaScript(code.UTF8String, "", 0);
}

- (void)captureScreenshot:(void (^)(NSData *_Nullable))completion {
  if (!_browser) { completion(nil); return; }
  if (!_devtools) {
    _devtools = new BDevToolsObserver();
    _devtoolsRegistration = _browser->GetHost()->AddDevToolsMessageObserver(_devtools);
  }
  int message = ++_nextMessageID;
  _devtools->waiting[@(message)] = [^(NSData *json) { completion(PNGFromScreenshotResult(json)); } copy];
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "png");
  if (_browser->GetHost()->ExecuteDevToolsMethod(message, "Page.captureScreenshot", params) == 0) {
    [_devtools->waiting removeObjectForKey:@(message)];
    completion(nil);
  }
}

- (void)devtools:(const char *)method params:(CefRefPtr<CefDictionaryValue>)params done:(void (^)(NSData *_Nullable))done {
  if (!_browser) { done(nil); return; }
  if (!_devtools) {
    _devtools = new BDevToolsObserver();
    _devtoolsRegistration = _browser->GetHost()->AddDevToolsMessageObserver(_devtools);
  }
  int message = ++_nextMessageID;
  _devtools->waiting[@(message)] = [done copy];
  if (_browser->GetHost()->ExecuteDevToolsMethod(message, method, params) == 0) {
    [_devtools->waiting removeObjectForKey:@(message)];
    done(nil);
  }
}

- (void)evaluate:(NSString *)expression completion:(void (^)(NSString *))completion {
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", expression.UTF8String);
  params->SetBool("awaitPromise", true);
  params->SetBool("returnByValue", true);
  [self devtools:"Runtime.evaluate" params:params done:^(NSData *json) {
    completion(json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil);
  }];
}

- (void)addScriptOnNewDocument:(NSString *)source {
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("source", source.UTF8String);
  [self devtools:"Page.addScriptToEvaluateOnNewDocument" params:params done:^(NSData *json) {
    NSLog(@"[cef-call] script registered: %@", json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"failed");
  }];
}

- (void)close {
  _closing = YES;
  if (_browser) _browser->GetHost()->CloseBrowser(true);
}

@end

// MARK: - Chrome-style window (spike)

class BChromeClient : public CefClient {
  IMPLEMENT_REFCOUNTING(BChromeClient);
};

class BChromeBrowserViewDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  IMPLEMENT_REFCOUNTING(BChromeBrowserViewDelegate);
};

class BChromeWindowDelegate : public CefWindowDelegate {
 public:
  explicit BChromeWindowDelegate(CefRefPtr<CefBrowserView> view) : view_(view) {}
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window->AddChildView(view_);
    window->Show();
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { view_ = nullptr; }
  bool CanClose(CefRefPtr<CefWindow>) override { return true; }
  CefSize GetPreferredSize(CefRefPtr<CefView>) override { return CefSize(1280, 860); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }

 private:
  CefRefPtr<CefBrowserView> view_;
  IMPLEMENT_REFCOUNTING(BChromeWindowDelegate);
};

@implementation BCEFChromeWindow {
  CefRefPtr<CefBrowserView> _view;
  CefRefPtr<CefWindow> _window;
  CefRefPtr<BDevToolsObserver> _devtools;
  CefRefPtr<CefRegistration> _registration;
  int _next;
}

- (instancetype)initWithURL:(NSString *)url {
  if ((self = [super init])) {
    CefBrowserSettings settings;
    _view = CefBrowserView::CreateBrowserView(new BChromeClient(), url.UTF8String, settings, nullptr, nullptr,
                                             new BChromeBrowserViewDelegate());
    _window = CefWindow::CreateTopLevelWindow(new BChromeWindowDelegate(_view));
  }
  return self;
}

- (CefRefPtr<CefBrowser>)browser { return _view ? _view->GetBrowser() : nullptr; }

- (void)loadURL:(NSString *)url {
  if (auto b = [self browser]) b->GetMainFrame()->LoadURL(url.UTF8String);
}

- (void)send:(const char *)method params:(CefRefPtr<CefDictionaryValue>)params done:(void (^)(NSData *))done {
  auto b = [self browser];
  if (!b) { done(nil); return; }
  if (!_devtools) {
    _devtools = new BDevToolsObserver();
    _registration = b->GetHost()->AddDevToolsMessageObserver(_devtools);
  }
  int message = ++_next;
  _devtools->waiting[@(message)] = [done copy];
  if (b->GetHost()->ExecuteDevToolsMethod(message, method, params) == 0) {
    [_devtools->waiting removeObjectForKey:@(message)];
    done(nil);
  }
}

- (void)captureScreenshot:(void (^)(NSData *))completion {
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "png");
  [self send:"Page.captureScreenshot" params:params done:^(NSData *json) { completion(PNGFromScreenshotResult(json)); }];
}

- (void)evaluate:(NSString *)expression completion:(void (^)(NSString *))completion {
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", expression.UTF8String);
  params->SetBool("awaitPromise", true);
  params->SetBool("returnByValue", true);
  [self send:"Runtime.evaluate" params:params done:^(NSData *json) {
    completion(json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil);
  }];
}

- (void)close {
  if (_window) _window->Close();
  _window = nullptr;
}

@end
