import AppKit
import BrowserCore
import BrowserEngine
import Extensibility

/// The tools Browsa itself gives agents: tabs, pages and Margin notes.
///
/// Pages are read as text plus a numbered list of the things you can click or type into, which is
/// cheaper and more reliable for an agent than a screenshot. Screenshots are there when looks matter.
@MainActor
enum BrowserAgentTools {
    /// Scripts run in their own content world, so a page can't see or tamper with them.
    static let world = "browsa-agent"
    static let noTab = "No such tab. Open one with tab_open, or pass a tab id from tabs_list."

    static func register(in toolbox: AgentToolbox, bridge: AgentBridge) {
        let tabArg: JSONValue = ["type": "string", "description": "A tab id from tabs_list. Leave out for the newest tab in the Agent space."]

        toolbox.register(AgentTool(
            name: "tabs_list", title: "List tabs",
            description: """
            Tabs in the Agent space, which are yours to use. The user's own tabs (never private ones) are \
            listed too if they allow it; using one of those asks them first.
            """,
            readOnly: true
        ) { _, caller in
            let mine = bridge.allTabs.filter(bridge.isInAgentSpace)
            let others = bridge.allTabs.filter { !bridge.isInAgentSpace($0) }
            var seesYours = false
            if !others.isEmpty { seesYours = await bridge.ask(.yourTabs, caller: caller.name, action: "See your open tabs") }
            let tabs: [JSONValue] = (mine + (seesYours ? others : [])).map { t in
                [
                    "id": .string(t.id.uuidString),
                    "title": .string(t.title),
                    "url": .string(t.url?.absoluteString ?? ""),
                    "space": .string(bridge.space(of: t)?.name ?? ""),
                    "agent": .bool(bridge.isInAgentSpace(t)),
                    "openNotes": .number(Double(openCount(t.url, bridge))),
                ]
            }
            if !others.isEmpty, !seesYours {
                return .json(["tabs": .array(tabs), "note": "The user didn't share their own tabs. These are the Agent space's."])
            }
            return .json(.array(tabs))
        })

        toolbox.register(AgentTool(
            name: "tab_open", title: "Open a page",
            description: "Opens a URL in a new tab in the Agent space, where the user can watch, and waits for it to load. Returns the tab id.",
            inputSchema: ["type": "object", "required": ["url"], "properties": [
                "url": ["type": "string"],
                "show": ["type": "boolean", "description": "Bring the Agent space to the front. Default true."],
            ]],
            readOnly: false
        ) { args, _ in
            guard let url = webURL(args["url"]?.string) else { return .error("Give a full web address, like https://example.com") }
            let tab = bridge.openTab(url, show: args["show"]?.bool ?? true)
            await waitForLoad(tab)
            return .json(["tab": .string(tab.id.uuidString), "title": .string(tab.title), "url": .string(tab.url?.absoluteString ?? "")])
        })

        toolbox.register(AgentTool(
            name: "page_navigate", title: "Navigate",
            description: "Goes to a URL in a tab, or back, forward or reload.",
            inputSchema: ["type": "object", "properties": [
                "tab": tabArg,
                "url": ["type": "string"],
                "action": ["type": "string", "enum": ["back", "forward", "reload"]],
            ]],
            readOnly: false
        ) { args, _ in
            guard let tab = bridge.tab(args["tab"]?.string) else { return .error(noTab) }
            let c = bridge.controller(for: tab)
            switch args["action"]?.string {
            case "back": c.page.goBack()
            case "forward": c.page.goForward()
            case "reload": c.page.reload()
            default:
                guard let url = webURL(args["url"]?.string) else { return .error("Give a web address (http or https) or an action.") }
                c.load(url, source: .link)
            }
            await waitForLoad(tab)
            return .json(["title": .string(tab.title), "url": .string(tab.url?.absoluteString ?? "")])
        })

        toolbox.register(AgentTool(
            name: "page_read", title: "Read the page",
            description: """
            The page as text, plus numbered interactive elements (links, buttons, fields). Use the numbers \
            with page_click and page_type. Also lists any open Margin notes on the page: the user's feedback.
            """,
            inputSchema: ["type": "object", "properties": [
                "tab": tabArg,
                "maxCharacters": ["type": "number", "description": "Default 20000."],
            ]],
            readOnly: true
        ) { args, _ in
            guard let tab = bridge.tab(args["tab"]?.string) else { return .error(noTab) }
            let max = Int(args["maxCharacters"]?.double ?? 20000)
            let raw = try await bridge.controller(for: tab).page.evaluate(readScript(max: max), inWorld: world)
            var page = JSONValue(any: raw)
            if case .object(var o) = page, let url = tab.url {
                let notes = bridge.margin.notes(on: url).filter { note in note.status == .open }
                if !notes.isEmpty { o["notes"] = .array(notes.map(encode)) }
                o["tab"] = .string(tab.id.uuidString)
                page = .object(o)
            }
            return .json(page)
        })

        toolbox.register(AgentTool(
            name: "page_screenshot", title: "Screenshot",
            description: "What the tab looks like now. The tab has to be on screen, so this brings it forward in its window.",
            inputSchema: ["type": "object", "properties": ["tab": tabArg]],
            readOnly: true
        ) { args, _ in
            guard let tab = bridge.tab(args["tab"]?.string) else { return .error(noTab) }
            guard let image = await bridge.controller(for: tab).page.snapshot(),
                  let data = jpeg(image) else {
                return .error("Browsa can only take a screenshot of a tab that's showing. Open the Agent space in a window.")
            }
            return AgentTool.Result([.image(base64: data.base64EncodedString(), mimeType: "image/jpeg")])
        })

        toolbox.register(AgentTool(
            name: "page_click", title: "Click",
            description: "Clicks an element: a number from page_read, or a CSS selector.",
            inputSchema: ["type": "object", "properties": [
                "tab": tabArg,
                "ref": ["type": "number"],
                "selector": ["type": "string"],
            ]],
            readOnly: false
        ) { args, _ in
            guard let tab = bridge.tab(args["tab"]?.string) else { return .error(noTab) }
            let target = try targetExpression(args)
            let raw = try await bridge.controller(for: tab).page.evaluate("""
                const el = \(target);
                if (!el) return 'missing';
                el.scrollIntoView({block: 'center'});
                el.focus?.();
                el.click();
                return 'ok';
                """, inWorld: world)
            if raw as? String == "missing" { return .error("Couldn't find that element. Read the page again; it may have changed.") }
            try? await Task.sleep(for: .milliseconds(300))
            await waitForLoad(tab)
            return .text("Clicked. Now on \(tab.url?.absoluteString ?? "the same page").")
        })

        toolbox.register(AgentTool(
            name: "page_type", title: "Type",
            description: "Types into a field (a number from page_read, or a CSS selector), replacing what's there. Set submit to press Return.",
            inputSchema: ["type": "object", "required": ["text"], "properties": [
                "tab": tabArg,
                "ref": ["type": "number"],
                "selector": ["type": "string"],
                "text": ["type": "string"],
                "submit": ["type": "boolean"],
            ]],
            readOnly: false
        ) { args, _ in
            guard let tab = bridge.tab(args["tab"]?.string) else { return .error(noTab) }
            let target = try targetExpression(args)
            let text = jsString(args["text"]?.string ?? "")
            let submit = args["submit"]?.bool == true
            let raw = try await bridge.controller(for: tab).page.evaluate("""
                const el = \(target);
                if (!el) return 'missing';
                el.scrollIntoView({block: 'center'});
                el.focus();
                if (el.isContentEditable) { el.textContent = \(text); }
                else {
                  // Through the prototype's setter, so React and friends notice.
                  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, \(text));
                }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                if (\(submit)) {
                  el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
                  if (el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
                }
                return 'ok';
                """, inWorld: world)
            if raw as? String == "missing" { return .error("Couldn't find that field.") }
            if submit { try? await Task.sleep(for: .milliseconds(300)); await waitForLoad(tab) }
            return .text("Typed.")
        })

        toolbox.register(AgentTool(
            name: "page_eval", title: "Run JavaScript",
            description: "Runs JavaScript in a page on your own dev server (localhost only) and returns the result. The body is an async function body: use return.",
            inputSchema: ["type": "object", "required": ["script"], "properties": ["tab": tabArg, "script": ["type": "string"]]],
            readOnly: false
        ) { args, _ in
            guard let tab = bridge.tab(args["tab"]?.string) else { return .error(noTab) }
            guard AgentAccess.isLoopback(tab.url?.host() ?? "") else { return .error("page_eval only runs on localhost pages.") }
            // The page's own world, so it sees the app's globals.
            let raw = try await bridge.controller(for: tab).page.evaluate(args["script"]?.string ?? "", inWorld: "page")
            return .json(JSONValue(any: raw))
        })

        registerNotes(in: toolbox, bridge: bridge)
    }

