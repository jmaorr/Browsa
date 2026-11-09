import SwiftUI
import BrowserCore
import BrowserEngine
import Extensibility

/// A page's dialog, sign-in or permission request. Always names the site, so a page can't pass
/// itself off as the browser.
struct PromptSheet: View {
    @Environment(Browser.self) private var browser
    let prompt: Prompt
    @State private var text = ""
    @State private var user = ""
    @State private var password = ""
    @State private var alwaysAllow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if let message, !message.isEmpty {
                ScrollView { Text(message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fields
            HStack {
                Spacer()
                if showsCancel {
                    Button(cancelTitle) { browser.answer(.cancel) }
                        .keyboardShortcut(.cancelAction)
                }
                // An agent's ask can appear while you're typing elsewhere: Return mustn't allow it.
                Button(okTitle) { browser.answer(okResponse) }
                    .keyboardShortcut(isAgentAsk ? nil : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if case .dialog(.prompt(_, _, let d)) = prompt.kind { text = d }
        }
    }

    private var title: String {
        switch prompt.kind {
        case .dialog(.alert(let host, _)), .dialog(.confirm(let host, _)), .dialog(.prompt(let host, _, _)):
            "\(host) says"
        case .dialog(.credentials(let host, _)):
            "Sign in to \(host)"
        case .permission(let p, let host):
            "Allow \(host) to \(p.phrase)?"
        case .agent(let ask):
            switch ask.grant {
            case .site(let host): "Let \(ask.caller) use \(host)?"
            case .yourTab: "Let \(ask.caller) use your tab “\(ask.tabTitle ?? "Untitled")”?"
            case .yourTabs: "Let \(ask.caller) see your open tabs?"
            }
        }
    }

    private var message: String? {
        switch prompt.kind {
        case .dialog(.alert(_, let m)), .dialog(.confirm(_, let m)), .dialog(.prompt(_, let m, _)): m
        case .dialog(.credentials(_, let realm)): realm.map { "The site says: “\($0)”" }
        case .permission: "You can change this later in Settings."
        case .agent(let ask):
            switch ask.grant {
            case .site:
                "It wants to \(ask.action.lowercased()). It works as you, signed in, in the Agent space where you can watch. Allowed until you quit Browsa. Stop in the Agents panel halts every agent."
            case .yourTab(_, let host):
                "It wants to \(ask.action.lowercased()) on \(host.isEmpty ? "this page" : host). This is your tab, not the Agent space, so it sees what you see there, signed in as you. Allowed for this tab until you quit Browsa."
            case .yourTabs:
                "It gets the title and address of every tab that isn't private. It still asks before it reads or uses one of them."
            }
        }
    }

    @ViewBuilder private var fields: some View {
        switch prompt.kind {
        case .dialog(.prompt):
            TextField("", text: $text).textFieldStyle(.roundedBorder)
        case .agent(let ask):
            if case .site(let host) = ask.grant {
                Toggle("Always allow on \(host)", isOn: $alwaysAllow).toggleStyle(.checkbox)
            }
        case .dialog(.credentials):
            TextField("User name", text: $user).textFieldStyle(.roundedBorder).textContentType(.username)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).textContentType(.password)
        default:
            EmptyView()
        }
    }

    private var isAgentAsk: Bool {
        if case .agent = prompt.kind { return true }
        return false
    }

    private var showsCancel: Bool {
        if case .dialog(.alert) = prompt.kind { return false }
        return true
    }

    private var cancelTitle: String {
        if case .permission = prompt.kind { return "Don't Allow" }
        if case .agent = prompt.kind { return "Don't Allow" }
        return "Cancel"
    }

    private var okTitle: String {
        switch prompt.kind {
        case .permission: "Allow"
        case .agent: "Allow"
        case .dialog(.credentials): "Sign In"
        default: "OK"
        }
    }

    private var okResponse: EngineDialogResponse {
        switch prompt.kind {
        case .dialog(.prompt): .text(text)
        case .dialog(.credentials): .credentials(user: user, password: password)
        case .agent: alwaysAllow ? .text(AgentAsk.always) : .ok
        default: .ok
        }
    }
}

/// Today tabs that were archived after going unused.
struct ArchiveSheet: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Archived Tabs").font(.headline)
                Spacer()
                Button("Clear All") { browser.library.clearArchive() }
                    .disabled(browser.archive.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if browser.archive.isEmpty {
                Text("Today tabs you haven't used for \(Int(browser.settings.archiveAfterHours)) hours move here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(30)
            } else {
                List(browser.archive) { tab in
                    HStack(spacing: 10) {
                        TabIcon(tab: tab, size: 16)
                        VStack(alignment: .leading) {
                            Text(tab.displayTitle).lineLimit(1)
                            Text(tab.lastActive, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { browser.restoreFromArchive(tab); dismiss() }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 460, height: 420)
    }
}
