import Foundation

/// Cursor has no local usage log — the numbers only exist server-side. Rather than decrypting
/// browser cookie jars, this reads the bearer token Cursor.app already keeps in its own global
/// state database and rebuilds the web session cookie from it. No Keychain prompt, no browser.
///
/// Cursor's IDE windows reset at the billing-cycle end. Grok Bot has a separate weekly
/// allowance, read from Cursor's dashboard RPC with the same bearer token.
struct CursorProvider: UsageProvider {
    let id = ProviderID.cursor

    private var stateDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }

    func fetch() async -> ProviderOutcome {
        guard let token = StateDB.value(forKey: "cursorAuth/accessToken", at: stateDBPath), !token.isEmpty else {
            return .signedOut("Sign in to Cursor")
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

        async let grokUsage = fetchGrokUsage(token: token)
        do {
            let json = try await HTTP.getJSON(
                "https://cursor.com/api/usage-summary",
                headers: [
                    "Cookie": "WorkosCursorSessionToken=\(encodedSubject)%3A%3A\(token)",
                    "Accept": "application/json",
                ]
            )
            let grok = await grokUsage
            return .ok(parse(json, grokWindow: grok.window, grokNote: grok.note))
        } catch let failure as HTTP.Failure where failure.status == 401 {
            return .signedOut("Cursor session rejected — sign in again")
        } catch {
            return .failed(error.localizedDescription, transient: HTTP.isTransient(error))
        }
    }

    /// This optional reading must not turn healthy monthly Cursor usage into an error.
    private func fetchGrokUsage(token: String) async -> (window: UsageWindow?, note: String?) {
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
            guard !isTrue(json["usesPooledEnterpriseAllowance"]),
                  isTrue(json["hasNonZeroIncludedLimit"]) else { return (nil, nil) }
            guard let percent = json.number("usagePercent"), percent.isFinite else {
                return (nil, "Grok Bot usage unavailable")
            }
            let resets = json.date("nextResetTimestampUtc")
            let start = json.date("currentPeriodStart")
            let duration: TimeInterval? = {
                guard let resets, let start, resets > start else { return nil }
                return resets.timeIntervalSince(start)
            }()
            return (UsageWindow(id: "grok-weekly", title: "Grok Bot · Weekly",
                                usedPercent: max(0, percent), resetsAt: resets, duration: duration), nil)
        } catch {
            return (nil, "Grok Bot usage unavailable")
        }
    }

    private func parse(_ json: [String: Any], grokWindow: UsageWindow?, grokNote: String?) -> ProviderSnapshot {
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
        var windows: [UsageWindow] = []
        if let auto = plan?.number("autoPercentUsed") {
            windows.append(UsageWindow(id: "included", title: "Cursor Models",
                                       usedPercent: auto, resetsAt: resets, duration: duration))
        }
        if let api = plan?.number("apiPercentUsed") {
            windows.append(UsageWindow(id: "api", title: "Other Models",
                                       usedPercent: api, resetsAt: resets, duration: duration))
        }
        if let grokWindow { windows.append(grokWindow) }

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
        if auto >= 100, api >= 100 {
            snapshot.note = onDemandNote ?? "Included usage spent"
        } else if auto >= 100 {
            snapshot.note = "Cursor Models spent — drawing from Other Models"
        } else {
            snapshot.note = onDemandNote
        }
        snapshot.note = [snapshot.note, grokNote].compactMap { $0 }.joined(separator: " · ")
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
