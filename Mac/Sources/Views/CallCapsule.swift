import SwiftUI
import BrowserCore

/// While you're in a call and looking at another tab, a small glass capsule floats over the corner of the
/// page with the call's icon and name. Clicking it goes back to the call, switching space or window if it
/// has to. Hovering shows a close button that hides it until the next call.
struct CallCapsule: View {
    @Environment(Browser.self) private var browser
    /// The call you hid the capsule for. A new call (another tab) brings it back.
    @State private var hiddenFor: UUID?
    @State private var hovering = false

    /// The call to lead back to: a tab in a call that no window is showing right now.
    private var call: BrowserTab? {
        let library = browser.library
        return library.allTabs
            .filter { $0.call != nil && library.window(showing: $0) == nil }
            .max { $0.lastActive < $1.lastActive }
    }

    var body: some View {
        ZStack {
            // While the call floats in its own window (CallPiP), that window leads back instead.
            if let tab = call, let state = tab.call, tab.id != hiddenFor, tab.id != browser.library.pipTabID {
                capsule(tab, state)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: call?.id)
        .animation(Motion.snappy, value: hiddenFor)
        .animation(Motion.snappy, value: browser.library.pipTabID)
    }

    private func capsule(_ tab: BrowserTab, _ state: TabCall) -> some View {
        HStack(spacing: 8) {
            if hovering {
                Button {
                    hiddenFor = tab.id
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(.primary.opacity(0.08), in: .circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide until the next call")
                .transition(.scale.combined(with: .opacity))
            }
            TabIcon(tab: tab, size: 16)
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .leading)
                .foregroundStyle(.primary)
            CallBadge(call: state)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 7)
        // Glass alone lets busy pages show through the text; a material under it keeps it legible.
        .background(.regularMaterial, in: .capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .contentShape(.capsule)
        .onTapGesture { browser.select(tab) }
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Back to call: \(tab.displayTitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { browser.select(tab) }
        .accessibilityAction(named: "Hide Until the Next Call") { hiddenFor = tab.id }
    }
}
