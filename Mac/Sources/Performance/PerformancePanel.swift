import SwiftUI
import AppKit
import BrowserCore

/// The Performance panel: how hard Browsa is working right now, the tabs and helpers doing the work,
/// and a way out when a tab gets stuck.
struct PerformancePanel: View {
    @Environment(Browser.self) private var browser
    /// What you picked in Sort by, until the panel closes. Nil follows the load: memory, which is
    /// steadier, unless Browsa is busy or a tab is stuck, then CPU.
    @State private var chosenMetric: PerformanceMetric?
    private var metric: PerformanceMetric {
        if let chosenMetric { return chosenMetric }
        switch monitor.health {
        case .busy, .stuck: return .cpu
        case .calm, .heavyMemory: return .memory
        }
    }
    private var monitor: PerformanceMonitor { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PerformanceStatusCard(level: level, speed: glowSpeed, title: headline, detail: detail)
                HStack(spacing: 8) {
                    PerformanceTotal(title: "CPU", value: PerformanceFormat.cpu(monitor.totalCPU),
                                     values: monitor.history.map(\.cpu), floor: 100, tint: tone)
                    PerformanceTotal(title: "Memory", value: PerformanceFormat.memory(monitor.totalMemory),
                                     values: monitor.history.map { Double($0.memory) }, floor: 0, tint: .accentColor)
                }
                HStack {
                    Text("Using the Most")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    GlassTabs(selection: Binding(get: { metric }, set: { chosenMetric = $0 }), options: [.cpu, .memory], size: .small) { $0 == .cpu ? "CPU" : "Memory" }
                        .help("Sort by")
                }
                .padding(.top, 4)
                VStack(spacing: 2) {
                    ForEach(sortedRows) { row in
                        PerformanceRowView(row: row, metric: metric, scale: scale,
                                           isStuck: !monitor.stuckTabs.isDisjoint(with: row.tabIDs))
                    }
                }
                .animation(Motion.snappy, value: sortedRows.map(\.id))
                HStack(alignment: .firstTextBaseline) {
                    Text(monitor.isSamplingFast ? "Updates every 2 seconds. Charts show the last 5 minutes."
                                                : "Updates every 10 seconds.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Button(monitor.simulatedTab == nil ? "Simulate Stuck Tab" : "Stop Simulation") {
                        withAnimation(Motion.snappy) {
                            if monitor.simulatedTab == nil { monitor.simulateStuckTab() } else { monitor.endSimulation() }
                        }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("Pretends a background tab is stuck at 110% CPU for a minute, to show what happens")
                }
                .padding(.top, 4)
            }
            .padding(12)
        }
        .onAppear { monitor.panelAppeared() }
        .onDisappear { monitor.panelDisappeared() }
    }

    /// 0 calm (green), 1 busy (amber), 2 stuck (red). The card's colours slide between them.
    private var level: Double {
        switch monitor.health {
        case .calm: 0
        case .busy, .heavyMemory: 1
        case .stuck: 2
        }
    }

    /// The card drifts slowly at rest and quicker under load.
    private var glowSpeed: Double {
        if case .stuck = monitor.health { return 3 }
        return 1 + min(monitor.recentCPU, 200) / 200
    }

    /// Stuck tabs first, then by whichever total is selected.
    private var sortedRows: [PerformanceMonitor.Row] {
        let stuck = monitor.stuckTabs
        return monitor.rows.sorted { a, b in
            let sa = !stuck.isDisjoint(with: a.tabIDs), sb = !stuck.isDisjoint(with: b.tabIDs)
            if sa != sb { return sa }
            return metric == .cpu ? a.cpu > b.cpu : a.memory > b.memory
        }
    }

    /// The longest bar is the busiest row, never shorter than a full core or 500 MB.
    private var scale: Double {
        let top = monitor.rows.map { metric == .cpu ? $0.cpu : Double($0.memory) }.max() ?? 0
        return max(top, metric == .cpu ? 100 : 500_000_000)
    }

    private var tone: Color {
        switch monitor.health {
        case .calm: .green
        case .busy, .heavyMemory: .orange
        case .stuck: .red
        }
    }

    private var headline: String {
        switch monitor.health {
        case .calm: "All calm"
        case .busy: "Busy"
        case .heavyMemory: "Using a lot of memory"
        case .stuck(let id): "\(monitor.tab(id)?.displayTitle ?? "A tab") is stuck"
        }
    }

    private var detail: String {
        switch monitor.health {
        case .calm:
            let count = monitor.rows.reduce(0) { $0 + $1.tabIDs.count }
            return count == 1 ? "1 tab loaded, nothing working hard" : "\(count) tabs loaded, nothing working hard"
        case .busy:
            return "\(PerformanceFormat.cpu(monitor.recentCPU)) CPU over the last 30 seconds"
        case .heavyMemory:
            return "\(PerformanceFormat.memory(monitor.totalMemory)) of your Mac's \(PerformanceFormat.memory(ProcessInfo.processInfo.physicalMemory))"
        case .stuck(let id):
            guard let row = monitor.rows.first(where: { $0.tabIDs.contains(id) }) else { return "" }
            var text = "\(PerformanceFormat.cpu(row.cpu)) CPU"
            if let since = row.busySince { text += " for \(PerformanceFormat.duration(since))" }
            if let tab = monitor.tab(id), browser.library.window(showing: tab) == nil { text += ", in the background" }
            return text
        }
    }
}

