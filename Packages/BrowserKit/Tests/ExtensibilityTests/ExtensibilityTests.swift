import Foundation
import Testing
@testable import Extensibility

@Suite struct SourceTests {
    @Test func recognisesStoreLinks() {
        #expect(ExtensionSource(link: "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh")
                == .chromeWebStore(id: "ddkjiahejlhfcafbddmgiahcphecmpfh"))
        #expect(ExtensionSource(link: "ddkjiahejlhfcafbddmgiahcphecmpfh") == .chromeWebStore(id: "ddkjiahejlhfcafbddmgiahcphecmpfh"))
        #expect(ExtensionSource(link: "https://addons.mozilla.org/en-US/firefox/addon/darkreader/") == .firefoxAddons(slug: "darkreader"))
        #expect(ExtensionSource(link: "https://example.com/detail/x") == nil)
    }

    @Test func escapesTheInnerQueryOfAnUpdateCheck() {
        let url = ChromeWebStore.updateCheckURL(ids: ["abc"]).absoluteString
        #expect(url.contains("x=id%3Dabc%26uc"))
        #expect(url.contains("response=updatecheck"))
    }

    @Test func comparesVersions() {
        #expect(isVersion("1.2.10", newerThan: "1.2.9"))
        #expect(!isVersion("1.2", newerThan: "1.2.0"))
        #expect(isVersion("2", newerThan: "1.99.99"))
    }
}

