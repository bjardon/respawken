import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var accounts: [ClaudeAccount] = []
    @State private var testNotificationNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider()

            Form {
                Section {
                    if accounts.isEmpty {
                        Text("No Claude accounts yet.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach($accounts) { $account in
                        AccountEditor(account: $account) {
                            accounts.removeAll { $0.id == account.id }
                        }
                    }

                    Button("Add Claude Account") {
                        accounts.append(.make())
                    }
                } header: {
                    Text("Claude accounts")
                } footer: {
                    Text("Each account needs a label and the Claude config directory (`CLAUDE_CONFIG_DIR`). Use `~/.claude` for the default login.")
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
                    Text("Menu bar icon")
                } footer: {
                    Text("Panel order is icon order. Up to \(UsageStore.maxIconProviders) shown providers appear on the icon; fewer collapse to a single column.")
                }

                Section {
                    Button("Send Test Notification") {
                        Task {
                            let ok = await UsageNotifier.shared.sendTest()
                            testNotificationNote = ok
                                ? "Sent — check Notification Center."
                                : "Notifications are off for Respawken. Enable them in System Settings → Notifications."
                        }
                    }
                    if let testNotificationNote {
                        Text(testNotificationNote)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Posts a sample alert so you can confirm permission and the app icon.")
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            accounts = store.claudeAccounts
            NSApp.activate(ignoringOtherApps: true)
        }
        .onChange(of: accounts) { _, newValue in
            store.updateClaudeAccounts(newValue)
        }
    }
}

private struct AccountEditor: View {
    @Binding var account: ClaudeAccount
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Label", text: $account.label)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove account")
            }

            HStack(spacing: 8) {
                TextField("Config directory", text: $account.configDir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button("Choose…", action: chooseDirectory)
            }
        }
        .padding(.vertical, 4)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select the Claude config directory for “\(account.label)”."

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
                .help("Provider colour")

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
                .help("Show on menu bar icon")
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
