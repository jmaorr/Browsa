import Foundation
import BrowserCore
import Extensibility

/// Everything SpikeBrowsa fakes, in one place: the dev servers Radar finds, the pages they serve,
/// the notes pinned to them, and what a connected agent does.
///
/// Ports live in the 479xx range so they never clash with real dev servers (3000, 8080…) or with
/// the daily-driver Browsa's agent endpoint (47913).
@MainActor
enum SpikeMocks {
    // MARK: Radar

    static let servers: [RadarServer] = [
        .init(port: 47940, project: "checkout-web", branch: "main", framework: "Next.js"),
        .init(port: 47941, project: "checkout-web", branch: "feat/pay-button", framework: "Next.js", isWorktree: true),
        .init(port: 47942, project: "api", branch: "main", framework: "Go", isUp: false, note: "Exited 2 min ago"),
        .init(port: 47943, project: "design-system", branch: "main", framework: "Storybook"),
    ]

    static func url(_ port: Int, _ path: String = "/") -> URL { URL(string: "http://localhost:\(port)\(path)")! }

    // MARK: Pages

    /// The page a mock dev server serves for `path`, by port.
    static func page(port: Int, path: String) -> String {
        switch port {
        case 47943: return storybook(path: path)
        default: return checkout(path: path, variant: port == 47941)
        }
    }

    private static let css = """
    :root { color-scheme: light dark; --accent: #5b5bd6; }
    * { box-sizing: border-box; }
    body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0; background: Canvas; color: CanvasText; }
    header { display: flex; align-items: center; gap: 24px; padding: 16px 32px; border-bottom: 1px solid #8883; }
    header b { font-size: 18px; } header nav a { margin-right: 16px; color: inherit; text-decoration: none; opacity: .75; }
    main { max-width: 960px; margin: 0 auto; padding: 32px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 16px; }
    .card { border: 1px solid #8884; border-radius: 12px; padding: 16px; }
    .swatch { height: 120px; border-radius: 8px; margin-bottom: 12px; }
    button { font: inherit; border: 0; border-radius: 8px; padding: 8px 14px; background: var(--accent); color: white; cursor: pointer; }
    button.secondary { background: #8883; color: inherit; }
    input, select, textarea { font: inherit; padding: 8px 10px; border-radius: 8px; border: 1px solid #8886; width: 100%; background: Field; color: FieldText; }
    label { display: block; margin: 12px 0 4px; font-size: 13px; opacity: .8; }
    .banner { padding: 10px 32px; background: #f5a62322; font-size: 13px; }
    #log { font: 12px ui-monospace, monospace; opacity: .7; margin-top: 16px; min-height: 1em; }
    """

