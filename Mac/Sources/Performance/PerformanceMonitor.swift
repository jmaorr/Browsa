import Foundation
import Observation
import WebKit
import BrowserCore

/// Watches how hard Browsa is working: CPU and memory for every tab's process and for the helpers all
/// tabs share, over the last five minutes, and which tabs are stuck.
///
/// It samples every 2 seconds while a Performance panel is open and every 10 seconds otherwise, so a
/// runaway tab is caught even with the panel closed. A sample is one system call per process.
@MainActor @Observable
final class PerformanceMonitor {
    static let shared = PerformanceMonitor()

    enum Kind: Hashable {
        /// A process running one or more tabs.
        case tabs
        case graphics, networking, browsa
        /// Extension background pages, service workers and the spare page process, added up.
        case background
    }

    struct Row: Identifiable {
        let id: pid_t
        let kind: Kind
        /// The tabs in this process, most recently used first. Sites can share a process.
        var tabIDs: [UUID]
        /// Percent of one core, as Activity Monitor counts it: 200% is two cores flat out.
        var cpu: Double
        var memory: UInt64
        /// When the process went above the stuck line, while it stays there.
        var busySince: Date?
    }

    struct Point {
        let date: Date
        let cpu: Double
        let memory: UInt64
    }

    enum Health: Equatable {
        case calm
        /// High CPU across Browsa for the last half minute, but no single tab to blame.
        case busy
        /// Browsa is holding more than half the Mac's memory.
        case heavyMemory
        /// One process has been above the stuck line for a while. Its first tab.
        case stuck(UUID)
    }

    /// A tab's process counts as stuck after this much CPU, held for `stuckAfter`.
    static let stuckCPU = 80.0
    static let stuckAfter: TimeInterval = 30
    /// How much history the charts show.
    static let window: TimeInterval = 300

    private(set) var rows: [Row] = []
    private(set) var history: [Point] = []
    private(set) var health: Health = .calm
    /// Every tab in a stuck process. The sidebar marks these.
    private(set) var stuckTabs: Set<UUID> = []
    /// Average total CPU over the last 30 seconds.
    private(set) var recentCPU: Double = 0

    /// A tab pretending to be stuck, for trying the panel out (Simulate Stuck Tab).
    private(set) var simulatedTab: UUID?

    var totalCPU: Double { history.last?.cpu ?? 0 }
    var totalMemory: UInt64 { history.last?.memory ?? 0 }
    var isSamplingFast: Bool { viewers > 0 }

    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var previous: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
    @ObservationIgnored private var busySince: [pid_t: Date] = [:]
    @ObservationIgnored private var simulationStarted: Date?
    @ObservationIgnored private var simulationEnd: Task<Void, Never>?
    private var viewers = 0

    func start(library: Library) {
        self.library = library
        restart()
    }

    func panelAppeared() {
        viewers += 1
        if viewers == 1 { restart() }
    }

