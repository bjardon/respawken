import Foundation
import ServiceManagement

/// Registers the running bundle as a login item via `SMAppService`.
///
/// First interactive launch turns it on once. After that the in-app toggle and
/// System Settings are the only writers — we don't re-register on later launches
/// if it was turned off.
enum LaunchAtLogin {
    private static let appliedDefaultKey = "respawken.didApplyLaunchAtLoginDefault"

    private(set) static var lastError: String?

    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func applyDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: appliedDefaultKey) else { return }

        let status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval {
            defaults.set(true, forKey: appliedDefaultKey)
            return
        }

        if let error = setEnabled(true) {
            lastError = error
            return
        }
        defaults.set(true, forKey: appliedDefaultKey)
    }

    /// Returns an error string on failure, otherwise nil.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
            return nil
        } catch {
            lastError = error.localizedDescription
            return error.localizedDescription
        }
    }
}
