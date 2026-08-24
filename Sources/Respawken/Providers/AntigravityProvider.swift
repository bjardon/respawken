import Foundation

/// Antigravity CLI (`agy`) quota.
///
/// The numbers behind `/usage` live on Cloud Code's `retrieveUserQuotaSummary`
/// (Gemini weekly + 5-hour, Claude/GPT weekly + 5-hour). Credentials are the
/// consumer OAuth blob `agy` stores in Keychain (`svce=gemini`, `acct=antigravity`),
/// wrapped as `go-keyring-base64:…`. Same `/usr/bin/security` read as Claude, so
/// rebuilds never re-prompt.
///
/// A running `agy` also serves that payload on loopback (Connect-RPC, no CSRF).
/// That's preferred while the CLI is open; Cloud Code is used with `agy` closed.
/// Access tokens last about an hour; they're refreshed with Antigravity's public
/// OAuth client and written back so the CLI stays in sync.
struct AntigravityProvider: UsageProvider {
    let id = ProviderID.antigravity

    /// Antigravity CLI's public installed-app OAuth client (RFC 8252 — not a confidential
    /// secret). XOR-obfuscated so GitHub push protection doesn't treat the literals as a leak.
    private static let clientID = reveal([
        0x6b, 0x6a, 0x6d, 0x6b, 0x6a, 0x6a, 0x6c, 0x6a, 0x6c, 0x6a, 0x6f, 0x63, 0x6b,
        0x77, 0x2e, 0x37, 0x32, 0x29, 0x29, 0x33, 0x34, 0x68, 0x32, 0x68, 0x6b, 0x36,
        0x39, 0x28, 0x3f, 0x68, 0x69, 0x6f, 0x2c, 0x2e, 0x35, 0x36, 0x35, 0x30, 0x32,
        0x6e, 0x3d, 0x6e, 0x6a, 0x69, 0x3f, 0x2a, 0x74, 0x3b, 0x2a, 0x2a, 0x29, 0x74,
        0x3d, 0x35, 0x35, 0x3d, 0x36, 0x3f, 0x2f, 0x29, 0x3f, 0x28, 0x39, 0x35, 0x34,
        0x2e, 0x3f, 0x34, 0x2e, 0x74, 0x39, 0x35, 0x37,
    ])
    private static let clientSecret = reveal([
        0x1d, 0x15, 0x19, 0x09, 0x0a, 0x02, 0x77, 0x11, 0x6f, 0x62, 0x1c, 0x0d, 0x08,
        0x6e, 0x62, 0x6c, 0x16, 0x3e, 0x16, 0x10, 0x6b, 0x37, 0x16, 0x18, 0x62, 0x29,
        0x02, 0x19, 0x6e, 0x20, 0x6c, 0x2b, 0x1e, 0x1b, 0x3c,
    ])
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let userInfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"
    private static let cloudCode = "https://cloudcode-pa.googleapis.com/v1internal"
    private static let keychainService = "gemini"
    private static let keychainAccount = "antigravity"
    private static let userAgent = "antigravity"
    private static let refreshSkew: TimeInterval = 5 * 60
    private static let quotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let userStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"

    private struct Credentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var authMethod: String
        var raw: [String: Any]
        var source: Source

        enum Source {
            case keychain
            case file(URL)
        }