    func panelDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { restart() }
    }

    func tab(_ id: UUID) -> BrowserTab? { library?.controllers[id]?.tab }

    /// Makes a loaded tab look stuck at about 110% CPU for a minute, as if it had been for 4 minutes,
    /// so the red card, the sidebar dot and Unload Tab can be tried. Picks the most recent tab that
    /// isn't on screen, so Unload Tab works on it.
    func simulateStuckTab() {
        guard let library else { return }
        let loaded = library.controllers.values.map(\.tab)
        let offScreen = loaded.filter { library.window(showing: $0) == nil && $0.call == nil }
        guard let tab = (offScreen.isEmpty ? loaded : offScreen).max(by: { $0.lastActive < $1.lastActive }) else { return }
        simulatedTab = tab.id
        simulationStarted = Date().addingTimeInterval(-240)
        simulationEnd?.cancel()
        simulationEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.endSimulation()
        }
        sample()
    }

    func endSimulation() {
        simulationEnd?.cancel()
        simulationEnd = nil
        simulatedTab = nil
        simulationStarted = nil
        sample()
    }

    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                let interval: Double = self.viewers > 0 ? 2 : 10
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.2))
            }
        }
    }

    private func sample() {
        guard let library else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let date = Date()
        let me = getpid()

        // Which process each live tab runs in, most recently used tab first.
        var tabsByProcess: [pid_t: [BrowserTab]] = [:]
        var graphics: pid_t?
        var networking: Set<pid_t> = []
        for controller in library.controllers.values {
            guard let page = controller.page, let webView = page.view as? WKWebView else { continue }
            if let pid = ProcessSampler.webProcess(of: webView) { tabsByProcess[pid, default: []].append(controller.tab) }
            if graphics == nil { graphics = ProcessSampler.graphicsProcess(of: webView) }
            if let pid = ProcessSampler.networkProcess(of: webView) { networking.insert(pid) }
        }

        var pids = Set(ProcessSampler.browsaProcesses())
        pids.formUnion(tabsByProcess.keys)
        pids.formUnion(networking)
        if let graphics { pids.insert(graphics) }

        var readings: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
        var next: [Row] = []
        var shared: [Kind: Row] = [:]
        for pid in pids {
            guard let reading = ProcessSampler.read(pid) else { continue }
            readings[pid] = (reading.cpuNanoseconds, now)
            var cpu = 0.0
            if let last = previous[pid], now > last.at, reading.cpuNanoseconds >= last.cpu {
                cpu = Double(reading.cpuNanoseconds - last.cpu) / Double(now - last.at) * 100
            }
            let kind = processKind(of: pid, me: me, tabs: tabsByProcess, graphics: graphics, networking: networking)
            if kind == .tabs {
                let tabs = (tabsByProcess[pid] ?? []).sorted { $0.lastActive > $1.lastActive }
                next.append(Row(id: pid, kind: .tabs, tabIDs: tabs.map(\.id), cpu: cpu, memory: reading.footprint))
            } else {
                // One row per kind of helper, even when there are a few of them (a networking
                // process per profile, say).
                var row = shared[kind] ?? Row(id: sharedRowID(kind), kind: kind, tabIDs: [], cpu: 0, memory: 0)
                row.cpu += cpu
                row.memory += reading.footprint
                shared[kind] = row
            }
        }
        next += shared.values.sorted { $0.id < $1.id }
        previous = readings

        // Simulating: that tab's process reads as flat out since the simulation's pretend start.
        if let simulated = simulatedTab, let started = simulationStarted {
            if let i = next.firstIndex(where: { $0.tabIDs.contains(simulated) }) {
                next[i].cpu = 104 + Double.random(in: 0...12)
                busySince[next[i].id] = started
            } else {
                // Unloaded or closed: nothing left to pretend about.
                simulatedTab = nil
                simulationStarted = nil
                simulationEnd?.cancel()
            }
        }

        // Stuck: a tab's process above the line for long enough. Calls and helpers are never "stuck".
        var stuck: Set<UUID> = []
        for i in next.indices where next[i].kind == .tabs {
            let pid = next[i].id
            if next[i].cpu >= Self.stuckCPU {
                let since = busySince[pid] ?? date
                busySince[pid] = since
                next[i].busySince = since
                if date.timeIntervalSince(since) >= Self.stuckAfter { stuck.formUnion(next[i].tabIDs) }
            } else {
                busySince[pid] = nil
            }
        }
        busySince = busySince.filter { readings[$0.key] != nil }

        let totalCPU = next.reduce(0) { $0 + $1.cpu }
        let totalMemory = next.reduce(UInt64(0)) { $0 + $1.memory }
        history.append(Point(date: date, cpu: totalCPU, memory: totalMemory))
        history.removeAll { date.timeIntervalSince($0.date) > Self.window }
        let recent = history.filter { date.timeIntervalSince($0.date) <= 30 }
        recentCPU = recent.map(\.cpu).reduce(0, +) / Double(max(1, recent.count))

        rows = next
        if stuckTabs != stuck { stuckTabs = stuck }
        let worst = next.filter { $0.kind == .tabs && !stuck.isDisjoint(with: $0.tabIDs) }.max { $0.cpu < $1.cpu }
        let newHealth: Health
        if let tab = worst?.tabIDs.first {
            newHealth = .stuck(tab)
        } else if recent.count >= 2, recentCPU >= 150 {
            newHealth = .busy
        } else if Double(totalMemory) > Double(ProcessInfo.processInfo.physicalMemory) * 0.5 {
            newHealth = .heavyMemory
        } else {
            newHealth = .calm
        }
        if health != newHealth { health = newHealth }
    }

    /// Stable, negative IDs for the shared rows, so they never clash with a process ID.
    private func sharedRowID(_ kind: Kind) -> pid_t {
        switch kind {
        case .browsa: -1
        case .graphics: -2
        case .networking: -3
        case .background, .tabs: -4
        }
    }

    private func processKind(of pid: pid_t, me: pid_t, tabs: [pid_t: [BrowserTab]], graphics: pid_t?, networking: Set<pid_t>) -> Kind {
        if tabs[pid] != nil { return .tabs }
        if pid == me { return .browsa }
        if pid == graphics { return .graphics }
        if networking.contains(pid) { return .networking }
        // When WebKit doesn't hand out the IDs, the helpers' own names still say what they are.
        let name = ProcessSampler.name(pid)
        if name.hasSuffix(".GPU") || name.contains("WebKit.GPU") { return .graphics }
        if name.contains("WebKit.Networking") { return .networking }
        return .background
    }
}
