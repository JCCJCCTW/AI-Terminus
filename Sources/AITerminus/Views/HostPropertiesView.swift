import SwiftUI

struct HostPropertiesView: View {
    @EnvironmentObject var appState: AppState
    @State private var host: SSHHost
    let isNew: Bool
    let existingGroups: [String]
    let onSave: (SSHHost) -> Void
    let onCancel: () -> Void
    @State private var showGroupPicker = false

    init(host: SSHHost, isNew: Bool, existingGroups: [String] = [],
         onSave: @escaping (SSHHost) -> Void, onCancel: @escaping () -> Void) {
        _host = State(initialValue: host)
        self.isNew = isNew
        self.existingGroups = existingGroups
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var isValid: Bool {
        !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? appState.t("新增主機", "Add Host") : appState.t("Host Properties", "Host Properties"))
                    .font(.title2).fontWeight(.semibold)
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FormSection(title: appState.t("基本資訊", "Basic Info")) {
                        FormRow(label: appState.t("名稱", "Name"), optional: true) {
                            TextField(appState.t("（選填）顯示名稱", "Optional display name"), text: $host.name)
                        }
                        FormRow(label: appState.t("主機名稱 / IP", "Host / IP")) {
                            TextField(appState.t("hostname 或 IP 位址", "hostname or IP address"), text: $host.hostname)
                        }
                        FormRow(label: appState.t("連接埠", "Port")) {
                            TextField("22", value: $host.port, format: .number).frame(width: 80)
                        }
                        FormRow(label: appState.t("使用者名稱", "Username")) {
                            TextField("username", text: $host.username)
                        }
                        FormRow(label: appState.t("群組", "Group"), optional: true) {
                            HStack(spacing: 4) {
                                TextField(appState.t("輸入或選擇群組", "Enter or choose a group"), text: $host.group)
                                if !existingGroups.isEmpty {
                                    Menu {
                                        ForEach(existingGroups, id: \.self) { g in
                                            Button(g) { host.group = g }
                                        }
                                        Divider()
                                        Button(appState.t("清除群組", "Clear Group")) { host.group = "" }
                                    } label: {
                                        Image(systemName: "chevron.down.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .frame(width: 24)
                                }
                            }
                        }
                    }

                    FormSection(title: appState.t("認證方式", "Authentication")) {
                        FormRow(label: appState.t("認證", "Auth")) {
                            Picker("", selection: $host.authMethod) {
                                ForEach(SSHHost.AuthMethod.allCases, id: \.self) {
                                    Text($0.localizedLabel).tag($0)
                                }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                        if host.authMethod == .password {
                            FormRow(label: appState.t("密碼", "Password"), optional: true) {
                                SecureField(appState.t("（可自動回應 SSH 密碼提示）", "Used to auto-answer SSH password prompts"), text: $host.password)
                            }
                        } else if host.authMethod == .privateKey {
                            FormRow(label: appState.t("私鑰路徑", "Private Key Path")) {
                                HStack {
                                    TextField("~/.ssh/id_rsa", text: $host.privateKeyPath)
                                    Button(appState.t("選擇...", "Choose...")) { selectKeyFile() }.controlSize(.small)
                                }
                            }
                        }
                    }

                    FormSection(title: appState.t("備註", "Notes")) {
                        TextEditor(text: $host.notes)
                            .font(.system(size: 13)).frame(minHeight: 70)
                            .padding(4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button(appState.t("取消", "Cancel")) { onCancel() }.keyboardShortcut(.escape)
                Button(isNew ? appState.t("新增", "Add") : appState.t("儲存", "Save")) { onSave(host) }
                    .keyboardShortcut(.return).disabled(!isValid).buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 480, height: 560)
    }

    private func selectKeyFile() {
        let panel = NSOpenPanel()
        panel.title = appState.t("選擇私鑰檔案", "Choose Private Key File")
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { host.privateKeyPath = url.path }
    }
}

// MARK: - Form helpers

struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase).padding(.top, 12)
            content()
        }
        .padding(.bottom, 4)
    }
}

struct FormRow<Content: View>: View {
    let label: String
    var optional: Bool = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 13)).frame(width: 110, alignment: .trailing)
                if optional { Text(localizedAppText("選填", "Optional")).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            .frame(width: 120, alignment: .trailing)
            content().textFieldStyle(.roundedBorder).padding(.leading, 12)
        }
        .padding(.vertical, 3)
    }
}