    // MARK: Margin

    private static func registerNotes(in toolbox: AgentToolbox, bridge: AgentBridge) {
        toolbox.register(AgentTool(
            name: "notes_list", title: "List notes",
            description: """
            Margin notes: feedback the user pinned to pages ("make this button bigger"), with the quote or \
            element it's about. Your to-do list. Filter by URL prefix, e.g. http://localhost:3000.
            """,
            inputSchema: ["type": "object", "properties": [
                "urlPrefix": ["type": "string"],
                "includeResolved": ["type": "boolean"],
            ]],
            readOnly: true
        ) { args, _ in
            let prefix = args["urlPrefix"]?.string
            let notes = args["includeResolved"]?.bool == true
                ? bridge.margin.notes.filter { note in prefix.map { p in note.url.hasPrefix(p) } ?? true }
                : bridge.margin.openNotes(under: prefix)
            return .json(.array(notes.map(encode)))
        })

        toolbox.register(AgentTool(
            name: "notes_add", title: "Add a note",
            description: "Pins a note to a page for the user: a question, or what you changed and where to look.",
            inputSchema: ["type": "object", "required": ["url", "body"], "properties": [
                "url": ["type": "string"], "body": ["type": "string"],
                "quote": ["type": "string"], "selector": ["type": "string"],
            ]],
            readOnly: false
        ) { args, caller in
            guard let url = args["url"]?.string.flatMap(URL.init(string:)) else { return .error("Give the page's URL.") }
            let key = MarginStore.pageKey(url)
            let title = bridge.allTabs.first(where: { tab in tab.url.map(MarginStore.pageKey) == key })?.title ?? ""
            let note = bridge.margin.add(MarginNote(
                url: url, pageTitle: title,
                anchor: .init(quote: args["quote"]?.string, selector: args["selector"]?.string),
                body: args["body"]?.string ?? "", author: .agent(caller.name)))
            return .json(["id": .string(note.id.uuidString)])
        })

        toolbox.register(AgentTool(
            name: "notes_reply", title: "Reply to a note",
            description: "Replies on a note without resolving it, e.g. to ask the user something.",
            inputSchema: ["type": "object", "required": ["id", "body"], "properties": ["id": ["type": "string"], "body": ["type": "string"]]],
            readOnly: false
        ) { args, caller in
            guard let id = args["id"]?.string.flatMap(UUID.init(uuidString:)), bridge.margin.note(id) != nil else { return .error("No such note.") }
            bridge.margin.reply(to: id, author: .agent(caller.name), body: args["body"]?.string ?? "")
            return .text("Replied.")
        })

        toolbox.register(AgentTool(
            name: "notes_resolve", title: "Resolve a note",
            description: "Marks a note done, with a short comment on what you changed. The user can reopen it.",
            inputSchema: ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"], "comment": ["type": "string"]]],
            readOnly: false
        ) { args, caller in
            guard let id = args["id"]?.string.flatMap(UUID.init(uuidString:)), bridge.margin.note(id) != nil else { return .error("No such note.") }
            bridge.margin.resolve(id, by: .agent(caller.name), comment: args["comment"]?.string)
            return .text("Resolved.")
        })
    }

