import AppKit
import SwiftUI

/// Product tabs sit beside Overview. Claude is one product even when Personal
/// and Work are separate icon meters — that's the grouping to try.
enum PanelTab: String, CaseIterable, Identifiable {
    case overview, claude, codex, cursor, notion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .notion: return "Notion"
        }
    }

    static func product(for provider: ProviderID) -> PanelTab {
        switch provider.rawValue {
        case ProviderID.codex.rawValue: return .codex
        case ProviderID.cursor.rawValue: return .cursor
        case ProviderID.notion.rawValue: return .notion
        default: return .claude
        }
    }
}

struct PanelView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State var tab: PanelTab = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            Divider()

            Group {
                switch tab {
                case .overview:
                    overviewBody
                default:
                    productBody(providers(for: tab))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("respawken")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Settings")
            if store.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(PanelTab.allCases) { item in
                Button(item.title) { tab = item }
                    .buttonStyle(PanelTabStyle(selected: tab == item))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var overviewBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.iconOrder.isEmpty {
                Text("Nothing on the menu bar. Turn providers on in Settings.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
                    .buttonStyle(.plain)
                    .help("Open \(PanelTab.product(for: provider).title)")
                }
            }
        }
    }

    private func productBody(_ providers: [ProviderID]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if providers.isEmpty {
                Text("No \(tab.title) accounts. Add one in Settings.")
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
        }
    }

    private var footer: some View {
        HStack {
            Text(lastRefreshLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var lastRefreshLabel: String {
        guard let last = store.lastRefresh else { return "Loading…" }
        let elapsed = Int(store.tick.timeIntervalSince(last))
        if elapsed < 60 { return "Updated just now" }
        return "Updated \(Format.countdown(to: Date(), now: last)) ago"
    }
}

/// Selection is fill + contrast only — same size and weight so the row doesn't jump.
private struct PanelTabStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.16 : 0.06))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
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
            }

            switch result?.outcome {
            case .none:
                message("Checking…", color: .tertiary)

            case .ok:
                if let window = iconWindow {
                    Text(window.title)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Meter(fraction: window.clamped / 100, level: UsageLevel(percent: window.clamped))
                    if let resets = window.resetsAt {
                        Text("resets in \(Format.countdown(to: resets, now: now))")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    } else if !window.isActive {
                        Text("not started")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    message(result?.snapshot?.note ?? "No usage reported", color: .secondary)
                }

            case .signedOut(let hint):
                message(hint, color: .secondary)

            case .failed(let reason, _):
                message(reason, color: Color(red: 0.93, green: 0.35, blue: 0.32))
            }
        }
        .contentShape(Rectangle())
    }

    private var iconWindow: UsageWindow? {
        guard let windows = result?.snapshot?.windows, !windows.isEmpty else { return nil }
        return windows.first(where: { $0.id == windowID }) ?? windows.first
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
                message("Checking…", color: .tertiary)

            case .ok(let snapshot):
                SnapshotBody(snapshot: snapshot, now: now)

            case .signedOut(let hint):
                message(hint, color: .secondary)

            case .failed(let reason, _):
                message(reason, color: Color(red: 0.93, green: 0.35, blue: 0.32))
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
            Text(snapshot.note ?? "No usage reported")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else {
            let shared = sharedReset(snapshot.windows)
            ForEach(snapshot.windows) { window in
                WindowRow(window: window, now: now, showsReset: shared == nil)
            }
            if let shared {
                // Every window resets together (Cursor's billing cycle), so say it once.
                Text("resets in \(Format.countdown(to: shared, now: now))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        if let note = snapshot.note, !snapshot.windows.isEmpty {
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        if snapshot.source != "api" {
            Text(snapshot.source)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    /// The single reset instant shared by every window, or nil when they differ.
    private func sharedReset(_ windows: [UsageWindow]) -> Date? {
        guard windows.count > 1, let first = windows.first?.resetsAt else { return nil }
        let same = windows.allSatisfy { window in
            guard let date = window.resetsAt else { return false }
            return abs(date.timeIntervalSince(first)) < 60
        }
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
                Text(window.title)
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
                Text("resets in \(Format.countdown(to: resets, now: now))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else if !window.isActive {
                Text("not started")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
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
