// Objective-C face of the Chromium Embedded Framework, for ChromiumEngine (Swift).
// Everything here runs on the main thread, which is CEF's UI thread on the Mac.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The app's NSApplication. CEF needs its event dispatch to be observable (CefAppProtocol).
@interface BCEFApplication : NSApplication
@end

/// Starting and stopping CEF for the whole app.
NS_SWIFT_UI_ACTOR
@interface BCEFRuntime : NSObject
/// Loads the framework and calls CefInitialize. `cachePath` holds cookies and site data.
+ (BOOL)startWithCachePath:(NSString *)cachePath;
+ (void)shutdown;
+ (NSString *)version;
@end

NS_SWIFT_UI_ACTOR
@protocol BCEFBrowserDelegate <NSObject>
- (void)browserAddressChanged:(NSString *)url;
- (void)browserTitleChanged:(NSString *)title;
- (void)browserProgressChanged:(double)progress;
- (void)browserLoadingChanged:(BOOL)loading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)browserLoadEnded:(NSString *)url status:(int)status;
- (void)browserLoadFailed:(NSString *)url code:(int)code text:(NSString *)text;
/// A link or window.open wants a new tab. Chromium's own popup window is cancelled.
- (void)browserWantsNewTab:(NSString *)url foreground:(BOOL)foreground;
/// Main-frame navigations only. Return NO to cancel.
- (BOOL)browserShouldNavigate:(NSString *)url userGesture:(BOOL)userGesture;
- (void)browserFindResult:(int)count active:(int)active final:(BOOL)final;
- (void)browserDidClose;
/// The page wants the mic, camera or screen. Call `decide` once, from the main thread.
- (void)browserRequestsMedia:(NSString *)origin audio:(BOOL)audio video:(BOOL)video screen:(BOOL)screen decide:(void (^)(BOOL allowed))decide;
/// The page wants to show notifications.
- (void)browserRequestsNotifications:(NSString *)origin decide:(void (^)(BOOL allowed))decide;
@end

/// One Chromium browser (a tab's page) inside an NSView.
NS_SWIFT_UI_ACTOR
@interface BCEFBrowser : NSObject
- (instancetype)initWithURL:(nullable NSString *)url incognito:(BOOL)incognito NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, weak, nullable) id<BCEFBrowserDelegate> delegate;
- (void)loadURL:(NSString *)url;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;
- (void)goBack;
- (void)goForward;
/// 1 = 100%.
@property (nonatomic) double zoomFactor;
- (void)find:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext;
- (void)stopFinding;
- (void)executeJavaScript:(NSString *)code;
/// The rendered page as PNG, from Chromium itself (DevTools Page.captureScreenshot).
- (void)captureScreenshot:(void (^)(NSData *_Nullable png))completion;
/// Spike: DevTools Runtime.evaluate (by value, promises awaited); the raw DevTools JSON reply.
- (void)evaluate:(NSString *)expression completion:(void (^)(NSString *_Nullable json))completion;
/// Spike: a script that runs at the start of every new document (Page.addScriptToEvaluateOnNewDocument).
- (void)addScriptOnNewDocument:(NSString *)source;
- (void)close;
@end

/// Spike: a Chrome-style browser in its own top-level window (CEF's Views framework). Chrome
/// style is the only one with Chrome's extension system; it can't be a child of Browsa's views.
NS_SWIFT_UI_ACTOR
@interface BCEFChromeWindow : NSObject
- (instancetype)initWithURL:(NSString *)url;
- (void)loadURL:(NSString *)url;
- (void)captureScreenshot:(void (^)(NSData *_Nullable png))completion;
- (void)evaluate:(NSString *)expression completion:(void (^)(NSString *_Nullable json))completion;
- (void)close;
@end

NS_ASSUME_NONNULL_END
