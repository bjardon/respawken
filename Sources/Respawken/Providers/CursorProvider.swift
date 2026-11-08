import Foundation

/// Cursor has no local usage log — the numbers only exist server-side. Rather than decrypting
/// browser cookie jars, this reads the bearer token Cursor.app already keeps in its own global
/// state database and rebuilds the web session cookie from it. No Keychain prompt, no browser.
///
/// Legacy plans: Cursor Models and Other Models reset at the billing-cycle end, and Grok Bot has
/// a separate weekly allowance. Unified plans (Premium) have one weekly limit for both, plus
/// prepaid credits. The weekly reading comes from Cursor's dashboard RPC with the same token.
struct CursorProvider: UsageProvider {
    let id = ProviderID.cursor

    private var stateDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }

    /// Cursor 3.27+ encrypts auth tokens at rest (`cursor.storage.authTokenEncryptionAtRest`) as
    /// `cursor-safe-storage:v1:<base64 Electron safeStorage blob>`. Older builds store the JWT as-is.
    private static func accessToken(from stored: String) -> Result<String, SafeStorage.Failure> {
        let prefix = "cursor-safe-storage:v1:"
        guard stored.hasPrefix(prefix) else { return .success(stored) }
        guard let blob = Data(base64Encoded: String(stored.dropFirst(prefix.count))) else {
            return .failure(.undecryptable)
        }
        return SafeStorage.decrypt(blob, service: "Cursor Safe Storage", account: "Cursor Key")
    }

    func fetch() async -> ProviderOutcome {
        guard let stored = StateDB.value(forKey: "cursorAuth/accessToken", at: stateDBPath), !stored.isEmpty else {
            return .signedOut("Sign in to Cursor")
        }
        let token: String
        switch Self.accessToken(from: stored) {
        case .success(let value): token = value
        case .failure(.keychainDenied): return .failed("Allow Keychain access to Cursor Safe Storage")
        case .failure(.undecryptable): return .failed("Could not decrypt Cursor session")
        }
        guard let claims = JWT.payload(token), let subject = claims["sub"] as? String else {
            return .failed("Could not read Cursor session")
        }
        if let exp = claims.number("exp"), Date(timeIntervalSince1970: exp) < Date() {
            return .signedOut("Cursor session expired — sign in again")
        }

        let encodedSubject = subject.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) ?? subject

        async let weeklyUsage = fetchWeeklyUsage(token: token)
        do {
            let json = try await HTTP.getJSON(
                "https://cursor.com/api/usage-summary",
                headers: [
                    "Cookie": "WorkosCursorSessionToken=\(encodedSubject)%3A%3A\(token)",
                    "Accept": "application/json",
                ]
            )
            return .ok(parse(json, weekly: await weeklyUsage))
        } catch let failure as HTTP.Failure where failure.status == 401 {
            return .signedOut("Cursor session rejected — sign in again")
        } catch {
            return .failed(error.localizedDescription, transient: HTTP.isTransient(error))
        }
    }

    private struct WeeklyReading {
        var window: UsageWindow?
        var note: String?
        /// Unified billing (Premium and later plans): one weekly limit shared by Cursor and
        /// Grok Bot replaces the monthly Cursor Models / Other Models gates.
        var unified = false
        var prepaidCents: Double?
    }

    /// This optional reading must not turn healthy monthly Cursor usage into an error.
    private func fetchWeeklyUsage(token: String) async -> WeeklyReading {
        do {
            let json = try await HTTP.postJSON(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus",
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Connect-Protocol-Version": "1",
                ],
                body: [:]
            )
            // Enterprise pools and accounts without an included allowance have no
            // individual weekly meter, matching Grok Bot's own Settings screen.
            let unified = isTrue(json["isUnified"])
            let prepaid = unified ? json.number("prepaidAvailableCents") : nil
            guard !isTrue(json["usesPooledEnterpriseAllowance"]),
                  isTrue(json["hasNonZeroIncludedLimit"]) else {
                return WeeklyReading(unified: unified, prepaidCents: prepaid)
            }
            guard let percent = json.number("usagePercent"), percent.isFinite else {
                return WeeklyReading(note: unified ? "Weekly usage unavailable" : "Grok Bot usage unavailable",
                                     unified: unified, prepaidCents: prepaid)
            }
            let resets = json.date("nextResetTimestampUtc")
            let start = json.date("currentPeriodStart")
            let duration: TimeInterval? = {
                guard let resets, let start, resets > start else { return nil }
                return resets.timeIntervalSince(start)
            }()
            let window = unified
                ? UsageWindow(id: "weekly", title: "Weekly",
                              usedPercent: max(0, percent), resetsAt: resets, duration: duration)
                : UsageWindow(id: "grok-weekly", title: "Grok Bot · Weekly",
                              usedPercent: max(0, percent), resetsAt: resets, duration: duration)
            return WeeklyReading(window: window, unified: unified, prepaidCents: prepaid)
        } catch {
            return WeeklyReading(note: "Grok Bot usage unavailable")
        }
    }

    private func parse(_ json: [String: Any], weekly: WeeklyReading) -> ProviderSnapshot {
        let resets = json.date("billingCycleEnd")
        let cycleStart = json.date("billingCycleStart")
        let duration: TimeInterval? = {
            if let resets, let cycleStart, resets > cycleStart {
                return resets.timeIntervalSince(cycleStart)
            }
            return resets.map(Format.monthlyCycleLength(ending:))
        }()
        let individual = json.dict("individualUsage")
        let plan = individual?.dict("plan")

        // Match Cursor's Plan & Usage UI: Cursor Models (auto) + Other Models (API).
        // Ignore plan.used/limit — those are a dollar ledger in cents, not the quota gate.
        // Unified plans still return the monthly percents, frozen at 0 and no longer
        // shown in Plan & Usage, so only the shared weekly limit counts there.
        var windows: [UsageWindow] = []
        if weekly.unified, let window = weekly.window {
            windows.append(window)
        } else if let auto = plan?.number("autoPercentUsed") {
            windows.append(UsageWindow(id: "included", title: "Cursor Models",
                                       usedPercent: auto, resetsAt: resets, duration: duration))
        }
        if !weekly.unified, let api = plan?.number("apiPercentUsed") {
            windows.append(UsageWindow(id: "api", title: "Other Models",
                                       usedPercent: api, resetsAt: resets, duration: duration))
        }
        if !weekly.unified, let window = weekly.window { windows.append(window) }

        var onDemandNote: String?
        if let onDemand = individual?.dict("onDemand"), isTrue(onDemand["enabled"]),
           let used = onDemand.number("used"), let limit = onDemand.number("limit"), limit > 0 {
            windows.append(UsageWindow(id: "onDemand", title: "On-demand",
                                       usedPercent: used / limit * 100, resetsAt: resets, duration: duration))
            onDemandNote = "On-demand: \(formatCents(used)) / \(formatCents(limit))"
        }

        var snapshot = ProviderSnapshot(
            plan: json.string("membershipType").map(planLabel),
            account: StateDB.value(forKey: "cursorAuth/cachedEmail", at: stateDBPath),
            windows: windows,
            renewsAt: resets,
            source: "api"
        )

        let auto = plan?.number("autoPercentUsed") ?? 0
        let api = plan?.number("apiPercentUsed") ?? 0
        if weekly.unified {
            let spent = (weekly.window?.usedPercent ?? 0) >= 100
            let credits = weekly.prepaidCents.map { "Credits remaining: \(formatCents($0))" }
            snapshot.note = [spent ? (onDemandNote ?? "Included usage spent") : onDemandNote, credits]
                .compactMap { $0 }.joined(separator: " · ")
        } else if auto >= 100, api >= 100 {
            snapshot.note = onDemandNote ?? "Included usage spent"
        } else if auto >= 100 {
            snapshot.note = "Cursor Models spent — drawing from Other Models"
        } else {
            snapshot.note = onDemandNote
        }
        snapshot.note = [snapshot.note, weekly.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if snapshot.note?.isEmpty == true { snapshot.note = nil }
        return snapshot
    }

    private func isTrue(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }

    /// Cursor reports on-demand used/limit in cents.
    private func formatCents(_ cents: Double) -> String {
        let dollars = cents / 100
        if dollars == dollars.rounded() {
            return String(format: "$%.0f", dollars)
        }
        return String(format: "$%.2f", dollars)
    }

    private func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pro_plus": return "Pro+"
        case "pro": return "Pro"
        case "ultra": return "Ultra"
        case "free_trial": return "Trial"
        case "free": return "Free"
        case "team", "enterprise": return raw.capitalized
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
