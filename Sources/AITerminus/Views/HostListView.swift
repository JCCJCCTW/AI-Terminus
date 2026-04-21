import SwiftUI
import AppKit

struct HostListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var editingHost: SSHHost?
    @State private var showAddHost = false
    @State private var renamingHost: SSHHost?
    @State private var renameText = ""
    @State private var pendingDuplicateHost: SSHHost?
    @State private var pendingDeleteHost: SSHHost?
    @State private var selectedRowId: String?
    @State private var expandedGroups: Set<String> = ["全部"]
    @State private var isShowingDragModeHelp = false
    @State private var observedSessionStatusToken: UInt64 = 0

    private var localClientHost: SSHHost { .localClient }

    // Filtered host list
    var filteredHosts: [SSHHost] {
        let allHosts = [localClientHost] + appState.hosts
        guard !searchText.isEmpty else { return allHosts }
        return allHosts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.hostname.localizedCaseInsensitiveContains(searchText) ||
            $0.username.localizedCaseInsensitiveContains(searchText) ||
            $0.group.localizedCaseInsensitiveContains(searchText) ||
            ( $0.isLocalClient && appState.t("本機", "local").localizedCaseInsensitiveContains(searchText) )
        }
    }

    private var topLocalClientHost: SSHHost? {
        filteredHosts.first(where: \.isLocalClient)
    }

    // Hosts grouped: always include "全部", then user-defined groups only.
    var groupedHosts: [(key: String, hosts: [SSHHost])] {
        let remoteHosts = filteredHosts.filter { !$0.isLocalClient }.sorted { $0.displayTitle < $1.displayTitle }
        let grouped = Dictionary(grouping: remoteHosts) { host in
            host.group.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let explicitGroups = grouped
            .filter { !$0.key.isEmpty }
            .map { (key: $0.key, hosts: $0.value.sorted { $0.displayTitle < $1.displayTitle }) }
            .sorted { $0.key < $1.key }

        return [(key: "全部", hosts: remoteHosts)] + explicitGroups
    }

    private func connectionState(for host: SSHHost) -> SSHSession.ConnectionStatus? {
        let matchingSessions = appState.sessions.filter { $0.host.id == host.id }
        guard !matchingSessions.isEmpty else { return nil }
        if matchingSessions.contains(where: { $0.status == .connected }) {
            return .connected
        }
        if matchingSessions.contains(where: { $0.status == .connecting }) {
            return .connecting
        }
        if matchingSessions.contains(where: { $0.status == .failed }) {
            return .failed
        }
        return .disconnected
    }

    private func sessionCount(for host: SSHHost) -> Int {
        appState.sessions.count { $0.host.id == host.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 4) {
                Text(appState.t("主機清單", "Hosts"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editingHost = SSHHost()
                    showAddHost = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 12))
                }
                .buttonStyle(.plain).help(appState.t("新增主機", "Add Host"))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(appState.t("搜尋主機", "Search Hosts"), text: $searchText).textFieldStyle(.plain).font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8).padding(.bottom, 6)

            Divider()

            // Host list with groups
            if filteredHosts.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(.quaternary)
                    Text(appState.hosts.isEmpty ? appState.t("尚無主機\n點擊 + 新增", "No hosts yet\nClick + to add one") : appState.t("無符合結果", "No results"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let localClientHost = topLocalClientHost {
                            VStack(spacing: 0) {
                                HostRowButton(
                                    host: localClientHost,
                                    rowId: rowIdentifier(for: localClientHost, in: "__local__"),
                                    selectedRowId: selectedRowId,
                                    connectionState: connectionState(for: localClientHost),
                                    sessionCount: sessionCount(for: localClientHost),
                                    onSelect: {
                                        let rowId = rowIdentifier(for: localClientHost, in: "__local__")
                                        selectedRowId = rowId
                                        appState.selectedHostId = localClientHost.id
                                    },
                                    onConnect: {
                                        selectedRowId = rowIdentifier(for: localClientHost, in: "__local__")
                                        appState.connect(to: localClientHost)
                                    },
                                    onEdit: { editingHost = $0 },
                                    onRename: { host in renameText = host.name.isEmpty ? host.hostname : host.name; renamingHost = host },
                                    onDuplicate: { pendingDuplicateHost = $0 },
                                    onDelete: { pendingDeleteHost = $0 }
                                )
                                .padding(.top, 6)
                                .padding(.bottom, 8)

                                Divider()
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 6)
                            }
                        }

                        ForEach(groupedHosts, id: \.key) { group in
                            GroupSection(
                                name: group.key,
                                hosts: group.hosts,
                                selectedRowId: selectedRowId,
                                isExpanded: expandedGroups.contains(group.key),
                                connectionState: connectionState,
                                onToggle: {
                                    if expandedGroups.contains(group.key) {
                                        expandedGroups.remove(group.key)
                                    } else {
                                        expandedGroups.insert(group.key)
                                    }
                                },
                                onSelect: { host in
                                    let rowId = rowIdentifier(for: host, in: group.key)
                                    selectedRowId = rowId
                                    appState.selectedHostId = host.id
                                },
                                onConnect: { host in
                                    selectedRowId = rowIdentifier(for: host, in: group.key)
                                    appState.connect(to: host)
                                },
                                onEdit: { editingHost = $0 },
                                onRename: { host in renameText = host.name.isEmpty ? host.hostname : host.name; renamingHost = host },
                                onDuplicate: { pendingDuplicateHost = $0 },
                                onDelete: { pendingDeleteHost = $0 }
                            )
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Toggle(isOn: $appState.isSessionDragModeEnabled) {
                        Text(appState.t("開啟拖曳", "Enable Dragging"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()

                    Text(appState.t("開啟拖曳", "Enable Dragging"))
                        .font(.system(size: 12, weight: .medium))

                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Circle())
                        .onHover { isHovering in
                            isShowingDragModeHelp = isHovering
                        }
                        .popover(isPresented: $isShowingDragModeHelp, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(appState.t("拖曳模式說明", "Dragging Mode"))
                                    .font(.system(size: 12, weight: .semibold))
                                Text(appState.t("開啟後停用 Session 一般操作，僅保留拖曳重排。", "Disable normal session interactions and only allow drag-to-reorder."))
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .frame(width: 230, alignment: .leading)
                        }
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            SettingsWindowButton {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text(appState.t("設定", "Settings"))
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SidebarSettingsButtonStyle())
        }
        // Add host sheet
        .sheet(isPresented: $showAddHost) {
            if let host = editingHost {
                HostPropertiesView(host: host, isNew: true, existingGroups: allGroupNames) { saved in
                    appState.addHost(saved)
                    expandedGroups.insert("全部")
                    if !saved.group.isEmpty {
                        expandedGroups.insert(saved.group)
                    }
                    showAddHost = false; editingHost = nil
                } onCancel: {
                    showAddHost = false; editingHost = nil
                }
            }
        }
        // Edit host sheet
        .sheet(item: editingExistingBinding) { host in
            HostPropertiesView(host: host, isNew: false, existingGroups: allGroupNames) { saved in
                appState.updateHost(saved)
                editingHost = nil
            } onCancel: {
                editingHost = nil
            }
        }
        // Rename alert
        .alert(appState.t("重新命名", "Rename"), isPresented: Binding(
            get: { renamingHost != nil },
            set: { if !$0 { renamingHost = nil } }
        )) {
            TextField(appState.t("名稱", "Name"), text: $renameText)
            Button(appState.t("確定", "OK")) {
                if var h = renamingHost { h.name = renameText; appState.updateHost(h); renamingHost = nil }
            }
            Button(appState.t("取消", "Cancel"), role: .cancel) { renamingHost = nil }
        }
        .alert(
            appState.t("確認複製", "Confirm Duplicate"),
            isPresented: Binding(
                get: { pendingDuplicateHost != nil },
                set: { if !$0 { pendingDuplicateHost = nil } }
            ),
            presenting: pendingDuplicateHost
        ) { host in
            Button(appState.t("複製", "Duplicate")) {
                appState.duplicateHost(host)
                pendingDuplicateHost = nil
            }
            Button(appState.t("取消", "Cancel"), role: .cancel) {
                pendingDuplicateHost = nil
            }
        } message: { host in
            Text(appState.t("確定要複製 \(host.displayTitle) 嗎？", "Duplicate \(host.displayTitle)?"))
        }
        .alert(
            appState.t("確認刪除", "Confirm Delete"),
            isPresented: Binding(
                get: { pendingDeleteHost != nil },
                set: { if !$0 { pendingDeleteHost = nil } }
            ),
            presenting: pendingDeleteHost
        ) { host in
            Button(appState.t("刪除", "Delete"), role: .destructive) {
                appState.deleteHost(host)
                pendingDeleteHost = nil
            }
            Button(appState.t("取消", "Cancel"), role: .cancel) {
                pendingDeleteHost = nil
            }
        } message: { host in
            Text(appState.t("確定要刪除 \(host.displayTitle) 嗎？", "Delete \(host.displayTitle)?"))
        }
        .onAppear {
            // Expand all groups initially
            for g in groupedHosts { expandedGroups.insert(g.key) }
        }
        .onChange(of: appState.sessionStatusChangeToken) { token in
            observedSessionStatusToken = token
        }
    }

    private var allGroupNames: [String] {
        Array(Set(appState.hosts.compactMap { $0.group.isEmpty ? nil : $0.group })).sorted()
    }

    private var editingExistingBinding: Binding<SSHHost?> {
        Binding(
            get: {
                guard let h = editingHost else { return nil }
                return appState.hosts.contains(where: { $0.id == h.id }) ? h : nil
            },
            set: { editingHost = $0 }
        )
    }

    private func rowIdentifier(for host: SSHHost, in group: String) -> String {
        "\(group)::\(host.id.uuidString)"
    }
}

struct SidebarSettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 0)
                    .fill(
                        configuration.isPressed
                            ? Color.accentColor.opacity(0.22)
                            : Color(NSColor.controlBackgroundColor).opacity(0.6)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

// MARK: - Group section

struct GroupSection: View {
    @EnvironmentObject var appState: AppState
    let name: String
    let hosts: [SSHHost]
    let selectedRowId: String?
    let isExpanded: Bool
    let connectionState: (SSHHost) -> SSHSession.ConnectionStatus?
    let onToggle: () -> Void
    let onSelect: (SSHHost) -> Void
    let onConnect: (SSHHost) -> Void
    let onEdit: (SSHHost) -> Void
    let onRename: (SSHHost) -> Void
    let onDuplicate: (SSHHost) -> Void
    let onDelete: (SSHHost) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(0.9))
                        .frame(width: 12)
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.9))
                    Text(appState.t(name, name == "全部" ? "All" : name))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(0.95))
                    Spacer()
                    Text("\(hosts.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.05))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            // Host rows
            if isExpanded {
                ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
                    VStack(spacing: 0) {
                        HostRowButton(
                            host: host,
                            rowId: "\(name)::\(host.id.uuidString)",
                            selectedRowId: selectedRowId,
                            connectionState: connectionState(host),
                            sessionCount: sessionCount(for: host),
                            onSelect: { onSelect(host) },
                            onConnect: { onConnect(host) },
                            onEdit: onEdit,
                            onRename: onRename,
                            onDuplicate: onDuplicate,
                            onDelete: onDelete
                        )

                        if index < hosts.count - 1 {
                            Divider()
                                .padding(.leading, 28)
                        }
                    }
                }
            }
        }
    }

    private func sessionCount(for host: SSHHost) -> Int {
        appState.sessions.count { $0.host.id == host.id }
    }
}