    private static func shell(title: String, brand: String, nav: [(String, String)], banner: String? = nil, body: String) -> String {
        let links = nav.map { "<a href=\"\($0.1)\">\($0.0)</a>" }.joined()
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <meta name="viewport" content="width=device-width"><style>\(css)</style></head><body>
        \(banner.map { "<div class=\"banner\">\($0)</div>" } ?? "")
        <header><b>\(brand)</b><nav>\(links)</nav></header>
        <main>\(body)<div id="log"></div></main>
        <script>
        document.addEventListener('click', e => { const b = e.target.closest('button'); if (b) document.getElementById('log').textContent = 'clicked: ' + b.textContent.trim(); });
        document.addEventListener('input', e => { document.getElementById('log').textContent = 'typed: ' + e.target.value; });
        </script></body></html>
        """
    }

    private static let products = [("Linen Shirt", "#c9b79c", 89), ("Field Jacket", "#56664b", 240), ("Canvas Tote", "#d8d2c4", 45),
                                   ("Wool Beanie", "#8a3b2e", 35), ("Trail Runner", "#3d4a5c", 160), ("Desk Lamp", "#e0b44c", 120)]

    private static func checkout(path: String, variant: Bool) -> String {
        let nav = [("Shop", "/"), ("Cart", "/cart"), ("Checkout", "/checkout")]
        let brand = "Northwind"
        let banner = variant ? "Worktree <code>feat/pay-button</code>: bigger pay button" : nil
        switch path {
        case "/cart":
            let rows = products.prefix(2).map { "<div class=\"card\" style=\"display:flex;justify-content:space-between\"><span>\($0.0)</span><span>$\($0.2)</span></div>" }.joined()
            return shell(title: "Cart · Northwind", brand: brand, nav: nav, banner: banner, body: """
                <h1>Your cart</h1><div style="display:grid;gap:8px">\(rows)</div>
                <p>Total: <b>$329</b></p><button id="to-checkout" onclick="location.href='/checkout'">Go to checkout</button>
                """)
        case "/checkout":
            let pay = variant ? "style=\"width:100%;padding:16px;font-size:18px\"" : ""
            return shell(title: "Checkout · Northwind", brand: brand, nav: nav, banner: banner, body: """
                <h1>Checkout</h1>
                <form onsubmit="event.preventDefault()">
                <label for="name">Name on card</label><input id="name" placeholder="Ada Lovelace">
                <label for="email">Email</label><input id="email" type="email" placeholder="ada@example.com">
                <label for="ship">Shipping</label><select id="ship"><option>Standard (free)</option><option>Express ($12)</option></select>
                <label for="note">Order note</label><textarea id="note" rows="3"></textarea>
                <p><button id="pay" \(pay)>Pay $329</button> <button class="secondary" type="button">Save for later</button></p>
                </form>
                """)
        default:
            let cards = products.map {
                "<div class=\"card\"><div class=\"swatch\" style=\"background:\($0.1)\"></div><b>\($0.0)</b><p>$\($0.2)</p><button>Add to cart</button></div>"
            }.joined()
            return shell(title: "Northwind Shop", brand: brand, nav: nav, banner: banner,
                         body: "<h1 id=\"hero\">Autumn essentials</h1><p>Well-made things for colder days.</p><div class=\"grid\">\(cards)</div>")
        }
    }

    private static func storybook(path: String) -> String {
        let nav = [("Buttons", "/"), ("Inputs", "/inputs"), ("Colors", "/colors")]
        let body: String
        switch path {
        case "/inputs":
            body = "<h1>Inputs</h1><label>Text</label><input placeholder=\"Type here\"><label>Select</label><select><option>One</option><option>Two</option></select>"
        case "/colors":
            let swatches = products.map { "<div class=\"card\"><div class=\"swatch\" style=\"background:\($0.1)\"></div><code>\($0.1)</code></div>" }.joined()
            body = "<h1>Colors</h1><div class=\"grid\">\(swatches)</div>"
        default:
            body = "<h1>Buttons</h1><p><button>Primary</button> <button class=\"secondary\">Secondary</button> <button disabled style=\"opacity:.4\">Disabled</button></p>"
        }
        return shell(title: "Storybook · design-system", brand: "design-system", nav: nav, body: body)
    }

    // MARK: Notes

    static func notes() -> [MarginNote] {
        let shop = url(47940), checkout = url(47940, "/checkout"), cart = url(47940, "/cart")
        var list: [MarginNote] = []
        list.append(MarginNote(url: checkout, pageTitle: "Checkout · Northwind",
                               anchor: .init(selector: "#pay", x: 60, y: 420),
                               body: "Pay button should span the form width on narrow windows."))
        list.append(MarginNote(url: checkout, pageTitle: "Checkout · Northwind",
                               anchor: .init(quote: "Name on card"),
                               body: "Copy: \"Cardholder name\" matches the bank's wording."))
        var answered = MarginNote(url: shop, pageTitle: "Northwind Shop", anchor: .init(quote: "Autumn essentials"),
                                  body: "Hero heading feels small next to the grid.")
        answered.replies = [.init(author: .agent("Claude Code"), body: "Bumped it to 40px and tightened the letter spacing. Take a look?")]
        list.append(answered)
        var resolved = MarginNote(url: shop, pageTitle: "Northwind Shop", anchor: .init(selector: ".grid .card:nth-child(3)"),
                                  body: "Canvas Tote swatch is too close to the background.")
        resolved.replies = [.init(author: .agent("Claude Code"), body: "Darkened the swatch to #d8d2c4 and added a border.")]
        resolved.status = .resolved
        resolved.resolvedAt = Date().addingTimeInterval(-3600)
        resolved.resolvedBy = .agent("Claude Code")
        list.append(resolved)
        list.append(MarginNote(url: cart, pageTitle: "Cart · Northwind", body: "Found while testing: the total doesn't update when an item is removed.",
                               author: .agent("Codex")))
        return list
    }

    // MARK: Agents

    /// A scripted agent session, as MCP `tools/call`s against Browsa's real tools.
    struct AgentStep {
        let tool: String
        let args: [String: Any]
    }

    static func scenario(_ name: String) -> (agent: String, steps: [AgentStep])? {
        let checkout = url(47940, "/checkout").absoluteString
        switch name {
        // A short history, so the Agents panel isn't empty on launch.
        case "history":
            return ("Claude Code", [
                .init(tool: "tabs_list", args: [:]),
                .init(tool: "notes_list", args: [:]),
                .init(tool: "page_read", args: [:]),
            ])
        // Works through the checkout notes: open, read, click, type, reply.
        case "fix-notes":
            return ("Claude Code", [
                .init(tool: "notes_list", args: ["status": "open"]),
                .init(tool: "tab_open", args: ["url": checkout]),
                .init(tool: "page_read", args: [:]),
                .init(tool: "page_click", args: ["selector": "#name"]),
                .init(tool: "page_type", args: ["selector": "#name", "text": "Ada Lovelace"]),
                .init(tool: "page_screenshot", args: [:]),
                .init(tool: "notes_add", args: ["url": checkout, "body": "Checked the pay button at 600px wide: it wraps under Save for later."]),
            ])
        // Gets refused: shows denied rows in the panel.
        case "blocked":
            return ("Codex", [
                .init(tool: "tab_open", args: ["url": "https://example.com/admin"]),
            ])
        default:
            return nil
        }
    }
}
