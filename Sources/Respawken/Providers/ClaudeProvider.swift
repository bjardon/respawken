import Foundation

/// Claude Code keeps no local record of limit state, so usage has to come from the OAuth API
/// that backs the CLI's own `/usage` view.
///
/// Credentials live either in `~/.claude/.credentials.json` or in the `Claude Code-credentials`
/// Keychain item. On Claude Code 2.1.x that Keychain item is often present but stripped of its
/// tokens when logged out, which reads as "signed out" rather than an error.
struct ClaudeProvider: UsageProvider {
    let id = ProviderID.claude

    /// The usage endpoint needs `user:profile`; inference-only tokens are rejected.
    private static let requiredScope = "user:profile"

    struct Credentials {
        let accessToken: String
        let scopes: [String]
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    /// Remembers the last Keychain read and the item's modification date, so the expensive
    /// authorized read happens only when Claude Code actually rewrites its credentials
    /// (a login or a token refresh) instead of on every poll.
    private actor CredentialCache {
        static let shared = CredentialCache()

        private var stamp: Date?
        private var cached: Credentials?
        private var loaded = false

        func credentials(service: String, decode: (Data) -> Credentials?) -> Credentials? {
            let current = Keychain.modificationDate(service: service)
            if loaded, current == stamp { return cached }

            cached = Keychain.genericPassword(service: service).flatMap(decode)
            stamp = current
            loaded = true
            return cached
        }
    }

    func fetch() async -> ProviderOutcome {
        guard let credentials = await loadCredentials() else {
            return .signedOut("Run `claude auth login`")
        }
        guard credentials.scopes.isEmpty || credentials.scopes.contains(Self.requiredScope) else {
            return .signedOut("Token lacks \(Self.requiredScope) — re-run `claude auth login`")
        }

        do {
            let json = try await HTTP.getJSON(
                "https://api.anthropic.com/api/oauth/usage",
                headers: [
                    "Authorization": "Bearer \(credentials.accessToken)",
                    "anthropic-beta": "oauth-2025-04-20",
                    "Accept": "application/json",
                ]
            )
            return .ok(parse(json, credentials: credentials))
        } catch let failure as HTTP.Failure where failure.status == 401 || failure.status == 403 {
            return .signedOut("Session expired — run `claude auth login`")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func loadCredentials() async -> Credentials? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let creds = decode(data) { return creds }
        return await CredentialCache.shared.credentials(service: "Claude Code-credentials", decode: decode)
    }

    private func decode(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root.dict("claudeAiOauth"),
              let token = oauth.string("accessToken"), !token.isEmpty
        else { return nil }

        return Credentials(
            accessToken: token,
            scopes: oauth["scopes"] as? [String] ?? [],
            subscriptionType: oauth.string("subscriptionType"),
            rateLimitTier: oauth.string("rateLimitTier")
        )
    }

    // MARK: - Payload

    /// Windows Anthropic reports, in the order they should appear.
    private static let knownWindows: [(key: String, title: String)] = [
        ("five_hour", "Session (5-hour)"),
        ("seven_day", "Weekly"),
        ("seven_day_opus", "Weekly · Opus"),
        ("seven_day_sonnet", "Weekly · Sonnet"),
        ("seven_day_routines", "Weekly · Routines"),
        ("seven_day_cowork", "Weekly · Cowork"),
    ]

    private func parse(_ json: [String: Any], credentials: Credentials) -> ProviderSnapshot {
        var windows: [UsageWindow] = []
        for entry in Self.knownWindows {
            guard let node = json.dict(entry.key),
                  let used = node.number("utilization", "used_percent", "usedPercent", "percent_used")
            else { continue }
            windows.append(UsageWindow(
                id: entry.key,
                title: entry.title,
                usedPercent: used,
                resetsAt: node.date("resets_at", "reset_at", "resetsAt")
            ))
        }

        var snapshot = ProviderSnapshot(
            plan: planLabel(credentials),
            account: json.dict("account")?.string("email") ?? json.string("email"),
            windows: windows,
            source: "api"
        )

        if let extra = json.dict("extra_usage"), let spend = extra.number("spend", "used") {
            let limit = extra.number("limit").map { String(format: " / $%.0f", $0) } ?? ""
            snapshot.note = String(format: "Extra usage: $%.2f", spend) + limit
        }
        if windows.isEmpty {
            snapshot.note = "No limit windows reported"
        }
        return snapshot
    }

    private func planLabel(_ credentials: Credentials) -> String? {
        // A Max tier carries its multiplier in the rate limit tier, which is worth surfacing.
        if let tier = credentials.rateLimitTier {
            if tier.contains("max_20x") { return "Max 20x" }
            if tier.contains("max_5x") { return "Max 5x" }
        }
        guard let subscription = credentials.subscriptionType else { return nil }
        switch subscription.lowercased() {
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return subscription.capitalized
        }
    }
}
