import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var results: [ProviderID: ProviderResult] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// Drives countdown labels without re-fetching.
    @Published private(set) var tick = Date()

    private let providers: [any UsageProvider]
    private let notifier = UsageNotifier.shared
    private var timer: Task<Void, Never>?

    static let refreshInterval: TimeInterval = 120

    init(seed: [ProviderID: ProviderResult] = [:], providers: [any UsageProvider]? = nil) {
        results = seed
        lastRefresh = seed.isEmpty ? nil : Date()
        self.providers = providers ?? Self.defaultProviders()
    }

    nonisolated static func defaultProviders() -> [any UsageProvider] {
        ClaudeAccount.configured.map { ClaudeProvider(account: $0) }
            + [CodexProvider(), CursorProvider()]
    }

    var ordered: [ProviderResult] {
        ProviderID.allCases.compactMap { results[$0] }
    }

    /// The number worth putting in the menu bar: the closest limit to being hit.
    var peak: (provider: ProviderID, percent: Double)? {
        ordered
            .compactMap { result in result.peakPercent.map { (result.provider, $0) } }
            .max { $0.1 < $1.1 }
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

        // Providers are independent; one hanging must not delay the others.
        await withTaskGroup(of: ProviderResult.self) { group in
            for provider in providers {
                group.addTask {
                    ProviderResult(provider: provider.id, outcome: await provider.fetch(), fetchedAt: Date())
                }
            }
            for await result in group {
                // Keep the last good reading across transient blips (429, gateway errors)
                // so overnight rate limits don't blank a provider that was fine.
                if result.isTransientFailure, case .ok = results[result.provider]?.outcome {
                    continue
                }
                results[result.provider] = result
            }
        }

        notifier.evaluate(results: results)
    }
}
