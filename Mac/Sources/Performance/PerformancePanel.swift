import SwiftUI
import AppKit
import BrowserCore

/// The Performance panel: how hard Browsa is working right now, the tabs and helpers doing the work,
/// and a way out when a tab gets stuck.
struct PerformancePanel: View {
    @Environment(Browser.self) private var browser
    @State private var metric: PerformanceMetric = .cpu
    private var monitor: PerformanceMonitor { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PerformancePulse(tone: tone, beatsPerSecond: beatsPerSecond, title: headline, detail: detail)
                HStack(spacing: 8) {
                    PerformanceTotal(title: "CPU", value: PerformanceFormat.cpu(monitor.totalCPU),
                                     values: monitor.history.map(\.cpu), floor: 100, tint: tone,
                                     selected: metric == .cpu) { metric = .cpu }
                    PerformanceTotal(title: "Memory", value: PerformanceFormat.memory(monitor.totalMemory),
                                     values: monitor.history.map { Double($0.memory) }, floor: 0, tint: .accentColor,
                                     selected: metric == .memory) { metric = .memory }
                }
                Text("Using the Most")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 4)
                VStack(spacing: 2) {
                    ForEach(sortedRows) { row in
                        PerformanceRowView(row: row, metric: metric, scale: scale,
                                           isStuck: !monitor.stuckTabs.isDisjoint(with: row.tabIDs))
                    }
                }
                .animation(Motion.snappy, value: sortedRows.map(\.id))
                Text(monitor.isSamplingFast ? "Updates every 2 seconds. Charts show the last 5 minutes."
                                            : "Updates every 10 seconds.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(12)
        }
        .onAppear { monitor.panelAppeared() }
        .onDisappear { monitor.panelDisappeared() }
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

    /// The pulse follows the load: a slow beat at rest, quicker as CPU climbs.
    private var beatsPerSecond: Double {
        if case .stuck = monitor.health { return 1.9 }
        return 0.7 + min(monitor.recentCPU, 200) / 200 * 1.1
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

// MARK: - Pulse

/// The status card: a heartbeat line running across it in the status colour, with a soft glow behind.
/// Calm is a slow, low beat; a stuck tab makes it quick and tall.
struct PerformancePulse: View {
    let tone: Color
    let beatsPerSecond: Double
    let title: String
    let detail: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                Canvas { g, size in
                    let mid = size.height * 0.36
                    let amplitude = size.height * (beatsPerSecond > 1.6 ? 0.30 : 0.14 + 0.08 * (beatsPerSecond - 0.7) / 1.1)
                    let period = size.width * (beatsPerSecond > 1.6 ? 0.34 : 0.55)
                    var path = Path()
                    for x in stride(from: 0.0, through: size.width, by: 2) {
                        let u = (x / period - time * beatsPerSecond * 0.5).truncatingRemainder(dividingBy: 1)
                        let y = mid - Self.beat(u < 0 ? u + 1 : u) * amplitude
                        if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    g.stroke(path, with: .linearGradient(Gradient(colors: [tone.opacity(0), tone.opacity(0.65), tone]),
                                                         startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                             style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tone)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .bottomLeading)
        .background {
            RadialGradient(colors: [tone.opacity(0.26), .clear], center: .topTrailing, startRadius: 0, endRadius: 220)
        }
        .background(.primary.opacity(0.03))
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)) }
        .animation(.easeInOut(duration: 0.6), value: title)
        .accessibilityElement(children: .combine)
    }

    /// One heartbeat over 0...1: a small bump, a dip, the spike, and back to flat.
    static func beat(_ u: Double) -> Double {
        switch u {
        case ..<0.08: sin(u / 0.08 * .pi) * 0.25
        case ..<0.12: -(u - 0.08) / 0.04 * 0.35
        case ..<0.16: -0.35 + (u - 0.12) / 0.04 * 1.35
        case ..<0.20: 1 - (u - 0.16) / 0.04 * 1.2
        case ..<0.24: -0.2 + (u - 0.20) / 0.04 * 0.2
        default: 0
        }
    }
}

// MARK: - Totals

/// A total with a little chart of the last five minutes under it. Clicking it sorts the list by it.
struct PerformanceTotal: View {
    let title: String
    let value: String
    let values: [Double]
    /// The chart's top is at least this, so a quiet minute doesn't look like a mountain.
    let floor: Double
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                Sparkline(values: values, top: max(floor, (values.max() ?? 0) * 1.15), tint: tint)
                    .frame(height: 30)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary.opacity(0.04)),
                        in: .rect(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.primary.opacity(selected ? 0.1 : 0))
            }
            .contentShape(.rect(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                Text(metric == .cpu ? PerformanceFormat.cpu(row.cpu) : PerformanceFormat.memory(row.memory))
                    .monospacedDigit()
                    .font(.system(size: 12, weight: isStuck ? .semibold : .regular))
                    .foregroundStyle(isStuck ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
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
