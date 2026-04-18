import Foundation
import SwiftUI

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var hosts: [SSHHost] = []
    @Published var sessions: [SSHSession] = []
    @Published var selectedHostId: UUID?
    @Published var currentPage: Int = 0
    @Published var focusedSessionId: UUID? {
        didSet {
            if let focusedSessionId {
                lastFocusedSessionId = focusedSessionId
            }
        }
    }
    @Published private(set) var lastFocusedSessionId: UUID?
    @Published var showAIPanel: Bool = true
    @Published var showAISettingsSheet: Bool = false
    @Published var aiConfig: AIConfig = AIConfig()
    @Published var language: AppLanguage = .traditionalChinese {
        didSet { L10n.setCurrentLanguage(language) }
    }

    private let hostsKey   = "saved_hosts"
    private let aiCfgKey   = "ai_config"

    init() {
        loadHosts()
        loadAIConfig()
        loadLanguage()
    }

    // MARK: - Host management

    func addHost(_ host: SSHHost) {
        hosts.append(host)
        saveHosts()
    }

    func updateHost(_ host: SSHHost) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
            saveHosts()
        }
    }

    func deleteHost(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        saveHosts()
    }

    func duplicateHost(_ host: SSHHost) {
        var copy = host
        copy.id = UUID()
        copy.name = host.name.isEmpty
            ? "\(host.hostname) \(t("複本", "Copy"))"
            : "\(host.name) \(t("複本", "Copy"))"
        hosts.append(copy)
        saveHosts()
    }

    // MARK: - Session management

    func connect(to host: SSHHost) {
        selectedHostId = host.id
        let session = SSHSession(host: host)
        sessions.append(session)
        currentPage = (sessions.count - 1) / 9
        focusedSessionId = session.id
    }

    func closeSession(_ session: SSHSession) {
        sessions.removeAll { $0.id == session.id }
        if focusedSessionId == session.id {
            focusedSessionId = sessions.last?.id
        }
        let maxPage = max(0, (sessions.count - 1) / 9)
        if currentPage > maxPage { currentPage = maxPage }
    }

    func moveSession(_ source: SSHSession, to target: SSHSession) {
        guard source.id != target.id,
              let sourceIndex = sessions.firstIndex(where: { $0.id == source.id }),
              let targetIndex = sessions.firstIndex(where: { $0.id == target.id })
        else { return }

        sessions.swapAt(sourceIndex, targetIndex)
    }

    var focusedSession: SSHSession? {
        sessions.first { $0.id == focusedSessionId }
    }

    var lastFocusedSession: SSHSession? {
        sessions.first { $0.id == lastFocusedSessionId }
    }

    var pageCount: Int {
        max(1, Int(ceil(Double(sessions.count) / 9.0)))
    }

    func sessions(onPage page: Int) -> [SSHSession?] {
        let start = page * 9
        return (0..<9).map { i -> SSHSession? in
            let idx = start + i
            return idx < sessions.count ? sessions[idx] : nil
        }
    }

    // MARK: - AI config

    func saveAIConfig() {
        if let data = try? JSONEncoder().encode(aiConfig) {
            UserDefaults.standard.set(data, forKey: aiCfgKey)
        }
    }

    private func loadAIConfig() {
        guard let data = UserDefaults.standard.data(forKey: aiCfgKey),
              let cfg  = try? JSONDecoder().decode(AIConfig.self, from: data)
        else { return }
        aiConfig = cfg
    }

    func t(_ zh: String, _ en: String) -> String {
        L10n.pair(zh, en, language: language)
    }

    // MARK: - Persistence

    private func saveHosts() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: hostsKey)
        }
    }

    private func loadHosts() {
        guard let data  = UserDefaults.standard.data(forKey: hostsKey),
              let saved = try? JSONDecoder().decode([SSHHost].self, from: data)
        else { return }
        hosts = saved
    }

    private func loadLanguage() {
        language = L10n.currentLanguage()
    }
}