    // MARK: Helpers

    /// Only the web: no file:, data: or javascript: pages for agents.
    static func webURL(_ s: String?) -> URL? {
        guard let url = s.flatMap(URL.init(string:)), url.scheme == "https" || url.scheme == "http", url.host() != nil else { return nil }
        return url
    }

    static func openCount(_ url: URL?, _ bridge: AgentBridge) -> Int {
        guard let url else { return 0 }
        return bridge.margin.notes(on: url).filter { note in note.status == .open }.count
    }

    static func encode(_ n: MarginNote) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(n.id.uuidString),
            "url": .string(n.url),
            "page": .string(n.pageTitle),
            "body": .string(n.body),
            "author": .string(n.author.name),
            "status": .string(n.status.rawValue),
            "created": .string(ISO8601DateFormatter().string(from: n.createdAt)),
        ]
        if let q = n.anchor.quote { o["quote"] = .string(q) }
        if let s = n.anchor.selector { o["selector"] = .string(s) }
        if !n.replies.isEmpty {
            o["replies"] = .array(n.replies.map { ["author": .string($0.author.name), "body": .string($0.body)] })
        }
        return .object(o)
    }

    /// Up to ten seconds; a page that never settles still gets answered.
    static func waitForLoad(_ tab: BrowserTab) async {
        try? await Task.sleep(for: .milliseconds(150))
        for _ in 0..<100 where tab.isLoading {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func targetExpression(_ args: JSONValue) throws -> String {
        if let ref = args["ref"]?.double { return "document.querySelector('[data-browsa-ref=\"\(Int(ref))\"]')" }
        if let sel = args["selector"]?.string { return "document.querySelector(\(jsString(sel)))" }
        throw AgentToolError("Give a ref from page_read or a CSS selector.")
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    static func jpeg(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// Numbers what you can act on (`data-browsa-ref`), then returns the readable text and that list.
    static func readScript(max: Int) -> String {
        """
        const visible = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
          return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
        const label = el => (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder
          || el.title || el.alt || el.name || '').trim().replace(/\\s+/g, ' ').slice(0, 80);
        document.querySelectorAll('[data-browsa-ref]').forEach(e => e.removeAttribute('data-browsa-ref'));
        const els = [...document.querySelectorAll('a[href], button, input:not([type=hidden]), textarea, select, [role=button], [role=link], [contenteditable=true]')]
          .filter(visible).slice(0, 300);
        const elements = els.map((el, i) => {
          el.setAttribute('data-browsa-ref', String(i + 1));
          const o = { ref: i + 1, kind: el.getAttribute('role') || el.tagName.toLowerCase(), label: label(el) };
          if (el.type && el.tagName === 'INPUT') o.type = el.type;
          if (el.href) o.href = el.href;
          if (el.disabled) o.disabled = true;
          return o;
        });
        const text = (document.body?.innerText || '').replace(/\\n{3,}/g, '\\n\\n');
        return { title: document.title, url: location.href, text: text.slice(0, \(max)),
                 truncated: text.length > \(max), elements };
        """
    }
}

struct AgentToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
