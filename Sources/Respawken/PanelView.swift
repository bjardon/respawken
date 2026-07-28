import SwiftUI

struct PanelView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                ForEach(ProviderID.allCases) { provider in
                    ProviderRow(provider: provider, result: store.results[provider], now: store.tick)
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
        .padding(.vertical, 10)
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

private struct ProviderRow: View {
    let provider: ProviderID
    let result: ProviderResult?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(provider.accent).frame(width: 7, height: 7)
                Text(provider.title)
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
                if snapshot.windows.isEmpty {
                    message(snapshot.note ?? "No usage reported", color: .secondary)
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
                    message(note, color: .secondary)
                }
                if snapshot.source != "api" {
                    message(snapshot.source, color: .tertiary)
                }

            case .signedOut(let hint):
                message(hint, color: .secondary)

            case .failed(let reason):
                message(reason, color: Color(red: 0.93, green: 0.35, blue: 0.32))
            }
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

    private func message(_ text: String, color: some ShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
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
