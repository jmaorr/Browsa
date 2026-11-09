#if DEBUG
import AppKit
import SwiftUI

/// Debug only: with BROWSA_RADAR_CHECK=<folder>, waits for Radar to find dev servers, logs what it
/// found, then walks the card, pill, panel, Stop and Restart. At each stage it writes
/// `<stage>.ready` (holding the window number) and waits for `<stage>.done`, so a script outside
/// the sandbox can `screencapture -l` the window. Stop and Restart only run with
/// BROWSA_RADAR_CHECK_STOP=<port>, on that server.
@MainActor
struct RadarCheck {
    let directory: URL
    let delegate: AppDelegate

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var waited = 0.0
        while delegate.browser?.nsWindow == nil, waited < 20 { await pause(0.5); waited += 0.5 }
        guard let browser = delegate.browser, let window = browser.nsWindow else { note("no window"); exit(1) }
        let store = RadarStore.shared
        UserDefaults.standard.set("", forKey: "expandedToolSections")

        await until(15) { store.hasRunning }
        await pause(3)
        note("mode: \(RadarScanner.mode == .processes ? "processes" : "ports")")
        for s in store.servers {
            var launch = "-"
            if let l = s.launch {
                let command: String = ([l.executable] + l.arguments).joined(separator: " ")
                let group: String = l.processGroup.map { String($0) } ?? "-"
                launch = "\(command) in \(l.directory) group=\(group)"
            }
            let root: String = s.root ?? "-"
            note(":\(s.port) project=\(s.project) branch=\(s.branch) worktree=\(s.isWorktree) framework=\(s.framework) up=\(s.isUp) root=\(root) launch=\(launch)")
        }
        await stage("card-collapsed", window)

        UserDefaults.standard.set("radar", forKey: "expandedToolSections")
        await pause(1)
        await stage("card-expanded", window)

        let worktree = store.servers.first { $0.isWorktree && $0.isUp }
        let main = store.servers.first { !$0.isWorktree && $0.isUp }
        for (name, server) in [("pill-main", main), ("pill-worktree", worktree)] {
            guard let server else { continue }
            RadarOpen.open(server, in: browser)
            await pause(3)
            await stage(name, window)
        }
        // Picking a server whose tab is open goes to that tab, not a new one.
        if let main {
            let before = browser.library.allTabs.count
            RadarOpen.open(main, in: browser)
            await pause(1)
            note("open again: tabs \(before) -> \(browser.library.allTabs.count), current is :\(browser.currentTab?.url?.port ?? 0)")
        }
        note("⌘K: \(browser.availableCommands().filter { $0.id.hasPrefix("tool:radar:open-") }.map(\.title))")

        browser.showPanel("radar")
        await pause(1.5)
        await stage("panel", window)
        browser.showPanel("radar", toggles: true)

        if let raw = ProcessInfo.processInfo.environment["BROWSA_RADAR_CHECK_STOP"], let port = Int(raw),
           let server = store.servers.first(where: { $0.port == port }) {
            RadarOpen.open(server, in: browser)
            await pause(1)
            note("stopping :\(port)")
            store.stop(server)
            await until(10) { store.servers.first { $0.port == port }?.isUp == false }
            await pause(1)
            note("after stop: up=\(store.servers.first { $0.port == port }?.isUp ?? true), card shown=\(store.hasRunning)")
            await stage("stopped", window)
            if let stopped = store.servers.first(where: { $0.port == port }), store.canRestart(stopped) {
                store.restart(stopped, in: browser)
                await pause(0.3)
                await stage("restarting", window)
                await until(20) { store.servers.first { $0.port == port }?.isUp == true }
                await pause(2)
                note("after restart: up=\(store.servers.first { $0.port == port }?.isUp ?? false)")
                await stage("restarted", window)
            } else {
                note("can't restart :\(port)")
            }
        }
        exit(0)
    }

    private func stage(_ name: String, _ window: NSWindow) async {
        let ready = directory.appending(path: "\(name).ready")
        let done = directory.appending(path: "\(name).done")
        try? FileManager.default.removeItem(at: done)
        try? "\(window.windowNumber)".write(to: ready, atomically: true, encoding: .utf8)
        note("stage \(name)")
        await until(15) { FileManager.default.fileExists(atPath: done.path) }
        try? FileManager.default.removeItem(at: ready)
    }

    private func until(_ seconds: Double, _ condition: () -> Bool) async {
        var waited = 0.0
        while !condition(), waited < seconds { await pause(0.25); waited += 0.25 }
    }

    private func note(_ line: String) { FileHandle.standardError.write(Data("[radar] \(line)\n".utf8)) }
    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
}
#endif