enum PerformanceMetric { case cpu, memory }

enum PerformanceFormat {
    static func cpu(_ percent: Double) -> String { "\(Int(percent.rounded()))%" }
    static func memory(_ bytes: UInt64) -> String { Int64(bytes).formatted(.byteCount(style: .memory)) }
    static func duration(_ since: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        return seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min"
    }
}

// MARK: - Status card

/// The status card: a living gradient drawn by a Metal shader (PerformanceGlow.metal) in the status
/// colour, green at rest, amber when busy, red when a tab is stuck.
struct PerformanceStatusCard: View, @MainActor Animatable {
    /// 0 green, 1 amber, 2 red; animates, so the colours blend across a change.
    var level: Double
    let speed: Double
    let title: String
    let detail: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = GlowClock()

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    var body: some View {
        let shades = Self.shades(level)
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    let t = clock.advance(to: context.date, speed: reduceMotion ? 0 : speed)
                    Rectangle()
                        .colorEffect(ShaderLibrary.performanceGlow(
                            .float2(proxy.size), .float(t),
                            .float3(shades.deep.x, shades.deep.y, shades.deep.z),
                            .float3(shades.mid.x, shades.mid.y, shades.mid.z),
                            .float3(shades.bright.x, shades.bright.y, shades.bright.z)))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
            }
            .shadow(color: .black.opacity(0.18), radius: 6, y: 1)
            .padding(14)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .bottomLeading)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)) }
        .accessibilityElement(children: .combine)
    }

    typealias Shades = (deep: SIMD3<Float>, mid: SIMD3<Float>, bright: SIMD3<Float>)

    /// Deep, mid and bright for each status, chosen dark enough at the bottom for white text.
    private static let green: Shades = ([0.02, 0.16, 0.10], [0.05, 0.50, 0.30], [0.50, 0.95, 0.62])
    private static let amber: Shades = ([0.22, 0.10, 0.02], [0.78, 0.45, 0.05], [1.00, 0.84, 0.38])
    private static let red: Shades = ([0.24, 0.03, 0.05], [0.78, 0.14, 0.17], [1.00, 0.52, 0.42])

    static func shades(_ level: Double) -> Shades {
        let (a, b, f) = level <= 1 ? (green, amber, Float(max(0, level))) : (amber, red, Float(min(1, level - 1)))
        func mix(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> { x + (y - x) * f }
        return (mix(a.deep, b.deep), mix(a.mid, b.mid), mix(a.bright, b.bright))
    }
}

/// The shader's own clock. Speed changes bend how fast it runs from now on, without a jump, and it
/// starts near zero so the shader's floats stay precise.
final class GlowClock {
    private var last: Date?
    private var phase: Double = 0

    func advance(to date: Date, speed: Double) -> Double {
        if let last { phase += min(0.1, max(0, date.timeIntervalSince(last))) * speed }
        last = date
        return phase.truncatingRemainder(dividingBy: 10_000)
    }
}

// MARK: - Totals

