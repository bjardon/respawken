import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var accounts: [ClaudeAccount] = []
    @State private var launchAtLoginEnabled = false
    @State private var launchAtLoginNote: String?
    @State private var shortcutNote: String?
    @State private var testNotificationNote: String?

    var body: some View {
        let _ = store.settings.language
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t(.settings))
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider()

            Form {
                Section {
                    Picker(selection: languageBinding) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(language)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text(L10n.t(.language))
                } footer: {
                    Text(L10n.t(.languageFooter))
                }

                Section {
                    Toggle(L10n.t(.launchAtLogin), isOn: launchAtLoginBinding)
                    if LaunchAtLogin.needsApproval {
                        Text(L10n.t(.launchAtLoginApprove))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let launchAtLoginNote {
                        Text(launchAtLoginNote)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.t(.startup))
                } footer: {
                    Text(L10n.t(.launchAtLoginFooter))
                }

                Section {
                    HStack {
                        Text(L10n.t(.togglePanel))
                        Spacer()
                        ShortcutRecorder(combo: panelShortcutBinding)
                    }
                    if let shortcutNote {
                        Text(shortcutNote)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.t(.keyboard))
                } footer: {
                    Text(L10n.t(.shortcutFooter))
                }

                Section {
                    if accounts.isEmpty {
                        Text(L10n.t(.noClaudeAccounts))
                            .foregroundStyle(.secondary)
                    }

                    ForEach($accounts) { $account in
                        AccountEditor(account: $account) {
                            accounts.removeAll { $0.id == account.id }
                        }
                    }

                    Button(L10n.t(.addClaudeAccount)) {
                        accounts.append(.make())
                    }
                } header: {
                    Text(L10n.t(.claudeAccounts))
                } footer: {
                    Text(L10n.t(.claudeAccountsFooter))
                }

                Section {
                    ForEach(store.providerOrder) { provider in
                        IconProviderEditor(
                            title: store.title(for: provider),
                            accent: store.accent(for: provider),
                            prefs: store.settings.prefs(for: provider),
                            windowOptions: store.iconWindowOptions(for: provider),
                            defaultWindowID: IconWindowDefaults.windowID(for: provider)
                        ) { prefs in
                            store.updateIconPrefs(prefs, for: provider)
                        }
                    }
                } header: {
                    Text(L10n.t(.menuBarIcon))
                } footer: {
                    Text(L10n.t(.menuBarIconFooter, UsageStore.maxIconProviders))
                }

                Section {
                    Button(L10n.t(.sendTestNotification)) {
                        Task {
                            let ok = await UsageNotifier.shared.sendTest()
                            testNotificationNote = ok
                                ? L10n.t(.testNotificationSent)
                                : L10n.t(.testNotificationOff)
                        }
                    }
                    if let testNotificationNote {
                        Text(testNotificationNote)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.t(.notifications))
                } footer: {
                    Text(L10n.t(.notificationsFooter))
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 560)
        .onAppear {
            accounts = store.claudeAccounts
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            launchAtLoginNote = LaunchAtLogin.lastError
            NSApp.activate(ignoringOtherApps: true)
        }
        .onChange(of: accounts) { _, newValue in
            store.updateClaudeAccounts(newValue)
        }
        .onChange(of: store.settings.language) { _, _ in
            testNotificationNote = nil
            shortcutNote = nil
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { store.settings.language },
            set: { store.updateLanguage($0) }
        )
    }

    private var panelShortcutBinding: Binding<KeyCombo?> {
        Binding(
            get: { store.settings.panelShortcut },
            set: { newValue in
                if store.updatePanelShortcut(newValue) {
                    shortcutNote = nil
                } else {
                    shortcutNote = L10n.t(.shortcutConflict)
                }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                launchAtLoginEnabled = newValue
                if let error = LaunchAtLogin.setEnabled(newValue) {
                    launchAtLoginEnabled = LaunchAtLogin.isEnabled
                    launchAtLoginNote = error
                } else {
                    launchAtLoginEnabled = LaunchAtLogin.isEnabled
                    launchAtLoginNote = nil
                }
            }
        )
    }
}

