import Foundation

/// UI language. Picker labels stay in their own language so Español is findable from English.
enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case spanish = "es"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        }
    }
}

/// Tiny in-app catalog. Providers keep English internally; the panel, Settings, and
/// notifications resolve through here so a language switch is instant.
enum L10n {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var language: AppLanguage = .english
    }

    private static let state = State()

    static var language: AppLanguage {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.language
        }
        set {
            state.lock.lock()
            state.language = newValue
            state.lock.unlock()
        }
    }

    static func t(_ key: Key) -> String {
        table[key]?[language] ?? table[key]?[.english] ?? key.rawValue
    }

    static func t(_ key: Key, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    /// Window meter label. Known ids translate even if the snapshot was fetched in English.
    static func windowTitle(id: String, stored: String) -> String {
        switch id {
        case "included": return t(.windowCursorModels)
        case "api": return t(.windowOtherModels)
        case "onDemand": return t(.windowOnDemand)
        case "monthly": return t(.windowMonthly)
        case "credits": return t(.windowCredits)
        case "five_hour": return t(.windowSession5h)
        case "seven_day": return t(.windowWeekly)
        case "seven_day_opus": return t(.windowWeeklyOpus)
        case "seven_day_sonnet": return t(.windowWeeklySonnet)
        case "seven_day_routines": return t(.windowWeeklyRoutines)
        case "seven_day_cowork": return t(.windowWeeklyCowork)
        case "seven_day_fable": return t(.windowWeeklyFable)
        case "extra_usage": return t(.windowUsageCredits)
        case "rolling": return durationTitle(stored)
        case "gemini-weekly": return t(.windowGeminiWeekly)
        case "gemini-5h": return t(.windowGemini5h)
        case "3p-weekly": return t(.windowClaudeGptWeekly)
        case "3p-5h": return t(.windowClaudeGpt5h)
        default: return durationTitle(stored)
        }
    }

    /// Signed-out hints, notes, and HTTP copy that providers emit in English.
    static func display(_ text: String) -> String {
        if text.contains(" · ") {
            return text.components(separatedBy: " · ").map(display).joined(separator: " · ")
        }
        if language == .english { return text }
        if let mapped = messages[text] { return mapped }

        if text.hasPrefix("Run `claude auth login` ("), text.hasSuffix(")") {
            let inner = String(text.dropFirst("Run `claude auth login` (".count).dropLast())
            return t(.claudeRunLogin, inner)
        }
        if text.hasPrefix("Token lacks "), text.hasSuffix(" — re-run `claude auth login`") {
            let scope = String(
                text.dropFirst("Token lacks ".count)
                    .dropLast(" — re-run `claude auth login`".count)
            )
            return t(.claudeTokenLacks, scope)
        }
        if text.hasPrefix("Usage credits: ") {
            return t(.claudeExtraUsagePrefix) + String(text.dropFirst("Usage credits: ".count))
        }
        if text.hasPrefix("Extra usage: ") {
            return t(.claudeExtraUsagePrefix) + String(text.dropFirst("Extra usage: ".count))
        }
        if text.hasPrefix("On-demand: ") {
            return t(.cursorOnDemandPrefix) + String(text.dropFirst("On-demand: ".count))
        }
        if text.hasPrefix("Credits left: ") {
            return t(.creditsLeftPrefix) + String(text.dropFirst("Credits left: ".count))
        }
        if text.hasPrefix("Credits: ") {
            return t(.creditsPrefix) + String(text.dropFirst("Credits: ".count))
        }
        if text.hasPrefix("Resets available: ") {
            return t(.resetsAvailablePrefix) + String(text.dropFirst("Resets available: ".count))
        }
        if text.hasPrefix("AI usage allowance not tracked for ") {
            return notionAllowance(text)
        }
        if text.hasPrefix("HTTP ") { return text }
        return text
    }

    static func notificationWindowPhrase(_ title: String) -> String {
        switch language {
        case .english: return title.lowercased()
        case .spanish: return title.lowercased()
        }
    }

    // MARK: - Keys

    enum Key: String {
        case settings
        case language
        case languageFooter
        case startup
        case launchAtLogin
        case launchAtLoginApprove
        case launchAtLoginFooter
        case keyboard
        case togglePanel
        case shortcutFooter
        case typeShortcut
        case shortcutNone
        case shortcutConflict
        case clearShortcut
        case noClaudeAccounts
        case addClaudeAccount
        case claudeAccounts
        case claudeAccountsFooter
        case menuBarIcon
        case menuBarIconFooter
        case sendTestNotification
        case testNotificationSent
        case testNotificationOff
        case notifications
        case notificationsFooter
        case label
        case removeAccount
        case configDirectory
        case chooseEllipsis
        case choose
        case chooseConfigDirectory
        case providerColour
        case showOnIcon
        case newAccount

        case overview
        case backToOverview
        case refreshNow
        case emptyIcon
        case openProduct
        case noProductAccounts
        case quit
        case loading
        case updatedJustNow
        case updatedAgo
        case checking
        case noUsageReported
        case resetsIn
        case emptiesIn
        case belowPace
        case onPace
        case renewsOn
        case notStarted
        case now

        case windowSession
        case windowWeekly
        case windowDaily
        case window5hour
        case windowNWeek
        case windowNDay
        case windowNHour
        case windowNMin
        case windowUsage
        case windowSession5h
        case windowWeeklyOpus
        case windowWeeklySonnet
        case windowWeeklyRoutines
        case windowWeeklyCowork
        case windowWeeklyFable
        case windowCursorModels
        case windowOtherModels
        case windowOnDemand
        case windowMonthly
        case windowCredits
        case windowGeminiWeekly
        case windowGemini5h
        case windowClaudeGptWeekly
        case windowClaudeGpt5h
        case windowUsageCredits

        case claudeRunLogin
        case claudeTokenLacks
        case claudeExtraUsagePrefix
        case cursorOnDemandPrefix
        case creditsLeftPrefix
        case creditsPrefix
        case resetsAvailablePrefix
        case notionAllowanceNotTracked
        case sourceLocalSessionLog

        case notifyExhaustionTitle
        case notifyResetTitle
        case notifyTestTitle
        case notifyTestBody
        case notifyExhaustionBody
        case notifyResetBody
        case notifySharedResetBody
        case notifyPaceTitle
        case notifyPaceBody
    }

    // MARK: - Catalog

    private static let table: [Key: [AppLanguage: String]] = [
        .settings: [.english: "Settings", .spanish: "Ajustes"],
        .language: [.english: "Language", .spanish: "Idioma"],
        .languageFooter: [
            .english: "Panel, Settings, and notifications. Account labels stay as you typed them.",
            .spanish: "Panel, Ajustes y notificaciones. Las etiquetas de cuenta se quedan como las escribiste.",
        ],
        .startup: [.english: "Startup", .spanish: "Inicio"],
        .launchAtLogin: [.english: "Launch at login", .spanish: "Abrir al iniciar sesión"],
        .launchAtLoginApprove: [
            .english: "Approve Respawken in System Settings → General → Login Items.",
            .spanish: "Autoriza Respawken en Ajustes del Sistema → General → Elementos de inicio.",
        ],
        .launchAtLoginFooter: [
            .english: "Starts Respawken when you log in. Also listed under System Settings → General → Login Items.",
            .spanish: "Abre Respawken al iniciar sesión. También aparece en Ajustes del Sistema → General → Elementos de inicio.",
        ],
        .keyboard: [.english: "Keyboard", .spanish: "Teclado"],
        .togglePanel: [.english: "Toggle panel", .spanish: "Mostrar/ocultar el panel"],
        .shortcutFooter: [
            .english: "Opens the panel from any app. Click the shortcut and press a new one. Delete clears it. Needs at least ⌃, ⌥, or ⌘.",
            .spanish: "Abre el panel desde cualquier app. Haz clic en el atajo y pulsa uno nuevo. Suprimir lo quita. Hace falta al menos ⌃, ⌥ o ⌘.",
        ],
        .typeShortcut: [.english: "Type shortcut", .spanish: "Pulsa un atajo"],
        .shortcutNone: [.english: "None", .spanish: "Ninguno"],
        .shortcutConflict: [
            .english: "Couldn’t take that shortcut — another app may already use it.",
            .spanish: "No se pudo usar ese atajo — puede que otra app ya lo tenga.",
        ],
        .clearShortcut: [.english: "Clear shortcut", .spanish: "Quitar atajo"],
        .noClaudeAccounts: [.english: "No Claude accounts yet.", .spanish: "Aún no hay cuentas de Claude."],
        .addClaudeAccount: [.english: "Add Claude Account", .spanish: "Añadir cuenta de Claude"],
        .claudeAccounts: [.english: "Claude accounts", .spanish: "Cuentas de Claude"],
        .claudeAccountsFooter: [
            .english: "Each account needs a label and the Claude config directory (`CLAUDE_CONFIG_DIR`). Use `~/.claude` for the default login.",
            .spanish: "Cada cuenta necesita una etiqueta y el directorio de configuración de Claude (`CLAUDE_CONFIG_DIR`). Usa `~/.claude` para el inicio de sesión predeterminado.",
        ],
        .menuBarIcon: [.english: "Menu bar icon", .spanish: "Icono de la barra de menús"],
        .menuBarIconFooter: [
            .english: "Panel order is icon order. Up to %d shown providers appear on the icon; fewer collapse to a single column.",
            .spanish: "El orden del panel es el del icono. Hasta %d proveedores visibles aparecen en el icono; si hay menos, se agrupan en una sola columna.",
        ],
        .sendTestNotification: [.english: "Send Test Notification", .spanish: "Enviar notificación de prueba"],
        .testNotificationSent: [
            .english: "Sent — check Notification Center.",
            .spanish: "Enviada — mira el Centro de notificaciones.",
        ],
        .testNotificationOff: [
            .english: "Notifications are off for Respawken. Enable them in System Settings → Notifications.",
            .spanish: "Las notificaciones de Respawken están desactivadas. Actívalas en Ajustes del Sistema → Notificaciones.",
        ],
        .notifications: [.english: "Notifications", .spanish: "Notificaciones"],
        .notificationsFooter: [
            .english: "Posts a sample alert so you can confirm permission and the app icon.",
            .spanish: "Envía una alerta de prueba para confirmar el permiso y el icono de la app.",
        ],
        .label: [.english: "Label", .spanish: "Etiqueta"],
        .removeAccount: [.english: "Remove account", .spanish: "Eliminar cuenta"],
        .configDirectory: [.english: "Config directory", .spanish: "Directorio de configuración"],
        .chooseEllipsis: [.english: "Choose…", .spanish: "Elegir…"],
        .choose: [.english: "Choose", .spanish: "Elegir"],
        .chooseConfigDirectory: [
            .english: "Select the Claude config directory for “%@”.",
            .spanish: "Elige el directorio de configuración de Claude para «%@».",
        ],
        .providerColour: [.english: "Provider colour", .spanish: "Color del proveedor"],
        .showOnIcon: [.english: "Show on menu bar icon", .spanish: "Mostrar en el icono de la barra de menús"],
        .newAccount: [.english: "New account", .spanish: "Cuenta nueva"],

        .overview: [.english: "Overview", .spanish: "Resumen"],
        .backToOverview: [.english: "Back to Overview", .spanish: "Volver al resumen"],
        .refreshNow: [.english: "Refresh now", .spanish: "Actualizar"],
        .emptyIcon: [
            .english: "Nothing on the menu bar. Turn providers on in Settings.",
            .spanish: "No hay nada en la barra de menús. Activa proveedores en Ajustes.",
        ],
        .openProduct: [.english: "Open %@", .spanish: "Abrir %@"],
        .noProductAccounts: [
            .english: "No %@ accounts. Add one in Settings.",
            .spanish: "No hay cuentas de %@. Añade una en Ajustes.",
        ],
        .quit: [.english: "Quit", .spanish: "Salir"],
        .loading: [.english: "Loading…", .spanish: "Cargando…"],
        .updatedJustNow: [.english: "Updated just now", .spanish: "Actualizado ahora"],
        .updatedAgo: [.english: "Updated %@ ago", .spanish: "Actualizado hace %@"],
        .checking: [.english: "Checking…", .spanish: "Comprobando…"],
        .noUsageReported: [.english: "No usage reported", .spanish: "Sin datos de uso"],
        .resetsIn: [.english: "resets in %@", .spanish: "se reinicia en %@"],
        .emptiesIn: [.english: "empties in %@", .spanish: "se agota en %@"],
        .belowPace: [.english: "below pace", .spanish: "ritmo bajo"],
        .onPace: [.english: "on pace", .spanish: "a ritmo"],
        .renewsOn: [.english: "Renews: %@", .spanish: "Se renueva: %@"],
        .notStarted: [.english: "not started", .spanish: "sin empezar"],
        .now: [.english: "now", .spanish: "ahora"],

        .windowSession: [.english: "Session", .spanish: "Sesión"],
        .windowWeekly: [.english: "Weekly", .spanish: "Semanal"],
        .windowDaily: [.english: "Daily", .spanish: "Diario"],
        .window5hour: [.english: "5-hour", .spanish: "5 horas"],
        .windowNWeek: [.english: "%d-week", .spanish: "%d semanas"],
        .windowNDay: [.english: "%d-day", .spanish: "%d días"],
        .windowNHour: [.english: "%d-hour", .spanish: "%d horas"],
        .windowNMin: [.english: "%d-min", .spanish: "%d min"],
        .windowUsage: [.english: "Usage", .spanish: "Uso"],
        .windowSession5h: [.english: "Session (5-hour)", .spanish: "Sesión (5 horas)"],
        .windowWeeklyOpus: [.english: "Weekly · Opus", .spanish: "Semanal · Opus"],
        .windowWeeklySonnet: [.english: "Weekly · Sonnet", .spanish: "Semanal · Sonnet"],
        .windowWeeklyRoutines: [.english: "Weekly · Routines", .spanish: "Semanal · Rutinas"],
        .windowWeeklyCowork: [.english: "Weekly · Cowork", .spanish: "Semanal · Cowork"],
        .windowWeeklyFable: [.english: "Weekly · Fable", .spanish: "Semanal · Fable"],
        .windowCursorModels: [.english: "Cursor Models", .spanish: "Modelos Cursor"],
        .windowOtherModels: [.english: "Other Models", .spanish: "Otros modelos"],
        .windowOnDemand: [.english: "On-demand", .spanish: "Bajo demanda"],
        .windowMonthly: [.english: "Monthly", .spanish: "Mensual"],
        .windowCredits: [.english: "Credits", .spanish: "Créditos"],
        .windowGeminiWeekly: [.english: "Gemini Weekly", .spanish: "Gemini semanal"],
        .windowGemini5h: [.english: "Gemini 5-hour", .spanish: "Gemini 5 horas"],
        .windowClaudeGptWeekly: [.english: "Claude/GPT Weekly", .spanish: "Claude/GPT semanal"],
        .windowClaudeGpt5h: [.english: "Claude/GPT 5-hour", .spanish: "Claude/GPT 5 horas"],
        .windowUsageCredits: [.english: "Usage credits", .spanish: "Créditos de uso"],

        .claudeRunLogin: [
            .english: "Run `claude auth login` (%@)",
            .spanish: "Ejecuta `claude auth login` (%@)",
        ],
        .claudeTokenLacks: [
            .english: "Token lacks %@ — re-run `claude auth login`",
            .spanish: "El token no tiene %@ — vuelve a ejecutar `claude auth login`",
        ],
        .claudeExtraUsagePrefix: [.english: "Usage credits: ", .spanish: "Créditos de uso: "],
        .cursorOnDemandPrefix: [.english: "On-demand: ", .spanish: "Bajo demanda: "],
        .creditsLeftPrefix: [.english: "Credits left: ", .spanish: "Créditos restantes: "],
        .creditsPrefix: [.english: "Credits: ", .spanish: "Créditos: "],
        .resetsAvailablePrefix: [.english: "Resets available: ", .spanish: "Reinicios disponibles: "],
        .notionAllowanceNotTracked: [
            .english: "AI usage allowance not tracked for %@ (%@)",
            .spanish: "El uso de IA de %@ (%@) no se rastrea",
        ],
        .sourceLocalSessionLog: [.english: "local session log", .spanish: "registro de sesión local"],

        .notifyExhaustionTitle: [.english: "🔥 Running on fumes", .spanish: "🔥 En las últimas"],
        .notifyResetTitle: [.english: "✨ Fresh limits", .spanish: "✨ Límites renovados"],
        .notifyTestTitle: [.english: "👋 Still here", .spanish: "👋 Sigo aquí"],
        .notifyTestBody: [
            .english: "Test notification — looking good.",
            .spanish: "Notificación de prueba — todo bien.",
        ],
        .notifyExhaustionBody: [
            .english: "%1$@’s %2$@ just hit %3$@",
            .spanish: "%1$@ acaba de llegar al %3$@ en %2$@",
        ],
        .notifyResetBody: [
            .english: "%1$@’s %2$@ just reset",
            .spanish: "%1$@ acaba de reiniciar su %2$@",
        ],
        .notifySharedResetBody: [
            .english: "%@’s limits just reset",
            .spanish: "Los límites de %@ se acaban de reiniciar",
        ],
        .notifyPaceTitle: [.english: "⏳ Ahead of pace", .spanish: "⏳ Ritmo alto"],
        .notifyPaceBody: [
            .english: "%1$@’s %2$@ is on track to empty in %3$@",
            .spanish: "%1$@ va camino de agotar su %2$@ en %3$@",
        ],
    ]

    private static let messages: [String: String] = [
        "Run `codex login`": "Ejecuta `codex login`",
        "Token expired — showing last session": "Token caducado — mostrando la última sesión",
        "Token expired — run `codex login`": "Token caducado — ejecuta `codex login`",
        "API unreachable — showing last session": "API no disponible — mostrando la última sesión",
        "Refresh returned no access token": "La renovación no devolvió un token de acceso",
        "Sign in to Cursor": "Inicia sesión en Cursor",
        "Could not read Cursor session": "No se pudo leer la sesión de Cursor",
        "Cursor session expired — sign in again": "Sesión de Cursor caducada — vuelve a iniciar sesión",
        "Cursor session rejected — sign in again": "Sesión de Cursor rechazada — vuelve a iniciar sesión",
        "Included usage spent — running on on-demand": "Uso incluido agotado — usando bajo demanda",
        "Included usage spent": "Uso incluido agotado",
        "Cursor Models spent — drawing from Other Models": "Modelos Cursor agotados — usando Otros modelos",
        "Install and sign in to Notion.app": "Instala Notion.app e inicia sesión",
        "Sign in to Notion.app (or Allow Keychain access)": "Inicia sesión en Notion.app (o permite el acceso al Llavero)",
        "No Business/Enterprise Notion workspace found": "No se encontró un espacio Notion Business/Enterprise",
        "Notion session rejected — sign in to Notion.app again": "Sesión de Notion rechazada — vuelve a iniciar sesión en Notion.app",
        "No limit windows reported": "No se informaron ventanas de límite",
        "No usage reported": "Sin datos de uso",
        "Session expired — run `claude auth login`": "Sesión caducada — ejecuta `claude auth login`",
        "Rate limited — will retry": "Límite de peticiones — se reintentará",
        "Unauthorized": "No autorizado",
        "Bad request": "Petición incorrecta",
        "local session log": "registro de sesión local",
        "Run `agy` and sign in": "Ejecuta `agy` e inicia sesión",
        "Token expired — run `agy` and sign in": "Token caducado — ejecuta `agy` e inicia sesión",
        "agy": "agy",
    ]

    private static func durationTitle(_ stored: String) -> String {
        switch stored {
        case "Session": return t(.windowSession)
        case "Weekly": return t(.windowWeekly)
        case "Daily": return t(.windowDaily)
        case "5-hour": return t(.window5hour)
        case "Usage": return t(.windowUsage)
        case "Monthly": return t(.windowMonthly)
        case "Credits": return t(.windowCredits)
        case "Gemini Weekly": return t(.windowGeminiWeekly)
        case "Gemini 5-hour": return t(.windowGemini5h)
        case "Claude/GPT Weekly": return t(.windowClaudeGptWeekly)
        case "Claude/GPT 5-hour": return t(.windowClaudeGpt5h)
        case "Usage credits", "Extra usage": return t(.windowUsageCredits)
        default:
            if let match = unitTitle(stored) { return match }
            return stored
        }
    }

    private static func unitTitle(_ stored: String) -> String? {
        let suffixes: [(String, Key)] = [
            ("-week", .windowNWeek),
            ("-day", .windowNDay),
            ("-hour", .windowNHour),
            ("-min", .windowNMin),
        ]
        for (suffix, key) in suffixes {
            guard stored.hasSuffix(suffix),
                  let value = Int(stored.dropLast(suffix.count))
            else { continue }
            return t(key, value)
        }
        return nil
    }

    private static func notionAllowance(_ text: String) -> String {
        let prefix = "AI usage allowance not tracked for "
        guard text.hasPrefix(prefix),
              let rparen = text.lastIndex(of: ")"),
              let lparen = text.lastIndex(of: "("),
              lparen < rparen
        else { return text }
        let nameStart = text.index(text.startIndex, offsetBy: prefix.count)
        let name = String(text[nameStart..<lparen]).trimmingCharacters(in: .whitespaces)
        let tier = String(text[text.index(after: lparen)..<rparen])
        return t(.notionAllowanceNotTracked, name, tier)
    }
}