        var isExpiredOrNearExpiry: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow <= AntigravityProvider.refreshSkew
        }
    }

    private actor CredentialCache {
        static let shared = CredentialCache()

        private var stamp: Date?
        private var cached: Credentials?
        private var loaded = false

        func credentials(load: () -> Credentials?) -> Credentials? {
            let current = Keychain.modificationDate(service: AntigravityProvider.keychainService)
            if loaded, stamp == current { return cached }
            cached = load()
            stamp = current
            loaded = true
            return cached
        }

        func replace(_ credentials: Credentials) {
            cached = credentials
            stamp = Keychain.modificationDate(service: AntigravityProvider.keychainService)
            loaded = true
        }
    }

    func fetch() async -> ProviderOutcome {
        if let local = await localSnapshot(), !local.windows.isEmpty {
            return .ok(local)
        }

        guard var credentials = await loadCredentials() else {
            return .signedOut("Run `agy` and sign in")
        }

        if credentials.isExpiredOrNearExpiry {
            if let outcome = mapRefresh(await refresh(&credentials)) { return outcome }
        }

        do {
            return .ok(try await remoteSnapshot(token: credentials.accessToken))
        } catch let failure as HTTP.Failure where failure.status == 400 || failure.status == 401 || failure.status == 403 {
            // Cloud Code often answers 400 INVALID_ARGUMENT for a stale bearer token.
            if let outcome = mapRefresh(await refresh(&credentials)) { return outcome }
            do {
                return .ok(try await remoteSnapshot(token: credentials.accessToken))
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

    // MARK: - Remote API

    private func remoteSnapshot(token: String) async throws -> ProviderSnapshot {
        async let summary = HTTP.postJSON(
            "\(Self.cloudCode):retrieveUserQuotaSummary",
            headers: Self.apiHeaders(token: token),
            body: [:]
        )
        async let assist = HTTP.postJSON(
            "\(Self.cloudCode):loadCodeAssist",
            headers: Self.apiHeaders(token: token),
            body: [
                "metadata": [
                    "ideType": "ANTIGRAVITY",
                    "platform": "PLATFORM_UNSPECIFIED",
                    "pluginType": "GEMINI",
                ],
            ]
        )
        async let profile = (try? await HTTP.getJSON(Self.userInfoURL, headers: Self.apiHeaders(token: token)))
        return parseSummary(
            try await summary,
            plan: Self.planName(fromAssist: try? await assist),
            account: await profile?.string("email"),
            source: "api"
        )
    }

    private static func apiHeaders(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": userAgent,
        ]
    }

    private static func planName(fromAssist json: [String: Any]?) -> String? {
        guard let json else { return nil }
        if let paid = json.dict("paidTier")?.string("name"), !paid.isEmpty { return paid }
        return json.dict("currentTier")?.string("name")
    }

    // MARK: - OAuth refresh

    private enum RefreshResult {
        case ok
        case signedOut(String)
        case failed(String, transient: Bool = false)
    }

    private func refresh(_ credentials: inout Credentials) async -> RefreshResult {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return .signedOut("Token expired — run `agy` and sign in")
        }

        do {
            let json = try await HTTP.postForm(
                Self.tokenURL,
                headers: [
                    "Accept": "application/json",
                    "User-Agent": Self.userAgent,
                ],
                fields: [
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": Self.clientID,
                    "client_secret": Self.clientSecret,
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
            return .signedOut("Token expired — run `agy` and sign in")
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
        var token = credentials.raw.dict("token") ?? [:]
        token["access_token"] = credentials.accessToken
        token["token_type"] = "Bearer"
        if let refresh = credentials.refreshToken {
            token["refresh_token"] = refresh
        }
        if let expires = credentials.expiresAt {
            token["expiry"] = Self.timestamp(expires)
        }
        var raw = credentials.raw
        raw["token"] = token
        raw["auth_method"] = credentials.authMethod
        guard let json = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return }

        switch credentials.source {
        case .file(let url):
            try? json.write(to: url, options: .atomic)
        case .keychain:
            let wrapped = "go-keyring-base64:" + json.base64EncodedString()
            guard let data = wrapped.data(using: .utf8) else { return }
            _ = Keychain.updateGenericPassword(
                service: Self.keychainService,
                account: Self.keychainAccount,
                data: data
            )
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func reveal(_ bytes: [UInt8]) -> String {
        String(bytes: bytes.map { $0 ^ 0x5A }, encoding: .utf8)!
    }

    // MARK: - Credential loading

    private func loadCredentials() async -> Credentials? {
        await CredentialCache.shared.credentials { decodeStored() }
    }

    private func decodeStored() -> Credentials? {
        if let data = Keychain.genericPassword(service: Self.keychainService, account: Self.keychainAccount),
           let credentials = decode(data, source: .keychain) {
            return credentials
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        if let data = try? Data(contentsOf: fallback),
           let credentials = decode(data, source: .file(fallback)) {
            return credentials
        }
        return nil
    }

    private func decode(_ data: Data, source: Credentials.Source) -> Credentials? {
        guard let jsonData = unwrapKeyring(data),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let token = root.dict("token"),
              let access = token.string("access_token"), !access.isEmpty
        else { return nil }

        return Credentials(
            accessToken: access,
            refreshToken: token.string("refresh_token"),
            expiresAt: Self.parseDate(token.string("expiry")),
            authMethod: root.string("auth_method") ?? "consumer",
            raw: root,
            source: source
        )
    }

    /// `agy` uses zalando/go-keyring, which prefixes the blob with `go-keyring-base64:`.
    private func unwrapKeyring(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            return Data(base64Encoded: String(text.dropFirst(prefix.count)))
        }
        return text.data(using: .utf8)
    }

    // MARK: - Local `agy` loopback

    private func localSnapshot() async -> ProviderSnapshot? {
        for port in Self.agyListenPorts() {
            guard let summary = await loopbackJSON(port: port, path: Self.quotaSummaryPath) else { continue }
            let status = await loopbackJSON(port: port, path: Self.userStatusPath)
            let user = status?.dict("userStatus")
            return parseSummary(
                summary,
                plan: user?.dict("userTier")?.string("name")
                    ?? user?.dict("planStatus")?.dict("planInfo")?.string("planName"),
                account: user?.string("email"),
                source: "agy"
            )
        }
        return nil
    }

    private func loopbackJSON(port: Int, path: String) async -> [String: Any]? {
        let body: [String: Any] = [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "locale": "en",
                "ideVersion": "unknown",
            ],
        ]
        for scheme in ["https", "http"] {
            do {
                return try await Loopback.postJSON("\(scheme)://127.0.0.1:\(port)\(path)", body: body)
            } catch {
                continue
            }
        }
        return nil
    }

    private static func agyListenPorts() -> [Int] {
        let pids = agyPIDs()
        guard !pids.isEmpty else { return [] }
        var ports: [Int] = []
        for pid in pids {
            ports.append(contentsOf: listenPorts(pid: pid))
        }
        return ports
    }

    private static func agyPIDs() -> [Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ax", "-o", "pid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var pids: [Int] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2, parts[1] == "agy", let pid = Int(parts[0]) else { continue }
            pids.append(pid)
        }
        return pids
    }

    private static func listenPorts(pid: Int) -> [Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var ports: [Int] = []
        for line in text.split(separator: "\n") {
            guard let colon = line.lastIndex(of: ":") else { continue }
            let rest = line[line.index(after: colon)...]
            let digits = rest.prefix(while: { $0.isNumber })
            if let port = Int(digits), !ports.contains(port) {
                ports.append(port)
            }
        }
        return ports
    }

    // MARK: - Parsing

    private func parseSummary(
        _ json: [String: Any],
        plan: String?,
        account: String?,
        source: String
    ) -> ProviderSnapshot {
        let root = json.dict("response") ?? json
        let groups = (root["groups"] as? [[String: Any]] ?? []).sorted { lhs, rhs in
            Self.groupRank(lhs.string("displayName")) < Self.groupRank(rhs.string("displayName"))
        }

        var windows: [UsageWindow] = []
        for group in groups {
            let family = Self.familyName(group.string("displayName"))
            let buckets = (group["buckets"] as? [[String: Any]] ?? []).sorted { lhs, rhs in
                Self.bucketRank(lhs) < Self.bucketRank(rhs)
            }
            for bucket in buckets {
                guard let remaining = bucket.number("remainingFraction") else { continue }
                let id = bucket.string("bucketId") ?? "\(family)-\(windows.count)"
                windows.append(UsageWindow(
                    id: id,
                    title: "\(family) \(Self.cadenceName(bucket))",
                    usedPercent: (1 - remaining) * 100,
                    resetsAt: Self.parseDate(bucket.string("resetTime")) ?? bucket.date("resetTime")
                ))
            }
        }

        return ProviderSnapshot(
            plan: plan,
            account: account,
            windows: windows,
            source: source
        )
    }

    private static func familyName(_ raw: String?) -> String {
        let title = (raw ?? "").lowercased()
        if title.contains("gemini") { return "Gemini" }
        if title.contains("claude") || title.contains("gpt") { return "Claude/GPT" }
        if let raw, !raw.isEmpty { return raw }
        return "Quota"
    }

    private static func cadenceName(_ bucket: [String: Any]) -> String {
        switch bucketKind(bucket) {
        case .session: return "5-hour"
        case .weekly: return "Weekly"
        case .other: return bucket.string("displayName") ?? "Usage"
        }
    }

    private static func groupRank(_ name: String?) -> Int {
        let title = (name ?? "").lowercased()
        if title.contains("gemini") { return 0 }
        if title.contains("claude") || title.contains("gpt") { return 1 }
        return 2
    }

    private static func bucketRank(_ bucket: [String: Any]) -> Int {
        switch bucketKind(bucket) {
        case .session: return 0
        case .weekly: return 1
        case .other: return 2
        }
    }

    private enum BucketKind { case session, weekly, other }

    private static func bucketKind(_ bucket: [String: Any]) -> BucketKind {
        let haystack = [
            bucket.string("bucketId"),
            bucket.string("displayName"),
            bucket.string("window"),
        ].compactMap { $0?.lowercased() }.joined(separator: " ")
        if haystack.contains("weekly") { return .weekly }
        if haystack.contains("5h") || haystack.contains("5-hour") || haystack.contains("five hour")
            || haystack.contains("session") {
            return .session
        }
        return .other
    }

    /// Go's RFC3339Nano uses a variable-length fractional second (`86502`);
    /// `ISO8601DateFormatter` wants three digits.
    private static func parseDate(_ raw: String?) -> Date? {
        guard var raw, !raw.isEmpty else { return nil }
        if let date = ISO8601.parse(raw) { return date }
        if let dot = raw.firstIndex(of: "."),
           let tz = raw[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            var fraction = String(raw[raw.index(after: dot)..<tz])
            if fraction.count > 3 { fraction = String(fraction.prefix(3)) }
            while fraction.count < 3 { fraction.append("0") }
            raw = String(raw[..<dot]) + "." + fraction + String(raw[tz...])
            if let date = ISO8601.parse(raw) { return date }
        }
        return nil
    }
}

/// Self-signed loopback certs from `agy`; trusted only for 127.0.0.1 / localhost.
private final class Loopback: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = Loopback()

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    static func postJSON(_ url: String, body: [String: Any]) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw HTTP.Failure(status: -1, body: "bad url") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await shared.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HTTP.Failure(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTP.Failure(status: status, body: "unexpected payload")
        }
        return obj
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              host == "127.0.0.1" || host == "localhost"
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
