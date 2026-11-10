import SwiftUI
import AppKit
import BrowserCore
import Extensibility

// MARK: - Colour

/// An agent acting live: the pill, the cursor, the caption. The same warm yellow as notes, so
/// "an agent is here" and "a note is here" read as one family.
enum AgentLive {
    static let color = Color(red: 0.96, green: 0.71, blue: 0.04)
    static let css = "#f5b60b"
}

// MARK: - Words

/// Agent calls in plain words: "Typed ‘Ada Lovelace’ into Name on card", not "page_type text: …".
enum AgentWords {
    /// "key: value, key: value" (how `AgentToolbox` summarises arguments) back into fields.
    static func fields(_ summary: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in summary.components(separatedBy: ", ") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            out[String(part[..<colon])] = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    static func fields(_ args: JSONValue) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in args.object ?? [:] { out[k] = v.string ?? v.double.map { String(Int($0)) } ?? "" }
        return out
    }

    static func sentence(tool: String, fields f: [String: String], tabTitle: String? = nil) -> String {
        let page = tabTitle.map { "‘\($0)’" } ?? "the page"
        let target = f["label"].map { "‘\($0)’" } ?? f["selector"].map(readable) ?? f["ref"].map { "item \($0)" } ?? "it"
        switch tool {
        case "tabs_list": return "Looked at your open tabs"
        case "tab_open": return "Opened \(f["url"].map(shortURL) ?? "a page")"
        case "page_navigate":
            if let a = f["action"], !a.isEmpty { return a == "back" ? "Went back" : a == "forward" ? "Went forward" : "Reloaded \(page)" }
            return "Went to \(f["url"].map(shortURL) ?? "a page")"
        case "page_read": return "Read \(page)"
        case "page_screenshot": return "Took a screenshot of \(page)"
        case "page_click": return "Clicked \(target)"
        case "page_type": return "Typed ‘\(f["text"] ?? "")’ into \(target)"
        case "page_eval": return "Ran a script on \(page)"
        case "notes_list": return "Read your notes"
        case "notes_add": return "Left a note: “\(f["body"]?.prefix(60) ?? "")”"
        case "notes_reply": return "Replied to a note"
        case "notes_resolve": return "Resolved a note"
        default: return tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Present-tense, for the caption on the page while it happens.
    static func caption(_ sentence: String) -> String {
        let pairs = [("Clicked", "Clicking"), ("Typed", "Typing"), ("Read", "Reading"), ("Took a screenshot", "Taking a screenshot"),
                     ("Opened", "Opening"), ("Went to", "Going to"), ("Ran", "Running"), ("Left a note", "Leaving a note"),
                     ("Replied", "Replying"), ("Resolved", "Resolving"), ("Looked at", "Looking at")]
        for (past, now) in pairs where sentence.hasPrefix(past) { return now + sentence.dropFirst(past.count) }
        return sentence
    }

    private static func shortURL(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host() else { return s }
        let path = u.path()
        return path.isEmpty || path == "/" ? host : host + path
    }

    /// "#email" → "email", "button.pay" → "pay button".
    private static func readable(_ selector: String) -> String {
        let last = selector.components(separatedBy: CharacterSet(charactersIn: " >")).last(where: { !$0.isEmpty }) ?? selector
        if last.hasPrefix("#") { return String(last.dropFirst()).replacingOccurrences(of: "-", with: " ") }
        return last
    }
}

// MARK: - Cursor on the page

/// A yellow pointer (the iPad pointer symbol) that glides to what the agent is about to click or type
/// into, a ripple on a click, an outline on a field. Runs in its own world; waits until it arrives.
enum AgentCursor {
    @MainActor static func target(_ args: JSONValue) -> String {
        if let ref = args["ref"]?.double { return BrowserAgentTools.refExpression(Int(ref)) }
        if let sel = args["selector"]?.string,
           let data = try? JSONSerialization.data(withJSONObject: [sel]), let json = String(data: data, encoding: .utf8) {
            return "(() => { try { return document.querySelector(\(json)[0]); } catch (e) { return null; } })()"
        }
        return "null"
    }

    /// `pointer.arrow.ipad`, drawn once as a PNG for the page.
    @MainActor static let pointerImage: String = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(.init(paletteColors: [NSColor(AgentLive.color)]))
        guard let symbol = NSImage(systemSymbolName: "pointer.arrow.ipad", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return "" }
        let size = NSSize(width: symbol.size.width * 2, height: symbol.size.height * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return "" }
        rep.size = symbol.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }()

    @MainActor static var script: String { scriptBody.replacingOccurrences(of: "__POINTER__", with: pointerImage)
        .replacingOccurrences(of: "__LIVE__", with: AgentLive.css) }

    private static let scriptBody = #"""
    window.__browsaAgentCursor = async (el, click) => {
      if (!el) return false;
      el.scrollIntoView({ block: 'center', inline: 'nearest' });
      const root = document.documentElement;
      let c = document.getElementById('__browsa-agent-cursor');
      if (!c) {
        c = document.createElement('div'); c.id = '__browsa-agent-cursor';
        c.innerHTML = '<img src="__POINTER__" width="14" alt="">';
        Object.assign(c.style, { position: 'fixed', zIndex: 2147483647, pointerEvents: 'none', left: (innerWidth - 40) + 'px', top: '40px',
          transition: 'left .32s cubic-bezier(.3,.7,.2,1), top .32s cubic-bezier(.3,.7,.2,1), opacity .3s', filter: 'drop-shadow(0 1px 1.5px rgba(0,0,0,.35)) drop-shadow(0 0 1px white)' });
        root.appendChild(c);
      }
      const r = el.getBoundingClientRect();
      const x = r.left + Math.min(r.width / 2, 40), y = r.top + r.height / 2;
      c.style.opacity = '1';
      c.style.left = x + 'px'; c.style.top = y + 'px';
      await new Promise(res => setTimeout(res, 340));
      const mark = document.createElement('div');
      if (click) {
        Object.assign(mark.style, { position: 'fixed', zIndex: 2147483646, pointerEvents: 'none', left: (x - 14) + 'px', top: (y - 14) + 'px',
          width: '28px', height: '28px', borderRadius: '50%', border: '2px solid __LIVE__', opacity: '0.9',
          transition: 'transform .45s ease-out, opacity .45s ease-out' });
        root.appendChild(mark);
        requestAnimationFrame(() => { mark.style.transform = 'scale(2.2)'; mark.style.opacity = '0'; });
        setTimeout(() => mark.remove(), 500);
      } else {
        Object.assign(mark.style, { position: 'fixed', zIndex: 2147483646, pointerEvents: 'none', left: (r.left - 4) + 'px', top: (r.top - 4) + 'px',
          width: (r.width + 8) + 'px', height: (r.height + 8) + 'px', borderRadius: '8px', border: '2px solid __LIVE__',
          boxShadow: '0 0 0 4px rgba(245,182,11,.22)', transition: 'opacity .4s' });
        root.appendChild(mark);
        setTimeout(() => { mark.style.opacity = '0'; setTimeout(() => mark.remove(), 400); }, 1600);
      }
      clearTimeout(window.__browsaCursorHide);
      root.dataset.browsaCursorAt = String(Date.now());
      setTimeout(() => { if (Date.now() - Number(root.dataset.browsaCursorAt) > 3500) c.style.opacity = '0'; }, 3600);
      return true;
    };
    """#
}

// MARK: - Driving pill

/// At the top of the sidebar while an agent is acting: who, what, Watch and Stop. Your window
/// never switches to the Agent space by itself.
struct AgentDrivingPill: View {
    @Environment(Browser.self) private var browser
    private var agents: AgentBridge { browser.library.agents }

    var body: some View {
        if agents.isEnabled, agents.isActing || !agents.requests.isEmpty, let step = agents.currentStep ?? agents.requests.first.map({
            AgentBridge.Step(caller: $0.caller, tabID: nil, text: "Waiting for you", at: $0.at)
        }) {
            let watching = browser.currentTab.map { tab in step.tabID == tab.id } ?? false
            HStack(spacing: 8) {
                AgentIcon(caller: step.caller, size: 16)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(AgentLive.color).frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                            .offset(x: 2, y: 2)
                            .symbolEffect(.pulse)
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(AgentIdentity.displayName(step.caller)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(agents.requests.isEmpty ? step.text : "Waiting for you to allow")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .contentTransition(.opacity)
                }
                .help("\(AgentIdentity.displayName(step.caller)) is driving: \(step.text)")
                Spacer(minLength: 4)
                if !watching {
                    Button { withAnimation(Motion.snappy) { agents.watch(in: browser) } } label: {
                        Image(systemName: "eye.fill").font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(.primary.opacity(0.08), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Watch: show the agent's tab")
                }
                Button { withAnimation(Motion.snappy) { agents.stopAll() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.white)
                        .background(.red, in: .circle)
                }
                .buttonStyle(.plain)
                .help("Stop all agents")
            }
            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
            .background(AgentLive.color.opacity(0.09), in: .rect(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(AgentLive.color.opacity(0.3)))
            .animation(Motion.snappy, value: step.text)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - On the page

/// Over the page: an ask from an agent (for this tab, or your tab list), and a caption while an
/// agent acts in this tab.
struct AgentPageOverlay: View {
    @Environment(Browser.self) private var browser
    private var agents: AgentBridge { browser.library.agents }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(agents.requests) { AgentAskBar(request: $0) }
            if let step = agents.currentStep, agents.isActing, step.tabID != nil, step.tabID == browser.currentTab?.id,
               Date().timeIntervalSince(step.at) < 6 {
                HStack(spacing: 7) {
                    Circle().fill(AgentLive.color).frame(width: 7, height: 7).symbolEffect(.pulse)
                    AgentIcon(caller: step.caller, size: 13)
                    Text(AgentWords.caption(step.text)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .padding(.horizontal, 12).frame(height: 28)
                .glassEffect(.regular.tint(AgentLive.color.opacity(0.22)), in: .capsule)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(step.at)
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 16)
        .animation(Motion.snappy, value: agents.requests.map(\.id))
        .animation(Motion.snappy, value: agents.currentStep)
    }
}

/// An ask, as a bar on the page you're on. The same ask shows in the Agents panel too; answering
/// either answers both.
struct AgentAskBar: View {
    @Environment(Browser.self) private var browser
    let request: AgentRequest
    private var agents: AgentBridge { browser.library.agents }

    var body: some View {
        let elsewhere: Bool = {
            if case .yourTab(let id, _) = request.grant { return id != browser.currentTab?.id }
            return false
        }()
        HStack(spacing: 10) {
            AgentIcon(caller: request.caller, size: 18)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "hand.raised.circle.fill").font(.system(size: 9)).foregroundStyle(.white, .orange).offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentAsk.headline(request, here: !elsewhere)).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(AgentAsk.detail(request)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if elsewhere, case .yourTab(let id, _) = request.grant {
                Button("Show Tab") { AgentAsk.show(id, in: browser) }.controlSize(.small)
            }
            Button("Don't Allow") { withAnimation(Motion.snappy) { agents.answer(request.id, allow: false) } }
                .controlSize(.small)
            Button("Allow") { withAnimation(Motion.snappy) { agents.answer(request.id, allow: true) } }
                .buttonStyle(.glassProminent).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.orange.opacity(0.35)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

enum AgentAsk {
    static func headline(_ r: AgentRequest, here: Bool) -> String {
        let who = AgentIdentity.displayName(r.caller)
        return switch r.grant {
        case .yourTab: here ? "\(who) wants to \(r.action.lowercased()) in this tab"
                            : "\(who) wants to \(r.action.lowercased()) in “\(r.tabTitle ?? "one of your tabs")”"
        case .yourTabs: "\(who) wants to see your open tabs"
        }
    }

    static func detail(_ r: AgentRequest) -> String {
        switch r.grant {
        case .yourTab: "It sees what you see here, signed in as you. Allowed for this tab until you quit."
        case .yourTabs: "Titles and addresses of tabs that aren't private. It still asks before using one."
        }
    }

    @MainActor static func show(_ id: UUID, in browser: Browser) {
        guard let tab = browser.library.tab(id: id) else { return }
        if let space = browser.space(containing: tab) { browser.selectSpace(space) }
        browser.select(tab)
    }
}
