import AppKit
import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var results: [ProviderID: ProviderResult] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// Drives countdown labels without re-fetching.
    @Published private(set) var tick = Date()
    @Published private(set) var settings: AppSettings

    private var providers: [any UsageProvider]
    private let notifier = UsageNotifier.shared
    private var timer: Task<Void, Never>?

    static let refreshInterval: TimeInterval = 120
    /// Faster poll while a window is still burning toward the cap — not after it's toast.
    static let urgentRefreshInterval: TimeInterval = 30
    static let urgentThreshold: Double = 90
    static let urgentCeiling: Double = 98
    /// Catch the flip back to 0% without sitting on a 2-minute poll across the reset.
    static let urgentResetHorizon: TimeInterval = 10 * 60
    static let maxIconProviders = 6

    var claudeAccounts: [ClaudeAccount] { settings.claudeAccounts }

    init(seed: [ProviderID: ProviderResult] = [:], providers: [any UsageProvider]? = nil) {
        let loaded = AppSettings.load()
        settings = loaded
        results = seed
        lastRefresh = seed.isEmpty ? nil : Date()
        self.providers = providers ?? Self.providers(for: loaded.claudeAccounts)
    }

    nonisolated static func defaultProviders() -> [any UsageProvider] {
        providers(for: AppSettings.load().claudeAccounts)
    }

    nonisolated static func providers(for accounts: [ClaudeAccount]) -> [any UsageProvider] {
        accounts.map { ClaudeProvider(account: $0) } + [CodexProvider(), CursorProvider(), NotionProvider(), AntigravityProvider()]
    }

    var providerOrder: [ProviderID] {
        claudeAccounts.map(\.providerID) + [.codex, .cursor, .notion, .antigravity]
    }

    /// Providers drawn on the menu bar icon, in panel order, capped at six.
    var iconOrder: [ProviderID] {
        Array(providerOrder.filter { settings.showOnIcon($0) }.prefix(Self.maxIconProviders))
    }

    var ordered: [ProviderResult] {
        providerOrder.compactMap { results[$0] }
    }

    func title(for provider: ProviderID) -> String {
        provider.title(using: claudeAccounts)
    }

    func accent(for provider: ProviderID) -> Color {
        if let custom = settings.prefs(for: provider).color {
            return custom.color
        }
        return provider.defaultAccent(accounts: claudeAccounts)
    }

    func nsAccent(for provider: ProviderID) -> NSColor {
        if let custom = settings.prefs(for: provider).color {
            return custom.nsColor
        }
        return NSColor(provider.defaultAccent(accounts: claudeAccounts))
    }

    /// Window choices for the icon picker: live titles when available, else static defaults.
    func iconWindowOptions(for provider: ProviderID) -> [(id: String, title: String)] {
        if let live = results[provider]?.snapshot?.windows, !live.isEmpty {
            return live.map { ($0.id, L10n.windowTitle(id: $0.id, stored: $0.title)) }
        }
        return IconWindowDefaults.options(for: provider)
    }

    /// The number worth putting in the menu bar: the closest limit to being hit.
    var peak: (provider: ProviderID, percent: Double)? {
        iconOrder
            .compactMap { provider in
                let windowID = settings.iconWindowID(for: provider)
                return results[provider]?.iconPercent(windowID: windowID).map { (provider, $0) }
            }
            .max { $0.1 < $1.1 }
    }

    func updateClaudeAccounts(_ accounts: [ClaudeAccount]) {
        guard accounts != claudeAccounts else { return }
        let previous = claudeAccounts
        var next = settings
        next.claudeAccounts = accounts
        // Drop prefs for removed Claude accounts; leave hardcoded providers alone.
        let validIDs = Set(accounts.map(\.id) + [
            ProviderID.codex.rawValue,
            ProviderID.cursor.rawValue,
            ProviderID.notion.rawValue,
            ProviderID.antigravity.rawValue,
        ])
        next.providerIconPrefs = next.providerIconPrefs.filter { validIDs.contains($0.key) }
        settings = next
        settings.save()

        // Relabeling alone shouldn't re-hit the APIs — only add/remove/path changes.
        let previousStructure = previous.map { "\($0.id)\0\($0.resolvedConfigDir ?? "")" }
        let nextStructure = accounts.map { "\($0.id)\0\($0.resolvedConfigDir ?? "")" }
        guard previousStructure != nextStructure else { return }

        providers = Self.providers(for: accounts)
        let valid = Set(providerOrder)
        results = results.filter { valid.contains($0.key) }
        Task { await refresh() }
    }

    func updateLanguage(_ language: AppLanguage) {
        guard language != settings.language else { return }
        L10n.language = language
        var next = settings
        next.language = language
        settings = next
        settings.save()
        notifier.evaluate(results: results, order: providerOrder, accounts: claudeAccounts)
    }

    @discardableResult
    func updatePanelShortcut(_ combo: KeyCombo?) -> Bool {
        var next = settings
        next.panelShortcut = combo
        settings = next
        settings.save()
        return PanelHotKey.shared.install(combo)
    }

    func updateIconPrefs(_ prefs: ProviderIconPrefs, for provider: ProviderID) {
        var next = settings
        let current = next.prefs(for: provider)
        guard prefs != current else { return }
        next.setPrefs(prefs, for: provider)
        settings = next
        settings.save()
    }

    /// Speed up only while a reading can still change soon: climbing through 90–98%,
    /// or a reset due within ten minutes. 99–100% with hours left stays on the 2-minute poll.
    var isRunningLow: Bool {
        let now = Date()
        return results.values.contains { result in
            result.snapshot?.windows.contains { window in
                guard window.isActive else { return false }
                let burning = window.clamped >= Self.urgentThreshold && window.clamped < Self.urgentCeiling
                if burning { return true }
                guard let reset = window.resetsAt else { return false }
                let remaining = reset.timeIntervalSince(now)
                return remaining > 0 && remaining <= Self.urgentResetHorizon
            } ?? false
        }
    }

    private var nextRefreshInterval: TimeInterval {
        isRunningLow ? Self.urgentRefreshInterval : Self.refreshInterval
    }

    func start() {
        guard timer == nil else { return }
        PanelHotKey.shared.install(settings.panelShortcut)
        timer = Task { [weak self] in
            await self?.notifier.requestAuthorizationIfNeeded()
            while !Task.isCancelled {
                await self?.refresh()
                // Sleep in ≤60s slices so countdowns stay honest between fetches.
                // Interval is picked after each poll: 30s while a window is still
                // burning (90–98%) or a reset is within 10 minutes, else 2 min.
                var remaining = self?.nextRefreshInterval ?? Self.refreshInterval
                while remaining > 0 {
                    let slice = min(remaining, 60)
                    try? await Task.sleep(nanoseconds: UInt64(slice * Double(NSEC_PER_SEC)))
                    if Task.isCancelled { return }
                    self?.tick = Date()
                    remaining -= slice
                }
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
            tick = Date()
        }

        let accounts = claudeAccounts
        let order = providerOrder

        // Providers are independent; one hanging must not delay the others.
        await withTaskGroup(of: ProviderResult.self) { group in
            for provider in providers {
                group.addTask {
                    ProviderResult(provider: provider.id, outcome: await provider.fetch(), fetchedAt: Date())
                }
            }
            for await result in group {
                // Keep the last good reading across transient blips (429, gateway errors,
                // dropped sockets) so a flaky poll doesn't blank a provider that was fine.
                if result.isTransientFailure, case .ok = results[result.provider]?.outcome {
                    continue
                }
                results[result.provider] = result
            }
        }

        notifier.evaluate(results: results, order: order, accounts: accounts)
    }
}