private struct AccountEditor: View {
    @Binding var account: ClaudeAccount
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                TextField(L10n.t(.label), text: $account.label)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L10n.t(.removeAccount))
            }

            HStack(spacing: 8) {
                TextField(L10n.t(.configDirectory), text: $account.configDir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button(L10n.t(.chooseEllipsis), action: chooseDirectory)
            }
        }
        .padding(.vertical, 4)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t(.choose)
        panel.message = L10n.t(.chooseConfigDirectory, account.label)

        let expanded = (account.configDir as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        account.configDir = shortenHome(url.path)
    }

    private func shortenHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

private struct IconProviderEditor: View {
    let title: String
    let accent: Color
    let prefs: ProviderIconPrefs
    let windowOptions: [(id: String, title: String)]
    let defaultWindowID: String
    var onChange: (ProviderIconPrefs) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28)
                .help(L10n.t(.providerColour))

            Text(title)
                .frame(minWidth: 110, alignment: .leading)

            Picker("Limit", selection: windowBinding) {
                ForEach(windowOptions, id: \.id) { option in
                    Text(option.title).tag(Optional.some(option.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Toggle("Show", isOn: showBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(L10n.t(.showOnIcon))
        }
        .padding(.vertical, 2)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { accent },
            set: { newValue in
                var next = prefs
                next.color = RGBColor(newValue)
                onChange(next)
            }
        )
    }

    private var showBinding: Binding<Bool> {
        Binding(
            get: { prefs.showOnIcon },
            set: { value in
                var next = prefs
                next.showOnIcon = value
                onChange(next)
            }
        )
    }

    private var windowBinding: Binding<String?> {
        Binding(
            get: {
                let id = prefs.windowID ?? defaultWindowID
                if windowOptions.contains(where: { $0.id == id }) { return id }
                return windowOptions.first?.id
            },
            set: { value in
                var next = prefs
                // Persist nil when the user picks the family default so defaults can evolve.
                next.windowID = (value == defaultWindowID) ? nil : value
                onChange(next)
            }
        )
    }
}

private struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording.toggle()
            } label: {
                Text(label)
                    .font(.system(size: 13, design: .rounded))
                    .monospaced()
                    .frame(minWidth: 92)
            }
            .buttonStyle(.bordered)
            .tint(recording ? Color.accentColor : nil)

            if combo != nil && !recording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.t(.clearShortcut))
            }
        }
        .background {
            ShortcutMonitor(isRecording: $recording, combo: $combo)
        }
    }

    private var label: String {
        if recording { return L10n.t(.typeShortcut) }
        return combo?.display ?? L10n.t(.shortcutNone)
    }
}

/// Coordinator owns the event monitor so keystrokes mutate the live bindings, not a View copy.
private struct ShortcutMonitor: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var combo: KeyCombo?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isRecording = $isRecording
        context.coordinator.combo = $combo
        context.coordinator.setRecording(isRecording)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isRecording: $isRecording, combo: $combo)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.setRecording(false)
    }

    @MainActor
    final class Coordinator {
        var isRecording: Binding<Bool>
        var combo: Binding<KeyCombo?>
        private var monitor: Any?
        private var armed = false

        init(isRecording: Binding<Bool>, combo: Binding<KeyCombo?>) {
            self.isRecording = isRecording
            self.combo = combo
        }

        func setRecording(_ recording: Bool) {
            guard recording != armed else { return }
            armed = recording
            if recording {
                PanelHotKey.shared.pause()
                startMonitor()
            } else {
                stopMonitor()
                PanelHotKey.shared.resume()
            }
        }

        private func startMonitor() {
            stopMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event)
                return nil
            }
        }

        private func stopMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch event.keyCode {
            case 53:
                isRecording.wrappedValue = false
            case 51, 117:
                combo.wrappedValue = nil
                isRecording.wrappedValue = false
            default:
                guard KeyCombo.isValid(keyCode: event.keyCode, modifiers: flags) else { return }
                combo.wrappedValue = KeyCombo(keyCode: event.keyCode, modifiers: flags)
                isRecording.wrappedValue = false
            }
        }
    }
}