// MARK: - Host row

struct HostRowButton: View {
    @EnvironmentObject var appState: AppState
    let host: SSHHost
    let rowId: String
    let selectedRowId: String?
    let connectionState: SSHSession.ConnectionStatus?
    let sessionCount: Int
    let onSelect: () -> Void
    let onConnect: () -> Void
    let onEdit: (SSHHost) -> Void
    let onRename: (SSHHost) -> Void
    let onDuplicate: (SSHHost) -> Void
    let onDelete: (SSHHost) -> Void

    var body: some View {
        Button {
            onSelect()
            if NSApp.currentEvent?.clickCount == 2 {
                onConnect()
            }
        } label: {
            HostRowView(
                host: host,
                isSelected: selectedRowId == rowId,
                connectionState: connectionState,
                sessionCount: sessionCount
            )
            .padding(.leading, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(appState.t("連線", "Connect")) { onConnect() }
            if !host.isLocalClient {
                Divider()
                Button(appState.t("重新命名", "Rename")) { onRename(host) }
                Button(appState.t("複製", "Duplicate")) { onDuplicate(host) }
                Divider()
                Button(appState.t("內容", "Properties")) { onEdit(host) }
                Divider()
                Button(appState.t("刪除", "Delete"), role: .destructive) { onDelete(host) }
            }
        }
    }
}

struct HostRowView: View {
    let host: SSHHost
    let isSelected: Bool
    let connectionState: SSHSession.ConnectionStatus?
    let sessionCount: Int

