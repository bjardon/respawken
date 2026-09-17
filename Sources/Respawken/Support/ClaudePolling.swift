import CryptoKit
import Darwin
import Foundation

/// Shared by the app and diagnostic processes. Only timestamps are stored, never credentials.
/// Hold the nonblocking file lock for the entire fetch, including token refresh.
final class ClaudePolling {
    static let interval: TimeInterval = 5 * 60
    static let profileInterval: TimeInterval = 24 * 60 * 60

    enum Paused: Error, LocalizedError {
        case busy, scheduled, rateLimited, unavailable

        var errorDescription: String? {
            switch self {
            case .busy: return "Claude refresh already in progress"
            case .scheduled: return "Claude polling paused — waiting before retry"
            case .rateLimited: return "Rate limited — cooling down"
            case .unavailable: return "Claude polling paused — cannot read or save cooldown"
            }
        }
    }

    private struct Account: Codable {
        var nextFetch = Date.distantPast
        var nextProfile = Date.distantPast
        var subscriptionCreatedAt: Date?
    }

    private struct State: Codable {
        var retryAt = Date.distantPast
        var failures = 0
        var accounts: [String: Account] = [:]
    }

    private let fd: Int32
    private let path: URL
    private let key: String
    private let now: () -> Date
    private var state: State

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Respawken/claude-polling", isDirectory: true)
    }

    static func acquire(account: String) async throws -> ClaudePolling {
        // Let the other account finish without blocking a thread or issuing another request.
        for _ in 0..<80 {
            try Task.checkCancellation()
            do { return try ClaudePolling(account: account) }
            catch Paused.busy { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        throw Paused.busy
    }

    init(account: String, directory: URL = ClaudePolling.directory,
         now: @escaping () -> Date = Date.init) throws {
        self.now = now
        key = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        path = directory.appendingPathComponent("cooldown.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        } catch { throw Paused.unavailable }
        let descriptor = open(directory.appendingPathComponent("poll.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw Paused.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw Paused.busy
        }
        fd = descriptor
        do {
            if FileManager.default.fileExists(atPath: path.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: path))
            } else {
                state = State()
            }
        } catch {
            close(descriptor)
            throw Paused.unavailable
        }
    }

    deinit { close(fd) }

    func reserve() throws {
        guard state.retryAt <= now() else { throw Paused.rateLimited }
        guard state.accounts[key, default: Account()].nextFetch <= now() else { throw Paused.scheduled }
        // Save before network access, so crashes and restarts cannot bypass the interval.
        state.accounts[key, default: Account()].nextFetch = now().addingTimeInterval(Self.interval)
        try save()
    }

    var subscriptionCreatedAt: Date? { state.accounts[key]?.subscriptionCreatedAt }

    func reserveProfile() throws -> Bool {
        guard state.retryAt <= now(),
              state.accounts[key, default: Account()].nextProfile <= now() else { return false }
        state.accounts[key, default: Account()].nextProfile = now().addingTimeInterval(Self.profileInterval)
        try save()
        return true
    }

    func cacheSubscription(_ date: Date?) throws {
        state.accounts[key, default: Account()].subscriptionCreatedAt = date
        try save()
    }

    func rateLimited(retryAt: Date?) throws {
        state.failures = min(state.failures + 1, 6)
        let backoff = min(15 * 60 * pow(2, Double(state.failures - 1)), 6 * 60 * 60)
        state.retryAt = max(state.retryAt, now().addingTimeInterval(backoff), retryAt ?? .distantPast)
        try save()
    }

    func succeeded() throws {
        // A profile 429 must not be cleared by the successful usage request preceding it.
        guard state.retryAt <= now() else { return }
        state.failures = 0
        try save()
    }

    private func save() throws {
        do { try JSONEncoder().encode(state).write(to: path, options: .atomic) }
        catch { throw Paused.unavailable }
    }
}

enum RetryAfter {
    static func date(_ value: String?, now: Date = Date()) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
