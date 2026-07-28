import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var results: [ProviderID: ProviderResult] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// Drives countdown labels without re-fetching.
    @Published private(set) var tick = Date()

    private let providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), CursorProvider()]
    private var timer: Task<Void, Never>?

    static let refreshInterval: TimeInterval = 120

    init(seed: [ProviderID: ProviderResult] = [:]) {
        results = seed
        lastRefresh = seed.isEmpty ? nil : Date()
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
                results[result.provider] = result
            }
        }
    }
}
