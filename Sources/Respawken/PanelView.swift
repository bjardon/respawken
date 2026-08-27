import AppKit
import SwiftUI

/// Overview is the default. A product screen is the same grouping as the old
/// tabs — Claude still stacks Personal + Work — reached by clicking a row.
enum PanelTab: String, CaseIterable, Identifiable {
    case overview, claude, codex, cursor, notion, antigravity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L10n.t(.overview)
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .notion: return "Notion"
        case .antigravity: return "Antigravity"
        }
    }

    static func product(for provider: ProviderID) -> PanelTab {
        switch provider.rawValue {
        case ProviderID.codex.rawValue: return .codex
        case ProviderID.cursor.rawValue: return .cursor
        case ProviderID.notion.rawValue: return .notion
        case ProviderID.antigravity.rawValue: return .antigravity
        default: return .claude
        }
    }
}

struct PanelView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State var tab: PanelTab = .overview

    var body: some View {
        let _ = store.settings.language
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Group {
                switch tab {
                case .overview:
                    overviewBody
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                default:
                    productBody(providers(for: tab))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }

            Divider()
            footer
        }
        .frame(width: 320)
        .background(ResetOverviewOnOpen { tab = .overview })
    }

    private var header: some View {
        HStack(spacing: 6) {
            if tab == .overview {
                Text("respawken")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            } else {
                Button {
                    tab = .overview
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                }
                .buttonStyle(.plain)
                .help(L10n.t(.backToOverview))
            }
            Spacer()
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(L10n.t(.settings))
            if store.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(L10n.t(.refreshNow))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var overviewBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.iconOrder.isEmpty {
                Text(L10n.t(.emptyIcon))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            } else {
                ForEach(store.iconOrder) { provider in
                    Button {
                        tab = .product(for: provider)
                    } label: {
                        OverviewRow(
                            title: store.title(for: provider),
                            accent: store.accent(for: provider),
                            result: store.results[provider],
                            windowID: store.settings.iconWindowID(for: provider),
                            now: store.tick
                        )
                    }
                    .buttonStyle(OverviewRowStyle())
                    .help(L10n.t(.openProduct, PanelTab.product(for: provider).title))
                }
            }
        }
    }

    private func productBody(_ providers: [ProviderID]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if providers.isEmpty {
                Text(L10n.t(.noProductAccounts, tab.title))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providers) { provider in
                    ProviderRow(
                        title: store.title(for: provider),
                        accent: store.accent(for: provider),
                        result: store.results[provider],
                        now: store.tick
                    )
                }
            }
        }
    }

    private func providers(for tab: PanelTab) -> [ProviderID] {
        switch tab {
        case .overview: return store.iconOrder
        case .claude: return store.claudeAccounts.map(\.providerID)
        case .codex: return [.codex]
        case .cursor: return [.cursor]
        case .notion: return [.notion]
        case .antigravity: return [.antigravity]
        }
    }

    private var footer: some View {
        HStack {
            Text(lastRefreshLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(L10n.t(.quit)) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var lastRefreshLabel: String {
        guard let last = store.lastRefresh else { return L10n.t(.loading) }
        let elapsed = Int(store.tick.timeIntervalSince(last))
        if elapsed < 60 { return L10n.t(.updatedJustNow) }
        return L10n.t(.updatedAgo, Format.countdown(to: Date(), now: last))
    }
}

private struct OverviewRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OverviewRowChrome(pressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct OverviewRowChrome<Content: View>: View {
    var pressed: Bool
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(pressed ? 0.10 : hovering ? 0.06 : 0))
            )
            .onHover { hovering = $0 }
    }
}

/// One meter: the window that drives that provider's menu-bar bar.
private struct OverviewRow: View {
    let title: String
    let accent: Color
    let result: ProviderResult?
    let windowID: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let window = iconWindow {
                    Text(Format.percent(window.clamped))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(UsageLevel(percent: window.clamped).color)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            switch result?.outcome {
            case .none:
                message(L10n.t(.checking), color: .tertiary)

            case .ok:
                if let window = iconWindow {
                    Text(windowCaption(window))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Meter(fraction: window.clamped / 100, level: UsageLevel(percent: window.clamped))
                    if let resets = result?.overviewReset(preferredID: windowID, now: now) {
                        Text(L10n.t(.resetsIn, Format.countdown(to: resets, now: now)))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    } else if !window.isActive {
                        Text(L10n.t(.notStarted))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    message(L10n.display(result?.snapshot?.note ?? L10n.t(.noUsageReported)), color: .secondary)
                }

            case .signedOut(let hint):
                message(L10n.display(hint), color: .secondary)

            case .failed(let reason, _):
                message(L10n.display(reason), color: Color(red: 0.93, green: 0.35, blue: 0.32))
            }
        }
        .contentShape(Rectangle())
    }