/// A total with a little chart of the last five minutes under it.
struct PerformanceTotal: View {
    let title: String
    let value: String
    let values: [Double]
    /// The chart's top is at least this, so a quiet minute doesn't look like a mountain.
    let floor: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            Sparkline(values: values, top: max(floor, (values.max() ?? 0) * 1.15), tint: tint)
                .frame(height: 30)
                .padding(.top, 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A filled line chart with its newest point marked.
struct Sparkline: View {
    let values: [Double]
    let top: Double
    let tint: Color

    var body: some View {
        Canvas { g, size in
            guard values.count > 1, top > 0 else { return }
            let step = size.width / CGFloat(values.count - 1)
            let points = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step, y: size.height - 2 - (size.height - 4) * CGFloat(min(v, top) / top))
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            g.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.22), tint.opacity(0.02)]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            g.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            if let last = points.last {
                g.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(tint))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Rows

struct PerformanceRowView: View {
    @Environment(Browser.self) private var browser
    let row: PerformanceMonitor.Row
    let metric: PerformanceMetric
    let scale: Double
    let isStuck: Bool
    @State private var showingInfo = false
    @State private var hovering = false

    private var monitor: PerformanceMonitor { .shared }
    private var tabs: [BrowserTab] { row.tabIDs.compactMap { monitor.tab($0) } }
    private var value: Double { metric == .cpu ? row.cpu : Double(row.memory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon.frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(title).lineLimit(1)
                        if row.kind != .tabs { infoButton }
                        if let subtitle {
                            Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    meter
                }
                Spacer(minLength: 4)
                // Both figures, the one the list is sorted by in the main text colour.
                Text(PerformanceFormat.cpu(row.cpu))
                    .font(.system(size: 12, weight: isStuck ? .semibold : .regular))
                    .foregroundStyle(isStuck ? AnyShapeStyle(.red) : metric == .cpu ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(minWidth: 34, alignment: .trailing)
                Text(PerformanceFormat.memory(row.memory))
                    .font(.system(size: 12))
                    .foregroundStyle(metric == .memory ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(minWidth: 58, alignment: .trailing)
            }
            .monospacedDigit()
            if isStuck, let tab = tabs.first { actions(for: tab) }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(background, in: .rect(cornerRadius: 9, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { if let tab = tabs.first { browser.select(tab) } }
        .help(row.kind == .tabs ? "Show this tab" : "")
    }

    private var background: AnyShapeStyle {
        if isStuck { return AnyShapeStyle(.red.opacity(0.12)) }
        return AnyShapeStyle(.primary.opacity(hovering && row.kind == .tabs ? 0.06 : 0))
    }

    @ViewBuilder private var icon: some View {
        if let tab = tabs.first {
            TabIcon(tab: tab, size: 16)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(.primary.opacity(0.07), in: .rect(cornerRadius: 4.5, style: .continuous))
        }
    }

    private var meter: some View {
        GeometryReader { proxy in
            Capsule().fill(.primary.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(isStuck ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary.opacity(0.6)))
                        .frame(width: max(2, proxy.size.width * min(1, value / max(scale, 1))))
                }
        }
        .frame(height: 4)
        .animation(Motion.snappy, value: value)
    }

    private var infoButton: some View {
        Button { showingInfo.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("What's this?")
        .popover(isPresented: $showingInfo, arrowEdge: .leading) {
            Text(info + " It's shared by all your tabs, so it isn't counted against any one of them.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
        }
    }

    private func actions(for tab: BrowserTab) -> some View {
        let onScreen = browser.library.window(showing: tab) != nil
        let inCall = tab.call != nil
        return HStack(spacing: 6) {
            Button("Unload Tab") {
                withAnimation(Motion.snappy) {
                    for id in row.tabIDs { browser.library.unload(id) }
                }
                browser.showToast(row.tabIDs.count == 1 ? "Unloaded. It reloads when you go back to it."
                                                         : "Unloaded \(row.tabIDs.count) tabs. They reload when you go back to them.")
            }
            .buttonStyle(.glassProminent)
            .disabled(onScreen || inCall)
            .help(inCall ? "This tab is in a call" : onScreen ? "This tab is on screen. Reload it instead." : "Frees its CPU and memory. The tab stays in the sidebar.")
            Button("Reload") { browser.library.controllers[tab.id]?.page.reload() }
                .buttonStyle(.glass)
            if !onScreen {
                Button("Show Tab") { browser.select(tab) }
                    .buttonStyle(.glass)
            }
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .padding(.leading, 24)
    }

    private var title: String {
        switch row.kind {
        case .tabs: tabs.first?.displayTitle ?? "Tab"
        case .graphics: "Graphics and Media"
        case .networking: "Networking"
        case .browsa: "Browsa"
        case .background: "Extensions and Background"
        }
    }

    private var subtitle: String? {
        switch row.kind {
        case .tabs:
            var parts: [String] = []
            if row.tabIDs.count > 1 { parts.append("and \(row.tabIDs.count - 1) more") }
            if isStuck, let since = row.busySince { parts.append(PerformanceFormat.duration(since)) }
            return parts.isEmpty ? nil : "· " + parts.joined(separator: ", ")
        default: return nil
        }
    }

    private var symbol: String {
        switch row.kind {
        case .graphics: "play.rectangle"
        case .networking: "arrow.up.arrow.down"
        case .browsa: "macwindow"
        case .background, .tabs: "puzzlepiece.extension"
        }
    }

    private var info: String {
        switch row.kind {
        case .graphics: "Draws pages and plays video for every tab, so it gets busy while video plays."
        case .networking: "Loads pages, images and files for every tab."
        case .browsa: "The app itself: the sidebar, windows, panels and settings."
        case .background: "Extensions running in the background, sites' service workers, and a spare page process Browsa keeps ready so new tabs open quickly."
        case .tabs: ""
        }
    }
}
