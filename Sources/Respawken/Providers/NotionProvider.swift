import Foundation
import SQLite3

/// Notion AI usage allowance + credits, read from the desktop app's session.
///
/// Auth is Notion.app's Chromium cookie jar (`token_v2`), decrypted with the
/// `Notion Safe Storage` Keychain password via `/usr/bin/security` (same prompt
/// avoidance as Claude). The public Notion API token cannot see these meters —
/// they live on the private `app.notion.com/api/v3` endpoints that back
/// Settings → Notion AI → Usage and the credits dashboard.
///
/// Allowance applies on Business / Enterprise only (6-hour rolling + monthly
/// billing window). Credits meter Custom Agents / Workers / overage separately.
struct NotionProvider: UsageProvider {
    let id = ProviderID.notion

    private static let safeStorageService = "Notion Safe Storage"
    private static let safeStorageAccount = "Notion"
    private static let apiBase = "https://app.notion.com/api/v3"

    private var cookiesPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Notion/Partitions/notion/Cookies"
            )
            .path
    }

    /// Avoid re-spawning `security` and re-decrypting on every 2-minute poll.
    private actor SessionCache {
        static let shared = SessionCache()

        private var keyStamp: Date?
        private var password: Data?
        private var cookieStamp: Date?
        private var token: String?

        func tokenV2(cookiesPath: String) -> String? {
            let keyStamp = Keychain.modificationDate(service: NotionProvider.safeStorageService)
            if password == nil || self.keyStamp != keyStamp {
                password = Keychain.genericPassword(
                    service: NotionProvider.safeStorageService,
                    account: NotionProvider.safeStorageAccount
                )
                self.keyStamp = keyStamp
                token = nil
            }
            guard let password else { return nil }

            let cookieStamp = (try? FileManager.default.attributesOfItem(atPath: cookiesPath))?[.modificationDate] as? Date
            if token == nil || self.cookieStamp != cookieStamp {
                token = NotionProvider.readTokenV2(from: cookiesPath, password: password)
                self.cookieStamp = cookieStamp
            }
            return token
        }
    }

    func fetch() async -> ProviderOutcome {
        guard FileManager.default.fileExists(atPath: cookiesPath) else {
            return .signedOut("Install and sign in to Notion.app")
        }
        guard let token = await SessionCache.shared.tokenV2(cookiesPath: cookiesPath) else {
            return .signedOut("Sign in to Notion.app (or Allow Keychain access)")
        }

        let headers = Self.apiHeaders(token: token)

        do {
            let spacesJSON = try await HTTP.postJSON(
                "\(Self.apiBase)/getSpaces",
                headers: headers,
                body: [:]
            )
            guard let workspace = Self.pickWorkspace(from: spacesJSON) else {
                return .failed("No Business/Enterprise Notion workspace found")
            }

            let rate = try await HTTP.postJSON(
                "\(Self.apiBase)/getCreditRateLimitStatus",
                headers: headers,
                body: ["spaceId": workspace.id]
            )

            if let status = rate.string("status"), status == "not_applicable" {
                return .failed("AI usage allowance not tracked for \(workspace.name) (\(workspace.tierLabel))")
            }

            var creditsJSON: [String: Any]?
            do {
                creditsJSON = try await HTTP.postJSON(
                    "\(Self.apiBase)/getAIUsageEligibilityV2",
                    headers: headers,
                    body: ["spaceId": workspace.id]
                )
            } catch {
                // Credits are secondary; allowance alone is still useful.
                creditsJSON = nil
            }

            return .ok(Self.parse(
                rate: rate,
                credits: creditsJSON,
                workspace: workspace,
                account: Self.accountEmail(from: spacesJSON)
            ))
        } catch let failure as HTTP.Failure where failure.status == 401 {
            return .signedOut("Notion session rejected — sign in to Notion.app again")
        } catch {
            return .failed(error.localizedDescription, transient: HTTP.isTransient(error))
        }
    }

    // MARK: - Cookie

    private static func readTokenV2(from path: String, password: Data) -> String? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            "file:\(encoded)?immutable=1",
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        ) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // Prefer the app.notion.com host; fall back to any token_v2.
        let sql = """
        SELECT host_key, encrypted_value FROM cookies
        WHERE name = 'token_v2'
        ORDER BY CASE host_key
            WHEN 'app.notion.com' THEN 0
            WHEN '.app.notion.com' THEN 1
            ELSE 2 END,
            length(encrypted_value) DESC
        LIMIT 4
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(stmt, 1) else { continue }
            let count = Int(sqlite3_column_bytes(stmt, 1))
            let data = Data(bytes: bytes, count: count)
            if let token = ChromiumCrypt.decryptCookieValue(data, password: password), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private static func apiHeaders(token: String) -> [String: String] {
        [
            "Cookie": "token_v2=\(token)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        ]
    }

    // MARK: - Workspace selection

    private struct Workspace {
        let id: String
        let name: String
        let planType: String?
        let subscriptionTier: String?

        var tierLabel: String {
            let raw = subscriptionTier ?? planType ?? "unknown"
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }

        var carriesAllowance: Bool {
            let tier = (subscriptionTier ?? "").lowercased()
            let plan = (planType ?? "").lowercased()
            return tier.contains("business") || tier.contains("enterprise")
                || plan.contains("business") || plan.contains("enterprise")
        }
    }

    private static func pickWorkspace(from spacesJSON: [String: Any]) -> Workspace? {
        var found: [Workspace] = []
        for (_, payload) in spacesJSON {
            guard let payload = payload as? [String: Any],
                  let spaceTable = payload["space"] as? [String: Any] else { continue }
            for (spaceID, entry) in spaceTable {
                guard let value = unwrapRecord(entry) else { continue }
                let id = value.string("id")
                    ?? (entry as? [String: Any])?.string("spaceId")
                    ?? spaceID
                let name = value.string("name") ?? "Workspace"
                found.append(Workspace(
                    id: id,
                    name: name,
                    planType: value.string("plan_type") ?? value.string("planType"),
                    subscriptionTier: value.string("subscription_tier") ?? value.string("subscriptionTier")
                ))
            }
        }

        return found.first(where: \.carriesAllowance) ?? found.first
    }

    private static func accountEmail(from spacesJSON: [String: Any]) -> String? {
        for (_, payload) in spacesJSON {
            guard let payload = payload as? [String: Any],
                  let users = payload["notion_user"] as? [String: Any] else { continue }
            for (_, entry) in users {
                if let email = unwrapRecord(entry)?.string("email"), !email.isEmpty {
                    return email
                }
            }
        }
        return nil
    }

    /// `getSpaces` nests records as `{ value: { role, value: { …fields } } }`.
    private static func unwrapRecord(_ entry: Any?) -> [String: Any]? {
        var current = entry as? [String: Any]
        while let dict = current, let nested = dict["value"] as? [String: Any] {
            if dict.string("id") != nil || dict.string("email") != nil { return dict }
            current = nested
        }
        return current
    }

    // MARK: - Parse

    private static func parse(
        rate: [String: Any],
        credits: [String: Any]?,
        workspace: Workspace,
        account: String?
    ) -> ProviderSnapshot {
        var windows: [UsageWindow] = []

        if let window = rate.dict("window"),
           let used = window.number("used"),
           let limit = window.number("limit"), limit > 0 {
            let resets: Date?
            if let seconds = rate.number("resetsInSeconds") {
                resets = Date().addingTimeInterval(seconds)
            } else {
                resets = nil
            }
            let label: String
            if let token = window.string("window"), token.hasSuffix("h"),
               let hours = Int(token.dropLast()) {
                label = "Rolling (\(hours)h)"
            } else {
                label = "Rolling"
            }
            windows.append(UsageWindow(
                id: "rolling",
                title: label,
                usedPercent: used / limit * 100,
                resetsAt: resets
            ))
        }

        if let monthly = rate.dict("billingPeriodWindow"),
           let used = monthly.number("used"),
           let limit = monthly.number("limit"), limit > 0 {
            windows.append(UsageWindow(
                id: "monthly",
                title: "Monthly",
                usedPercent: used / limit * 100,
                resetsAt: monthly.date("periodEndMs")
            ))
        }

        var note: String?
        if let credits {
            let premium = credits.dict("premiumCredits")
            let usage = credits.dict("usage")
            let balance = premium?.number("totalCreditBalance")
                ?? usage?.number("totalCreditBalance")

            if let allocated = premium?.dict("perSource")?.dict("monthlyAllocated"),
               let used = allocated.number("usageTotal"),
               let limit = allocated.number("limit"), limit > 0 {
                let resets = rate.dict("billingPeriodWindow")?.date("periodEndMs")
                windows.append(UsageWindow(
                    id: "credits",
                    title: "Credits",
                    usedPercent: used / limit * 100,
                    resetsAt: resets
                ))
            }

            if let balance {
                let whole = balance.rounded() == balance
                note = whole
                    ? "Credits left: \(Int(balance))"
                    : String(format: "Credits left: %.1f", balance)
            }
        }

        return ProviderSnapshot(
            plan: workspace.tierLabel,
            account: account ?? workspace.name,
            windows: windows,
            renewsAt: rate.dict("billingPeriodWindow")?.date("periodEndMs"),
            source: "notion.app",
            note: note
        )
    }
}
