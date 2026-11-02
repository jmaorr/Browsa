import SwiftUI
import BrowserCore
import Suggest

/// Shows the page's current dialog, permission request or login as a native alert.
/// The site's name is always the title, so a page can't pass its dialog off as the browser's.
struct WebPromptAlert: ViewModifier {
    @Environment(BrowserState.self) private var browser
    @State private var text = ""
    @State private var user = ""
    @State private var password = ""

    func body(content: Content) -> some View {
        let prompt = browser.activePrompt
        content.alert(title(for: prompt), isPresented: Binding(
            get: { browser.activePrompt != nil },
            set: { shown in if !shown, browser.activePrompt != nil { browser.answer(.cancel) } }
        ), presenting: prompt) { p in
            switch p.kind {
            case .alert:
                Button("OK") { browser.answer(.ok) }
            case .confirm:
                Button("Cancel", role: .cancel) { browser.answer(.cancel) }
                Button("OK") { browser.answer(.ok) }
            case .textInput:
                TextField("", text: $text)
                Button("Cancel", role: .cancel) { browser.answer(.cancel) }
                Button("OK") { browser.answer(.text(text)) }
            case .permission:
                Button("Don't Allow", role: .cancel) { browser.answer(.cancel) }
                Button("Allow") { browser.answer(.ok) }
            case .credentials:
                TextField("User Name", text: $user)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button("Cancel", role: .cancel) { browser.answer(.cancel) }
                Button("Sign In") { browser.answer(.credentials(user: user, password: password)) }
            }
        } message: { p in
            switch p.kind {
            case .permission: Text("You can change this later in Settings > Websites.")
            case .credentials(let realm): Text(realm.map { "The site says: “\($0)”" } ?? "Your login is sent to \(p.host).")
            default: Text(p.message)
            }
        }
        .onChange(of: prompt?.id) {
            if case .textInput(let d) = browser.activePrompt?.kind { text = d }
            if case .credentials = browser.activePrompt?.kind { user = ""; password = "" }
        }
    }

    private func title(for p: WebPrompt?) -> String {
        guard let p else { return "" }
        switch p.kind {
        case .permission: return p.message
        case .credentials: return "Sign in to \(p.host)"
        default: return p.host
        }
    }
}

/// A short confirmation that drops in from the top ("Opened in background").
struct ToastOverlay: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        VStack {
            if let text = browser.toast {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer()
        }
        .padding(.top, 8)
        .animation(Motion.bouncy, value: browser.toast)
        .allowsHitTesting(false)
        .onChange(of: browser.toast) { _, t in
            if let t { AccessibilityNotification.Announcement(t).post() }
        }
    }
}

/// Shown in place of the page when it couldn't load.
struct ErrorPage: View {
    @Environment(BrowserState.self) private var browser
    let tab: BrowserTab
    let error: LoadError

    var body: some View {
        ContentUnavailableView {
            Label(error.title, systemImage: error.symbol)
        } description: {
            VStack(spacing: 6) {
                if let host = error.url.map(URLNormalizer.displayHost) { Text(host).font(.headline) }
                Text(error.detail)
            }
        } actions: {
            if error.canRetry, let url = error.url {
                Button("Try Again") { browser.session(for: tab).load(url, source: .reload) }
                    .buttonStyle(.glassProminent)
            }
            if tab.canGoBack {
                Button("Go Back") { browser.goBack() }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
