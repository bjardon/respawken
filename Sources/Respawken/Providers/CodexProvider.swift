import Foundation

/// Codex exposes limits two ways:
///   1. `wham/usage`, authenticated with the OAuth token in `~/.codex/auth.json`. Authoritative.
///   2. The `rate_limits` block the CLI writes into its session rollout logs. Offline, but only
///      as fresh as the last Codex run.
///
/// The API is preferred; the log is used when the token is missing/expired or the network is down,
/// so the menu bar still shows something true-as-of-last-run instead of an error. Access tokens
/// are refreshed via Codex's public OAuth client and written back so the CLI stays in sync.
struct CodexProvider: UsageProvider {
    let id = ProviderID.codex

    /// Codex CLI's public ChatGPT OAuth client id.
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let tokenURL = "https://auth.openai.com/oauth/token"
    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    /// Refresh a few minutes early so overnight polls don't race the expiry.
    private static let refreshSkew: TimeInterval = 5 * 60

    private var home: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private struct Credentials {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var accountID: String?
        var expiresAt: Date?
        /// Full `auth.json` blob so a refresh can rewrite without dropping unrelated keys.
        var raw: [String: Any]
        var path: URL

        var isExpiredOrNearExpiry: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow <= CodexProvider.refreshSkew
        }
    }

    func fetch() async -> ProviderOutcome {
        guard var credentials = loadCredentials() else {
            if let local = localSnapshot() { return .ok(local) }
            return .signedOut("Run `codex login`")
        }

        if credentials.isExpiredOrNearExpiry {
            if let outcome = mapRefresh(await refresh(&credentials), renewal: renewalDate(from: credentials)) { return outcome }
        }

        do {
            return .ok(parse(try await fetchUsage(credentials), renewal: renewalDate(from: credentials)))
        } catch let failure as HTTP.Failure where failure.status == 401 {
            // Token may have been revoked mid-flight; try one refresh before falling back.
            if let outcome = mapRefresh(await refresh(&credentials), renewal: renewalDate(from: credentials)) { return outcome }
            do {
                return .ok(parse(try await fetchUsage(credentials), renewal: renewalDate(from: credentials)))
            } catch {
                return mapUsageError(error, renewal: renewalDate(from: credentials))
            }
        } catch {
            return mapUsageError(error, renewal: renewalDate(from: credentials))
        }
    }

    private func fetchUsage(_ credentials: Credentials) async throws -> [String: Any] {
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
        ]
        if let accountID = credentials.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return try await HTTP.getJSON(Self.usageURL, headers: headers)
    }

    private func mapUsageError(_ error: Error, renewal: Date? = nil) -> ProviderOutcome {
        if let failure = error as? HTTP.Failure, failure.status == 401 {
            if var local = localSnapshot() {
                local.note = "Token expired — showing last session"
                local.renewsAt = renewal
                return .ok(local)
            }
            return .signedOut("Token expired — run `codex login`")
        }
        if var local = localSnapshot() {
            local.note = "API unreachable — showing last session"
            local.renewsAt = renewal
            return .ok(local)
        }
        return .failed(error.localizedDescription, transient: HTTP.isTransient(error))
    }

    // MARK: - OAuth refresh

    private enum RefreshResult {
        case ok
        case signedOut(String)
        case failed(String, transient: Bool = false)
    }

    private func refresh(_ credentials: inout Credentials) async -> RefreshResult {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return .signedOut("Token expired — run `codex login`")
        }

        do {
            let json = try await HTTP.postJSON(
                Self.tokenURL,
                headers: [
                    "Content-Type": "application/json",
                    "Accept": "application/json",
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
            if let idToken = json.string("id_token"), !idToken.isEmpty {
                credentials.idToken = idToken
            }
            if let seconds = json.number("expires_in") {
                credentials.expiresAt = Date().addingTimeInterval(seconds)
            } else if let claims = JWT.payload(access), let exp = claims.number("exp") {
                credentials.expiresAt = Date(timeIntervalSince1970: exp)
            }

            persist(credentials)
            return .ok
        } catch let failure as HTTP.Failure where failure.status == 400 || failure.status == 401 {
            // invalid_grant / revoked refresh token — only a fresh login helps.
            return .signedOut("Token expired — run `codex login`")
        } catch {
            return .failed(error.localizedDescription, transient: HTTP.isTransient(error))
        }
    }

    private func mapRefresh(_ result: RefreshResult, renewal: Date? = nil) -> ProviderOutcome? {
        switch result {
        case .ok:
            return nil
        case .signedOut(let hint):
            if var local = localSnapshot() {
                local.note = "Token expired — showing last session"
                local.renewsAt = renewal
                return .ok(local)
            }
            return .signedOut(hint)
        case .failed(let reason, let transient):
            if var local = localSnapshot() {
                local.note = transient
                    ? "API unreachable — showing last session"
                    : "Token expired — showing last session"
                local.renewsAt = renewal
                return .ok(local)
            }
            return .failed(reason, transient: transient)
        }
    }

    private func persist(_ credentials: Credentials) {
        var raw = credentials.raw
        var tokens = raw.dict("tokens") ?? [:]
        tokens["access_token"] = credentials.accessToken
        if let refresh = credentials.refreshToken {
            tokens["refresh_token"] = refresh
        }
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountID = credentials.accountID {
            tokens["account_id"] = accountID
        }
        raw["tokens"] = tokens
        raw["last_refresh"] = Self.timestamp(Date())

        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        else { return }
        try? data.write(to: credentials.path, options: .atomic)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Credential loading

    private func loadCredentials() -> Credentials? {
        let path = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root.dict("tokens"),
              let access = tokens.string("access_token"), !access.isEmpty
        else { return nil }

        let expiresAt: Date?
        if let claims = JWT.payload(access), let exp = claims.number("exp") {
            expiresAt = Date(timeIntervalSince1970: exp)
        } else {
            expiresAt = nil
        }

        return Credentials(
            accessToken: access,
            refreshToken: tokens.string("refresh_token"),
            idToken: tokens.string("id_token"),
            accountID: tokens.string("account_id"),
            expiresAt: expiresAt,
            raw: root,
            path: path
        )
    }

    // MARK: - API payload

    private func parse(_ json: [String: Any], renewal: Date? = nil) -> ProviderSnapshot {
        let limit = json.dict("rate_limit")
        var windows: [UsageWindow] = []

        if let primary = limit?.dict("primary_window"), let w = window(id: "primary", from: primary) {
            windows.append(w)
        }
        if let secondary = limit?.dict("secondary_window"), let w = window(id: "secondary", from: secondary) {
            windows.append(w)
        }
        for (index, extra) in (json["additional_rate_limits"] as? [[String: Any]] ?? []).enumerated() {
            let node = extra.dict("rate_limit")?.dict("primary_window") ?? extra
            if var w = window(id: "extra-\(index)", from: node) {
                if let name = extra.string("name") ?? extra.string("limit_name") {
                    w = UsageWindow(id: w.id, title: name, usedPercent: w.usedPercent, resetsAt: w.resetsAt)
                }
                windows.append(w)
            }
        }

        var snapshot = ProviderSnapshot(
            plan: json.string("plan_type").map(planLabel),
            account: json.string("email"),
            windows: windows,
            renewsAt: renewal,
            source: "api"
        )
        snapshot.note = note(credits: json.dict("credits"), resets: json.dict("rate_limit_reset_credits"))
        return snapshot
    }

    private func note(credits: [String: Any]?, resets: [String: Any]?) -> String? {
        var parts: [String] = []
        if credits?["has_credits"] as? Bool == true {
            parts.append("Credits: \(credits?.string("balance") ?? "0")")
        }
        if let count = resets?.number("available_count", "applicable_available_count"), count > 0 {
            parts.append("Resets available: \(Int(count))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func window(id: String, from dict: [String: Any]) -> UsageWindow? {
        guard let used = dict.number("used_percent", "usedPercent") else { return nil }

        // The API reports seconds; session logs report minutes; app-server uses windowDurationMins.
        let seconds: Int
        if let minutes = dict.number("window_minutes", "windowDurationMins") {
            seconds = Int(minutes * 60)
        } else {
            seconds = Int(dict.number("limit_window_seconds") ?? 0)
        }

        var resets = dict.date("reset_at", "resets_at")
        if resets == nil, let after = dict.number("reset_after_seconds") {
            resets = Date().addingTimeInterval(after)
        }

        return UsageWindow(
            id: id,
            title: seconds > 0 ? Format.windowName(seconds: seconds) : "Usage",
            usedPercent: used,
            resetsAt: resets
        )
    }

    /// ChatGPT Plus/Pro billing day lives on the id token. The claim is often a past
    /// period end, so walk it forward month by month to the next future anniversary.
    private func renewalDate(from credentials: Credentials) -> Date? {
        guard let token = credentials.idToken,
              let claims = JWT.payload(token),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let anchor = auth.date(
                "chatgpt_subscription_active_until",
                "chatgpt_subscription_active_start"
              )
        else { return nil }
        return Format.nextMonthly(from: anchor)
    }

    private func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    // MARK: - Local session log fallback

    private func localSnapshot() -> ProviderSnapshot? {
        guard let path = newestSessionLog(),
              let payload = lastRateLimits(in: path) else { return nil }

        var windows: [UsageWindow] = []
        if let primary = payload.dict("primary"), let w = window(id: "primary", from: primary) {
            windows.append(w)
        }
        if let secondary = payload.dict("secondary"), let w = window(id: "secondary", from: secondary) {
            windows.append(w)
        }
        guard !windows.isEmpty else { return nil }

        return ProviderSnapshot(
            plan: payload.string("plan_type").map(planLabel),
            account: nil,
            windows: windows,
            source: "local session log"
        )
    }

    private func newestSessionLog() -> String? {
        let fm = FileManager.default
        let roots = [
            home.appendingPathComponent("sessions"),
            home.appendingPathComponent("archived_sessions"),
        ]

        var newest: (path: String, date: Date)?
        for root in roots {
            guard let walker = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if newest == nil || modified > newest!.date {
                    newest = (url.path, modified)
                }
            }
        }
        return newest?.path
    }

    private func lastRateLimits(in path: String) -> [String: Any]? {
        for line in FileTail.lines(of: path).reversed() {
            guard line.contains("\"rate_limits\""),
                  let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let limits = root.dict("payload")?.dict("rate_limits")
            else { continue }
            return limits
        }
        return nil
    }
}
