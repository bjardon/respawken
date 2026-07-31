import Foundation
import SQLite3
import Security

enum Keychain {
    private static func base(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    /// Reading attributes needs no authorization, so this is cheap and never prompts. Callers
    /// poll it and only re-read the secret when it changes.
    static func modificationDate(service: String) -> Date? {
        var query = base(service)
        query[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let attrs = out as? [String: Any] else { return nil }
        return attrs[kSecAttrModificationDate as String] as? Date
    }

    /// Account attribute (`acct`) for a generic-password item, needed when rewriting the secret.
    static func account(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        // security dumps lines like:     "acct"<blob>="brunojardon"
        for line in text.split(separator: "\n") where line.contains("\"acct\"") {
            guard let blob = line.range(of: "<blob>=\""),
                  let end = line[blob.upperBound...].firstIndex(of: "\"") else { continue }
            let value = String(line[blob.upperBound..<end])
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Delegates the secret read to `/usr/bin/security` rather than calling `SecItemCopyMatching`
    /// directly.
    ///
    /// Claude Code's Keychain item grants access to that Apple-signed tool, so it reads in ~20 ms
    /// and never prompts. Asking for the same secret in-process triggers an authorization prompt
    /// costing ~8 s, and macOS pins the resulting "Always Allow" grant to the binary's code hash,
    /// so every rebuild prompts again — signing with a real certificate and a hash-free designated
    /// requirement does not change that.
    static func genericPassword(service: String) -> Data? {
        runSecurity(["find-generic-password", "-s", service, "-w"])
    }

    /// Overwrites an existing generic-password item via `security -U`. Used after Claude OAuth
    /// refresh so the rotated refresh token stays shared with Claude Code.
    @discardableResult
    static func updateGenericPassword(service: String, account: String, data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return runSecurity([
            "add-generic-password",
            "-s", service,
            "-a", account,
            "-w", text,
            "-U",
        ]) != nil
    }

    @discardableResult
    private static func runSecurity(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // `-w` appends a newline, which would break JSON parsing.
        guard arguments.contains("-w"), let text = String(data: data, encoding: .utf8) else {
            return data.isEmpty ? Data() : data
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
    }
}

/// Reads a single key out of a VS Code style `state.vscdb`.
///
/// Cursor's global state database is multi-gigabyte and is written by the running
/// editor, so it is opened read-only with `immutable=1`: no locking, no WAL recovery,
/// no copy. A point lookup stays in the low milliseconds regardless of file size.
enum StateDB {
    static func value(forKey key: String, at path: String) -> String? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(encoded)?immutable=1", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
                                 -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }
}

enum JWT {
    /// Decodes the payload without verifying — we only need the `sub` and `exp` claims.
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Loose accessors so provider payload changes degrade into "no data" instead of a crash.
extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }

    func string(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func number(_ keys: String...) -> Double? {
        for key in keys {
            if let n = self[key] as? NSNumber { return n.doubleValue }
            if let s = self[key] as? String, let d = Double(s) { return d }
        }
        return nil
    }

    /// Accepts epoch seconds, epoch milliseconds, or an ISO-8601 string.
    func date(_ keys: String...) -> Date? {
        for key in keys {
            if let n = self[key] as? NSNumber {
                let v = n.doubleValue
                guard v > 0 else { continue }
                return Date(timeIntervalSince1970: v > 100_000_000_000 ? v / 1000 : v)
            }
            if let s = self[key] as? String {
                if let d = ISO8601.parse(s) { return d }
                if let v = Double(s), v > 0 {
                    return Date(timeIntervalSince1970: v > 100_000_000_000 ? v / 1000 : v)
                }
            }
        }
        return nil
    }
}

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}

enum HTTP {
    struct Failure: Error, LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? {
            switch status {
            case 429: return "Rate limited — will retry"
            case 401, 403: return "Unauthorized"
            case -1: return body.isEmpty ? "Bad request" : body
            default: return "HTTP \(status)"
            }
        }
        var isTransient: Bool { status == 429 || status == 502 || status == 503 || status == 504 }
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func getJSON(_ url: String, headers: [String: String]) async throws -> [String: Any] {
        try await requestJSON(url, method: "GET", headers: headers, body: nil)
    }

    static func postJSON(_ url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await requestJSON(url, method: "POST", headers: headers, body: data)
    }

    private static func requestJSON(
        _ url: String,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw Failure(status: -1, body: "bad url") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw Failure(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(status: status, body: "unexpected payload")
        }
        return obj
    }
}

enum FileTail {
    /// Reads the trailing bytes of a file so we never pull a large log fully into memory.
    static func lines(of path: String, maxBytes: Int = 512 * 1024) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }
}
