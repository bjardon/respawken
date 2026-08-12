import Foundation

/// Cursor has no local usage log — the numbers only exist server-side. Rather than decrypting
/// browser cookie jars, this reads the bearer token Cursor.app already keeps in its own global
/// state database and rebuilds the web session cookie from it. No Keychain prompt, no browser.
///
/// Cursor bills on a monthly cycle rather than rolling windows, so "resets" means the end of the
/// current billing period.
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

        do {
            let json = try await HTTP.getJSON(
                "https://cursor.com/api/usage-summary",
                headers: [
                    "Cookie": "WorkosCursorSessionToken=\(encodedSubject)%3A%3A\(token)",
                    "Accept": "application/json",
                ]
            )
            return .ok(parse(json))
        } catch let failure as HTTP.Failure where failure.status == 401 {
            return .signedOut("Cursor session rejected — sign in again")
        } catch {
            return .failed(error.localizedDescription, transient: HTTP.isTransient(error))
        }
    }

    private func parse(_ json: [String: Any]) -> ProviderSnapshot {
        let resets = json.date("billingCycleEnd")
        let individual = json.dict("individualUsage")
        let plan = individual?.dict("plan")

        // Match Cursor's Plan & Usage UI: Cursor Models (auto) + Other Models (API).
        // Ignore plan.used/limit — those are a dollar ledger in cents, not the quota gate.
        var windows: [UsageWindow] = []
        if let auto = plan?.number("autoPercentUsed") {
            windows.append(UsageWindow(id: "included", title: "Cursor Models",
                                       usedPercent: auto, resetsAt: resets))
        }
        if let api = plan?.number("apiPercentUsed") {
            windows.append(UsageWindow(id: "api", title: "Other Models",
                                       usedPercent: api, resetsAt: resets))
        }
        if let onDemand = individual?.dict("onDemand"), onDemand["enabled"] as? Bool == true,
           let used = onDemand.number("used"), let limit = onDemand.number("limit"), limit > 0 {
            windows.append(UsageWindow(id: "onDemand", title: "On-demand",
                                       usedPercent: used / limit * 100, resetsAt: resets))
        }

        var snapshot = ProviderSnapshot(
            plan: json.string("membershipType").map(planLabel),
            account: StateDB.value(forKey: "cursorAuth/cachedEmail", at: stateDBPath),
            windows: windows,
            source: "api"
        )

        // Percentages gate the plan; only annotate when a bar is actually exhausted.
        let auto = plan?.number("autoPercentUsed") ?? 0
        let api = plan?.number("apiPercentUsed") ?? 0
        let onDemand = individual?.dict("onDemand")
        let onDemandSpend = onDemand.flatMap { $0.number("used") } ?? 0
        let onDemandEnabled = onDemand?["enabled"] as? Bool == true
        if auto >= 100, api >= 100 {
            if onDemandEnabled, onDemandSpend > 0 {
                snapshot.note = "Included usage spent — running on on-demand"
            } else {
                snapshot.note = "Included usage spent"
            }
        } else if auto >= 100 {
            snapshot.note = "Cursor Models spent — drawing from Other Models"
        }
        return snapshot
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
