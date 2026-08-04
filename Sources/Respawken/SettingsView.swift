import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var accounts: [ClaudeAccount] = []

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
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 520, minHeight: 360)
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