    private var isHighlightedClient: Bool {
        host.isLocalClient
    }

    private var hasConnectedSession: Bool {
        connectionState == .connected
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if host.isLocalClient {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isHighlightedClient ? Color.accentColor : .secondary)
                    }
                    Text(host.displayTitle)
                        .font(.system(size: 13, weight: rowTitleWeight))
                        .foregroundStyle(rowTitleColor)
                        .lineLimit(1)
                    if isHighlightedClient {
                        Text("CLIENT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    if sessionCount > 1 {
                        Text("\(sessionCount)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(sessionBadgeForegroundColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(sessionBadgeBackgroundColor)
                            .clipShape(Capsule())
                    }
                }
                Text(host.connectionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(connectionLabelColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .overlay(
                    Circle()
                        .stroke(statusColor.opacity(0.25), lineWidth: 4)
                )
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: borderLineWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.trailing, 6)
    }

    private var statusColor: Color {
        switch connectionState {
        case .connected:
            return .green
        case .failed:
            return .red
        case .connecting, .disconnected, .none:
            return .gray.opacity(0.7)
        }
    }

    private var rowTitleWeight: Font.Weight {
        (isHighlightedClient || hasConnectedSession) ? .semibold : .medium
    }

    private var rowTitleColor: Color {
        if isHighlightedClient {
            return .accentColor
        }
        if hasConnectedSession {
            return .green
        }
        return .primary
    }

    private var connectionLabelColor: Color {
        if isHighlightedClient {
            return .accentColor.opacity(0.9)
        }
        if hasConnectedSession {
            return .green.opacity(0.9)
        }
        return .secondary
    }

    private var sessionBadgeBackgroundColor: Color {
        if isHighlightedClient {
            return Color.accentColor.opacity(0.14)
        }
        if hasConnectedSession {
            return Color.green.opacity(0.14)
        }
        return Color.black.opacity(0.06)
    }

    private var sessionBadgeForegroundColor: Color {
        if isHighlightedClient {
            return .accentColor
        }
        if hasConnectedSession {
            return .green
        }
        return .secondary
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }
        if isHighlightedClient {
            return Color.accentColor.opacity(0.08)
        }
        if hasConnectedSession {
            return Color.green.opacity(0.08)
        }
        return Color.clear
    }

    private var borderColor: Color {
        if isHighlightedClient {
            return Color.accentColor.opacity(0.35)
        }
        if hasConnectedSession {
            return Color.green.opacity(0.45)
        }
        return Color.clear
    }

    private var borderLineWidth: CGFloat {
        (isHighlightedClient || hasConnectedSession) ? 1 : 0
    }
}