    private var iconWindow: UsageWindow? {
        result?.iconWindow(preferredID: windowID)
    }

    private func windowCaption(_ window: UsageWindow) -> String {
        let name = L10n.windowTitle(id: window.id, stored: window.title)
        if windowID == IconWindowDefaults.nowBurning {
            return L10n.t(.nowBurningWindow, name)
        }
        return name
    }

    private func message(_ text: String, color: some ShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProviderRow: View {
    let title: String
    let accent: Color
    let result: ProviderResult?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let plan = result?.snapshot?.plan {
                    Text(plan)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(.secondary)
                }
            }

            switch result?.outcome {
            case .none:
                message(L10n.t(.checking), color: .tertiary)

            case .ok(let snapshot):
                SnapshotBody(snapshot: snapshot, now: now)

            case .signedOut(let hint):
                message(L10n.display(hint), color: .secondary)

            case .failed(let reason, _):
                message(L10n.display(reason), color: Color(red: 0.93, green: 0.35, blue: 0.32))
            }
        }
    }

    private func message(_ text: String, color: some ShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SnapshotBody: View {
    let snapshot: ProviderSnapshot
    let now: Date

    var body: some View {
        if snapshot.windows.isEmpty {
            Text(L10n.display(snapshot.note ?? L10n.t(.noUsageReported)))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else {
            let shared = sharedReset(snapshot.windows)
            ForEach(snapshot.windows) { window in
                WindowRow(window: window, now: now, showsReset: shared == nil)
            }
            if let shared {
                // Every window resets together (Cursor's billing cycle), so say it once.
                Text(L10n.t(.resetsIn, Format.countdown(to: shared, now: now)))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        if let note = snapshot.note, !snapshot.windows.isEmpty {
            Text(L10n.display(note))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        if let renews = snapshot.renewsAt {
            RenewsRow(date: renews)
        }
        if snapshot.source != "api" {
            Text(L10n.display(snapshot.source))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    /// The reset instant shared by every window that has one, when they agree.
    /// Windows without a date (idle session, 6-hour with no `resetsInSeconds`)
    /// don't block collapsing Cursor/Notion's billing cycle to one footer.
    private func sharedReset(_ windows: [UsageWindow]) -> Date? {
        let dates = windows.compactMap(\.resetsAt)
        guard dates.count > 1, let first = dates.first else { return nil }
        let same = dates.allSatisfy { abs($0.timeIntervalSince(first)) < 60 }
        return same ? first : nil
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let now: Date
    let showsReset: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(L10n.windowTitle(id: window.id, stored: window.title))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(window.clamped))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(UsageLevel(percent: window.clamped).color)
            }

            Meter(fraction: window.clamped / 100, level: UsageLevel(percent: window.clamped))

            if showsReset, let resets = window.resetsAt {
                Text(L10n.t(.resetsIn, Format.countdown(to: resets, now: now)))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else if !window.isActive {
                Text(L10n.t(.notStarted))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Dedicated fact line, same weight as "Credits left: 300".
private struct RenewsRow: View {
    let date: Date

    var body: some View {
        Text(L10n.t(.renewsOn, Format.billingDate(date)))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }
}

private struct Meter: View {
    let fraction: Double
    let level: UsageLevel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(level.color)
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 4)
    }
}

/// MenuBarExtra keeps PanelView alive after dismiss, so @State would otherwise
/// reopen on Claude. Reset on a rising edge of shown/key, not while it stays open.
private struct ResetOverviewOnOpen: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> OpenWatcher {
        let view = OpenWatcher()
        view.action = action
        return view
    }

    func updateNSView(_ view: OpenWatcher, context: Context) {
        view.action = action
    }
}

private final class OpenWatcher: NSView {
    var action: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var wasShown = false
    private var wasKey = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        wasShown = Self.isShown(window)
        wasKey = window.isKeyWindow
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.shownChanged()
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func shownChanged() {
        guard let window else { return }
        let shown = Self.isShown(window)
        let key = window.isKeyWindow
        if (shown && !wasShown) || (key && !wasKey) {
            action?()
        }
        wasShown = shown
        wasKey = key
    }

    private static func isShown(_ window: NSWindow) -> Bool {
        window.isVisible && window.occlusionState.contains(.visible)
    }
}
