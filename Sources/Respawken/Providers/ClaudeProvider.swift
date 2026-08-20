import CryptoKit
import Foundation

/// Claude Code keeps no local record of limit state, so usage has to come from the OAuth API
/// that backs the CLI's own `/usage` view.
///
/// Credentials live either in `$CLAUDE_CONFIG_DIR/.credentials.json` or in a Keychain item
/// named `Claude Code-credentials` (default dir) / `Claude Code-credentials-<sha256[:8]>`
/// (custom `CLAUDE_CONFIG_DIR`). Access tokens expire after eight hours; this provider refreshes
/// them via Claude Code's public OAuth client and writes the rotated tokens back so the CLI
/// stays in sync.
struct ClaudeProvider: UsageProvider {
    let account: ClaudeAccount
    var id: ProviderID { account.providerID }

    /// The usage endpoint needs `user:profile`; inference-only tokens are rejected.
    private static let requiredScope = "user:profile"
    /// Claude Code's public OAuth client id — same one the CLI uses.
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    /// Refresh a few minutes early so overnight polls don't race the expiry.
    private static let refreshSkew: TimeInterval = 5 * 60

    private struct Credentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var scopes: [String]
        var subscriptionType: String?
        var rateLimitTier: String?
        /// Full Keychain/file blob, so a refresh can rewrite without dropping `mcpOAuth` etc.
        var raw: [String: Any]
        var keychainAccount: String?
        var keychainService: String
        var source: Source

        enum Source {
            case file(URL)
            case keychain
        }

