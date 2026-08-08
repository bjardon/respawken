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
        accounts.map { ClaudeProvider(account: $0) } + [CodexProvider(), CursorProvider(), NotionProvider()]
    }

    var providerOrder: [ProviderID] {
        claudeAccounts.map(\.providerID) + [.codex, .cursor, .notion]
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
        if let windows = results[provider]?.snapshot?.windows, !windows.isEmpty {
            return windows.map { ($0.id, $0.title) }
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
        let validIDs = Set(accounts.map(\.id) + [ProviderID.codex.rawValue, ProviderID.cursor.rawValue, ProviderID.notion.rawValue])
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

    func updateIconPrefs(_ prefs: ProviderIconPrefs, for provider: ProviderID) {
        var next = settings
        let current = next.prefs(for: provider)
        guard prefs != current else { return }
        next.setPrefs(prefs, for: provider)
        settings = next
        settings.save()
    }

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            await self?.notifier.requestAuthorizationIfNeeded()
            while !Task.isCancelled {
                await self?.refresh()
                // Wake once a minute so countdowns stay honest between fetches.
                for _ in 0..<Int(Self.refreshInterval / 60) {
                    try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
                    if Task.isCancelled { return }
                    await MainActor.run { self?.tick = Date() }
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
