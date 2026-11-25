import SwiftUI
import AppKit
import BrowserEngine

// Getting 1Password's extension to unlock with the 1Password app. Two things can stand in the way, and
// each gets a card at the bottom of the sidebar, in place of any announcement:
//
// 1. The extension was added before Browsa served Chrome's extension addresses. 1Password's app only
//    talks to its extension at chrome-extension://<id>/, so it needs moving. One button moves it; what
//    it kept stays at the old address, so you sign in to it once.
// 2. 1Password's app doesn't know Browsa as a browser. It refuses until you add Browsa under
//    1Password › Settings › Browser. The refusal comes through the engine (ExtensionNativeHosts), and
//    so does the first connection the app keeps open, which ticks the card off.
//
// Both only show when the 1Password app is on this Mac: without it there's nothing to unlock with.

@MainActor @Observable
final class OnePasswordSetup {
    static let shared = OnePasswordSetup()
    static let catalogID = "chrome:aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    static let appBundleID = "com.1password.1password"

    enum Stage: String { case move, signIn, addBrowser, done }

    /// The app refused Browsa and hasn't accepted it since. Kept across launches.
    private(set) var refused: Bool {
        didSet { UserDefaults.standard.set(refused, forKey: Self.refusedKey) }
    }
    /// Moved this session: sign in once.
    private(set) var moved = false
    /// Accepted just now, after refusing: the card shows its ticks for a moment, then goes.
    private(set) var accepted = false
    private var dismissed: Set<String> {
        didSet { UserDefaults.standard.set(Array(dismissed).sorted(), forKey: Self.dismissedKey) }
    }
    /// The engine's address record isn't observable; bumped when it changes.
    private var revision = 0
    private(set) var appURL: URL?

    private static let refusedKey = "onePassword.appRefused"
    private static let dismissedKey = "onePassword.dismissedCards"

    private init() {
        refused = UserDefaults.standard.bool(forKey: Self.refusedKey)
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleID)
    }

    /// The card to show now, if any.
    func stage(in library: Library) -> Stage? {
        _ = revision
        guard appURL != nil, library.extensions.contains(where: { $0.id == Self.catalogID }) else { return nil }
        let next: Stage? = if accepted { .done }
            else if moved { .signIn }
            else if library.engine.extensionUsesOldAddress(id: Self.catalogID) { .move }
            else if refused { .addBrowser }
            else { nil }
        guard let next, next == .done || !dismissed.contains(next.rawValue) else { return nil }
        return next
    }

    /// What the 1Password app said, through the extension's connection to it.
    func heard(trusted: Bool) {
        appURL = appURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleID)
        if trusted {
            guard refused else { return }
            withAnimation(Motion.snappy) {
                refused = false
                accepted = true
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(Motion.snappy) { accepted = false }
            }
        } else if !refused {
            withAnimation(Motion.spring) { refused = true }
        }
    }

    func move(in library: Library) {
        library.moveExtensionToNewAddress(id: Self.catalogID)
        withAnimation(Motion.snappy) {
            moved = true
            revision += 1
        }
    }

    func signedIn() {
        withAnimation(Motion.snappy) { moved = false }
    }

    func dismiss(_ stage: Stage) {
        withAnimation(Motion.snappy) {
            if stage == .done { accepted = false } else { dismissed.insert(stage.rawValue) }
            if stage == .signIn { moved = false }
        }
    }

    func openApp() {
        guard let appURL else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The card, above the sidebar's bottom row. Looks like an announcement. Not shown in private windows.
struct OnePasswordCard: View {
    @Environment(Browser.self) private var browser
    private let setup = OnePasswordSetup.shared
    @State private var anchor = OnePasswordAnchor()

    var body: some View {
        ZStack {
            if !browser.currentSpace.isPrivate, let stage = setup.stage(in: browser.library) {
                card(stage)
                    .id(stage)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: setup.stage(in: browser.library))
    }

    private func card(_ stage: Stage) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title(stage))
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.trailing, 22)
            Text(message(stage))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if stage == .addBrowser || stage == .done {
                VStack(alignment: .leading, spacing: 5) {
                    step("In 1Password, open Settings › Browser", done: stage == .done)
                    step("Click Add Browser and choose Browsa", done: stage == .done)
                }
                .padding(.top, 4)
            }
            if let action = action(stage) {
                HStack {
                    Spacer(minLength: 4)
                    Button(action.title, action: action.run)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .fixedSize()
                        .background { OnePasswordAnchorView(anchor: anchor) }
                }
                .padding(.top, 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.06)))
        .clipShape(shape)
        .overlay(alignment: .topTrailing) {
            Button { setup.dismiss(stage) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.mini)
            .padding(6)
            .help("Close")
        }
    }

    typealias Stage = OnePasswordSetup.Stage

    private func title(_ stage: Stage) -> String {
        switch stage {
        case .move: "Unlock 1Password with its app"
        case .signIn: "Sign in to 1Password once"
        case .addBrowser: "Add Browsa to 1Password"
        case .done: "1Password is connected"
        }
    }

    private func message(_ stage: Stage) -> String {
        switch stage {
        case .move: "1Password's extension needs a quick update in Browsa before the 1Password app can unlock it. You'll sign in to it once afterwards."
        case .signIn: "The extension is updated. Open it and sign in, or unlock it with the 1Password app."
        case .addBrowser: "The 1Password app doesn't know Browsa yet, so the extension can't unlock with it."
        case .done: "The extension now unlocks with the 1Password app."
        }
    }

    private func action(_ stage: Stage) -> (title: String, run: () -> Void)? {
        switch stage {
        case .move: ("Update 1Password", { setup.move(in: browser.library) })
        case .signIn: ("Sign In", signIn)
        case .addBrowser: ("Open 1Password", { setup.openApp() })
        case .done: nil
        }
    }

    /// Opens the extension's popup at the button, as its toolbar button would.
    private func signIn() {
        if let ext = browser.library.extensions.first(where: { $0.id == OnePasswordSetup.catalogID }) {
            browser.runExtension(ext, anchor: anchor.view)
        }
        setup.signedIn()
    }

    private func step(_ text: String, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(done ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// On the add sheet and the extension's Library page: what unlocking with the app takes.
struct OnePasswordTip: View {
    private let setup = OnePasswordSetup.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unlock with the 1Password app").font(.system(size: 13, weight: .medium))
                Text("After you add it, open 1Password › Settings › Browser, click Add Browser and choose Browsa. Browsa tells you once it's connected.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if setup.appURL != nil {
                Button("Open 1Password") { setup.openApp() }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Where the extension's popup opens from the card.
@MainActor final class OnePasswordAnchor {
    weak var view: NSView?
}

private struct OnePasswordAnchorView: NSViewRepresentable {
    let anchor: OnePasswordAnchor
    func makeNSView(context: Context) -> NSView { let v = NSView(); anchor.view = v; return v }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
