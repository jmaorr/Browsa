import SwiftUI

/// The sidebar's mark for a stuck tab: a red dot that slides open into its CPU figure ("110%") when
/// you point at the tab. A click opens the Performance panel, where Unload Tab and Reload are.
struct StuckTabBadge: View {
    @Environment(Browser.self) private var browser
    let tabID: UUID
    /// Open, with the figure: while the pointer is over the tab.
    let expanded: Bool

    var body: some View {
        Button {
            if browser.panel != "performance" { browser.showPanel("performance") }
        } label: {
            HStack(spacing: 3) {
                if expanded {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 9, weight: .bold))
                    Text(PerformanceFormat.cpu(PerformanceMonitor.shared.cpu(forTab: tabID) ?? PerformanceMonitor.stuckCPU))
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, expanded ? 6 : 0)
            .frame(minWidth: 7, minHeight: 7)
            .frame(height: expanded ? 16 : 7)
            .background(Color.red, in: .capsule)
            .frame(minWidth: 16, minHeight: 16)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("This tab is using a lot of CPU. Click to see it in Performance.")
        .animation(Motion.snappy, value: expanded)
        .accessibilityLabel("High CPU. Show in Performance.")
    }
}