        var isExpiredOrNearExpiry: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow <= ClaudeProvider.refreshSkew
        }
    }

    /// Remembers the last Keychain read per service so we don't re-spawn `security` on every
    /// poll unless Claude Code (or we) rewrote the credentials.
    private actor CredentialCache {
        static let shared = CredentialCache()

        private struct Entry {
            var stamp: Date?
            var cached: Credentials?
            var loaded = false
        }

        private var entries: [String: Entry] = [:]

        func credentials(service: String, load: () -> Credentials?) -> Credentials? {
            let current = Keychain.modificationDate(service: service)
            if let entry = entries[service], entry.loaded, entry.stamp == current {
                return entry.cached
            }

            let loaded = load()
            entries[service] = Entry(stamp: current, cached: loaded, loaded: true)
            return loaded
        }

        func replace(_ credentials: Credentials) {
            entries[credentials.keychainService] = Entry(
                stamp: Keychain.modificationDate(service: credentials.keychainService),
                cached: credentials,
                loaded: true
            )
        }
    }

    func fetch() async -> ProviderOutcome {
        guard var credentials = await loadCredentials() else {
            return .signedOut("Run `claude auth login` (\(account.label))")
        }
        guard credentials.scopes.isEmpty || credentials.scopes.contains(Self.requiredScope) else {
            return .signedOut("Token lacks \(Self.requiredScope) — re-run `claude auth login`")
        }

        if credentials.isExpiredOrNearExpiry {
            if let outcome = mapRefresh(await refresh(&credentials)) { return outcome }
        }

        do {
            return .ok(try await snapshot(token: credentials.accessToken, credentials: credentials))
        } catch let failure as HTTP.Failure where failure.status == 401 || failure.status == 403 {
            // Token may have been revoked mid-flight; try one refresh before asking the user.
            if let outcome = mapRefresh(await refresh(&credentials)) { return outcome }
            do {
                return .ok(try await snapshot(token: credentials.accessToken, credentials: credentials))
            } catch {
                return mapUsageError(error)
            }
        } catch {
            return mapUsageError(error)
        }
    }

    private func mapUsageError(_ error: Error) -> ProviderOutcome {
        .failed(error.localizedDescription, transient: HTTP.isTransient(error))
    }

    private func fetchUsage(token: String) async throws -> [String: Any] {
        try await HTTP.getJSON(Self.usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": userAgent(),
        ])
    }

    private func fetchProfile(token: String) async -> [String: Any]? {
        try? await HTTP.getJSON("https://api.anthropic.com/api/oauth/profile", headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": userAgent(),
        ])
    }

    private func snapshot(token: String, credentials: Credentials) async throws -> ProviderSnapshot {
        async let usage = fetchUsage(token: token)
        async let profile = fetchProfile(token: token)
        return parse(try await usage, credentials: credentials, profile: await profile)
    }

    // MARK: - OAuth refresh

    private enum RefreshResult {
        case ok
        case signedOut(String)
        case failed(String, transient: Bool = false)
    }

    private func refresh(_ credentials: inout Credentials) async -> RefreshResult {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return .signedOut("Session expired — run `claude auth login`")
        }

        do {
            let json = try await HTTP.postJSON(
                Self.tokenURL,
                headers: [
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                    "User-Agent": userAgent(),
                ],
                body: [
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": Self.clientID,
                ]
            )

            guard let access = json.string("access_token"), !access.isEmpty else {
                return .failed("Refresh returned no access token")
            }

            credentials.accessToken = access
            if let rotated = json.string("refresh_token"), !rotated.isEmpty {
                credentials.refreshToken = rotated
            }
            if let seconds = json.number("expires_in") {
                credentials.expiresAt = Date().addingTimeInterval(seconds)
            }

            persist(credentials)
            await CredentialCache.shared.replace(credentials)
            return .ok
        } catch let failure as HTTP.Failure where failure.status == 400 || failure.status == 401 {
            // invalid_grant / revoked refresh token — only a fresh login helps.
            return .signedOut("Session expired — run `claude auth login`")
        } catch {
            return .failed(error.localizedDescription, transient: HTTP.isTransient(error))
        }
    }

    private func mapRefresh(_ result: RefreshResult) -> ProviderOutcome? {
        switch result {
        case .ok: return nil
        case .signedOut(let hint): return .signedOut(hint)
        case .failed(let reason, let transient): return .failed(reason, transient: transient)
        }
    }

    private func persist(_ credentials: Credentials) {
        var raw = credentials.raw
        var oauth = raw.dict("claudeAiOauth") ?? [:]
        oauth["accessToken"] = credentials.accessToken
        if let refresh = credentials.refreshToken {
            oauth["refreshToken"] = refresh
        }
        if let expires = credentials.expiresAt {
            oauth["expiresAt"] = Int(expires.timeIntervalSince1970 * 1000)
        }
        raw["claudeAiOauth"] = oauth

        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return }

        switch credentials.source {
        case .file(let url):
            try? data.write(to: url, options: .atomic)
        case .keychain:
            let account = credentials.keychainAccount
                ?? Keychain.account(service: credentials.keychainService)
                ?? NSUserName()
            _ = Keychain.updateGenericPassword(
                service: credentials.keychainService,
                account: account,
                data: data
            )
        }
    }

    private func userAgent() -> String {
        // Cloudflare on platform.claude.com bans non-browser / non-CLI signatures (error 1010).
        "claude-cli/\(claudeCLIVersion()) (external, cli)"
    }

    private func claudeCLIVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "2.0.0" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return "2.0.0" }
        // e.g. "2.1.220 (Claude Code)" → "2.1.220"
        return text.split(whereSeparator: { $0 == " " || $0 == "(" }).first.map(String.init) ?? "2.0.0"
    }

    // MARK: - Credential loading

    /// Matches Claude Code: default dir → `Claude Code-credentials`; custom dir →
    /// `Claude Code-credentials-` + first 8 hex chars of SHA-256(NFC(absolute path)).
    static func keychainService(forConfigDir configDir: String?) -> String {
        guard let configDir else { return "Claude Code-credentials" }
        let normalized = configDir.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(suffix)"
    }

    private var configDirectory: URL {
        if let configDir = account.resolvedConfigDir {
            return URL(fileURLWithPath: configDir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    private var keychainService: String {
        Self.keychainService(forConfigDir: account.resolvedConfigDir)
    }

    private func loadCredentials() async -> Credentials? {
        let file = configDirectory.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file),
           let creds = decode(
            data,
            source: .file(file),
            keychainService: keychainService,
            keychainAccount: nil
           ) {
            return creds
        }

        let service = keychainService
        return await CredentialCache.shared.credentials(service: service) {
            guard let data = Keychain.genericPassword(service: service) else { return nil }
            return decode(
                data,
                source: .keychain,
                keychainService: service,
                keychainAccount: Keychain.account(service: service)
            )
        }
    }

    private func decode(
        _ data: Data,
        source: Credentials.Source,
        keychainService: String,
        keychainAccount: String?
    ) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root.dict("claudeAiOauth"),
              let token = oauth.string("accessToken"), !token.isEmpty
        else { return nil }

        let expires: Date?
        if let ms = oauth.number("expiresAt"), ms > 0 {
            expires = Date(timeIntervalSince1970: ms > 100_000_000_000 ? ms / 1000 : ms)
        } else {
            expires = nil
        }

        return Credentials(
            accessToken: token,
            refreshToken: oauth.string("refreshToken"),
            expiresAt: expires,
            scopes: oauth["scopes"] as? [String] ?? [],
            subscriptionType: oauth.string("subscriptionType"),
            rateLimitTier: oauth.string("rateLimitTier"),
            raw: root,
            keychainAccount: keychainAccount,
            keychainService: keychainService,
            source: source
        )
    }

    // MARK: - Payload

    /// Windows Anthropic reports, in the order they should appear.
    /// Each window's payload key, display name, and the matching `kind` in the `limits` array.
    private static let knownWindows: [(key: String, title: String, kind: String)] = [
        ("five_hour", "Session (5-hour)", "session"),
        ("seven_day", "Weekly", "weekly_all"),
        ("seven_day_opus", "Weekly · Opus", "weekly_opus"),
        ("seven_day_sonnet", "Weekly · Sonnet", "weekly_sonnet"),
        ("seven_day_routines", "Weekly · Routines", "weekly_routines"),
        ("seven_day_cowork", "Weekly · Cowork", "weekly_cowork"),
    ]

    private func parse(
        _ json: [String: Any],
        credentials: Credentials,
        profile: [String: Any]?
    ) -> ProviderSnapshot {
        // The parallel `limits` array is the only place that says whether a window is running.
        var activeByKind: [String: Bool] = [:]
        for limit in json["limits"] as? [[String: Any]] ?? [] {
            if let kind = limit.string("kind") {
                activeByKind[kind] = limit["is_active"] as? Bool ?? true
            }
        }

        var windows: [UsageWindow] = []
        for entry in Self.knownWindows {
            guard let node = json.dict(entry.key),
                  let used = node.number("utilization", "used_percent", "usedPercent", "percent_used")
            else { continue }
            windows.append(UsageWindow(
                id: entry.key,
                title: entry.title,
                usedPercent: used,
                resetsAt: node.date("resets_at", "reset_at", "resetsAt"),
                isActive: activeByKind[entry.kind] ?? true
            ))
        }

        var snapshot = ProviderSnapshot(
            plan: planLabel(credentials),
            account: json.dict("account")?.string("email")
                ?? json.string("email")
                ?? account.label,
            windows: windows,
            source: "api"
        )

        if let created = profile?.dict("organization")?.date("subscription_created_at") {
            snapshot.renewsAt = Format.nextMonthly(from: created)
        }

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