@Suite struct PackageTests {
    @Test func readsTheUpdateManifest() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
          <app appid="abc" status="ok">
            <updatecheck codebase="https://example.com/abc.crx" version="1.4.2" hash_sha256="ff" status="ok"/>
          </app>
          <app appid="gone" status="error-unknownApplication"/>
        </gupdate>
        """
        let r = UpdateManifestParser.parse(Data(xml.utf8))
        #expect(r == [StoreRelease(id: "abc", version: "1.4.2", downloadURL: URL(string: "https://example.com/abc.crx")!, sha256: "ff")])
    }

    @Test func unwrapsCRX3() throws {
        let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 1, 2, 3]
        let header: [UInt8] = [9, 9, 9, 9, 9]
        var crx = Array("Cr24".utf8) + [3, 0, 0, 0] + [UInt8(header.count), 0, 0, 0] + header
        crx += zip
        #expect(try CRX.zipPayload(of: Data(crx)) == Data(zip))
        #expect(try CRX.zipPayload(of: Data(zip)) == Data(zip))
        #expect(throws: CRX.Failure.notACRX) { try CRX.zipPayload(of: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])) }
    }

    @Test func readsAFirefoxRelease() throws {
        let json = """
        {"slug":"darkreader","current_version":{"version":"4.9.99","file":{"url":"https://addons.mozilla.org/x.xpi","hash":"sha256:abcd"}}}
        """
        let r = try FirefoxAddons.release(from: Data(json.utf8))
        #expect(r.version == "4.9.99")
        #expect(r.sha256 == "abcd")
    }
}

@Suite struct ManifestTests {
    @Test func readsPermissionsPanelAndBrowsaBlock() throws {
        let json = """
        {
          "manifest_version": 3, "name": "Radar", "version": "1.0",
          "permissions": ["storage", "tabs"], "host_permissions": ["http://localhost/*"],
          "side_panel": {"default_path": "panel.html"},
          "background": {"service_worker": "bg.js", "type": "module"},
          "browsa": {
            "sidebar": {"page": "radar.html", "title": "Dev servers"},
            "commands": [{"id": "open", "title": "Open dev server"}],
            "agentTools": [{"name": "dev_servers", "description": "List servers"}, {"name": "bad name!"}]
          }
        }
        """
        let m = try ExtensionManifest(data: Data(json.utf8))
        #expect(m.permissions == ["storage", "tabs"])
        #expect(m.hostPermissions == ["http://localhost/*"])
        #expect(m.panelPath == "panel.html")
        #expect(m.background == .serviceWorker(path: "bg.js", isModule: true))
        #expect(m.browsa?.agentTools.map(\.name) == ["dev_servers"])
        #expect(m.allPermissions.contains("browsa.sidebar"))
        #expect(m.allPermissions.contains("browsa.agentTools"))
    }

    @Test func pluginRequests() {
        let r = PluginRequest(message: ["method": "badge.set", "params": ["text": "3"]])
        #expect(r?.method == .setBadge)
        #expect(r?.params["text"]?.string == "3")
        #expect(PluginRequest(message: ["method": "nope"]) == nil)
    }
}

@MainActor @Suite struct MarginTests {
    @Test func matchesPagesLoosely() {
        #expect(MarginStore.pageKey(URL(string: "https://www.Example.com/a/?utm=1#top")!) == "https://example.com/a")
        // On localhost the query is part of what's being reviewed.
        #expect(MarginStore.pageKey(URL(string: "http://localhost:4322/x?step=2")!) == "http://localhost:4322/x?step=2")
    }

    @Test func agentsResolveNotes() {
        let store = MarginStore(fileURL: nil)
        let url = URL(string: "http://localhost:4322/library")!
        let note = store.add(MarginNote(url: url, pageTitle: "Library", anchor: .init(quote: "Featured"), body: "Card sits 14px low"))
        #expect(store.openNotes(under: "http://localhost:4322").count == 1)
        store.resolve(note.id, by: .agent("Claude Code"), comment: "Fixed the badge margin")
        #expect(store.openNotes().isEmpty)
        #expect(store.notes(on: url).first?.replies.first?.author == .agent("Claude Code"))
        #expect(store.markdown(for: url).contains("- [x] Card sits 14px low"))
    }
}

@MainActor @Suite struct ToolboxTests {
    func call(_ box: AgentToolbox, _ json: String) async throws -> JSONValue {
        let data = try #require(await box.handle(Data(json.utf8)))
        return try JSONValue(data: data)
    }

    @Test func initializeListAndCall() async throws {
        let box = AgentToolbox(serverVersion: "1.0")
        box.register(AgentTool(name: "echo", title: "Echo", description: "Says it back", readOnly: true) { args, caller in
            .text("\(caller.name): \(args["text"]?.string ?? "")")
        })
        let hello = try await call(box, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"Claude Code","version":"2"}}}"#)
        #expect(hello["result"]?["serverInfo"]?["name"]?.string == "Browsa")
        #expect(await box.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        let list = try await call(box, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(list["result"]?["tools"]?.array?.first?["name"]?.string == "echo")
        let out = try await call(box, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        #expect(out["result"]?["content"]?.array?.first?["text"]?.string == "Claude Code: hi")
        let missing = try await call(box, #"{"jsonrpc":"2.0","id":4,"method":"nope"}"#)
        #expect(missing["error"]?["code"]?.int == -32601)
    }

    @Test func refusedToolsReportIt() async throws {
        let box = AgentToolbox(serverVersion: "1.0")
        box.register(AgentTool(name: "click", title: "Click", description: "", readOnly: false) { _, _ in .text("clicked") })
        box.authorize = { _, _, _ in .deny("The user declined this in Browsa.") }
        let out = try await call(box, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click"}}"#)
        #expect(out["result"]?["isError"]?.bool == true)
        #expect(out["result"]?["content"]?.array?.first?["text"]?.string == "The user declined this in Browsa.")
    }

    @Test func readsAreAskedToo() async throws {
        let box = AgentToolbox(serverVersion: "1.0")
        var ran = false
        box.register(AgentTool(name: "read", title: "Read", description: "", readOnly: true) { _, _ in ran = true; return .text("secret") })
        var asked: [String] = []
        box.authorize = { tool, _, _ in asked.append(tool.name); return .deny("no") }
        let out = try await call(box, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read"}}"#)
        #expect(asked == ["read"])
        #expect(!ran)
        #expect(out["result"]?["isError"]?.bool == true)
    }

    @Test func stopEndsARunningCallAtOnce() async throws {
        let box = AgentToolbox(serverVersion: "1.0")
        var cancelled = false
        box.register(AgentTool(name: "slow", title: "Slow", description: "", readOnly: true) { _, _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true; throw error }
            return .text("done")
        })
        var outcomes: [AgentActivity.Outcome] = []
        box.onActivity = { outcomes.append($0.outcome) }
        let pending = Task { try await call(box, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow"}}"#) }
        while !box.hasRunningCalls { await Task.yield() }
        let started = ContinuousClock.now
        box.stopAll()
        let out = try await pending.value
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(out["result"]?["content"]?.array?.first?["text"]?.string == AgentToolbox.stoppedMessage)
        #expect(outcomes.last == .stopped)
        #expect(!box.hasRunningCalls)
        await Task.yield()
        #expect(cancelled)
    }
}

@Suite struct AgentAccessTests {
    @Test func agentSpaceNeverAsksYourTabsAlwaysDo() {
        let id = UUID()
        #expect(AgentAccess.grants(target: nil).isEmpty)
        #expect(AgentAccess.grants(target: .init(tabID: id, host: "bank.example", inAgentSpace: true)).isEmpty)
        #expect(AgentAccess.grants(target: .init(tabID: id, host: "mail.google.com", inAgentSpace: false)) == [.yourTab(id, host: "mail.google.com")])
        // Even your own dev server, when it's your tab.
        #expect(AgentAccess.grants(target: .init(tabID: id, host: "localhost", inAgentSpace: false)) == [.yourTab(id, host: "localhost")])
    }

    @Test func loopbackIsThisMacOnly() {
        for h in ["localhost", "app.localhost", "127.0.0.1", "127.1.2.3", "::1", "[::1]"] { #expect(AgentAccess.isLoopback(h), "\(h)") }
        for h in ["router.local", "localhost.evil.com", "127.0.0.1.evil.com", "10.0.0.1", "", "1270.0.0.1"] { #expect(!AgentAccess.isLoopback(h), "\(h)") }
    }
}

@Suite struct PluginAPITests {
    @Test func newMethodsParse() {
        #expect(PluginRequest(message: ["method": "page.current"])?.method == .currentPage)
        #expect(PluginRequest(message: ["method": "browsa.info"])?.method == .info)
        #expect(PluginRequest(message: ["method": "panel.show", "params": ["id": "notes"]])?.params["id"]?.string == "notes")
    }

    @Test func sampleManifestHasABrowsaBlock() throws {
        let json: JSONValue = [
            "manifest_version": 3, "name": "Hello", "version": "1",
            "permissions": ["nativeMessaging"],
            "browsa": ["panel": ["page": "panel.html", "title": "Hello", "icon": "hand.wave"],
                       "commands": [["id": "a", "title": "A"]]],
        ]
        let m = try ExtensionManifest(json: json)
        #expect(m.browsa?.panel?.icon == "hand.wave")
        #expect(m.browsa?.commands == [BrowsaBlock.Command(id: "a", title: "A")])
    }
}
