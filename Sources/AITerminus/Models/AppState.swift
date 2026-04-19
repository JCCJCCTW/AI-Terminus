import Foundation
import SwiftUI
import AppKit

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var hosts: [SSHHost] = []
    @Published var sessions: [SSHSession] = []
    @Published var selectedHostId: UUID?
    @Published var currentPage: Int = 0
    @Published var focusedSessionId: UUID? {
        didSet {
            focusedSessionChangeToken &+= 1
            if let focusedSessionId {
                lastFocusedSessionId = focusedSessionId
            }
        }
    }
    @Published private(set) var focusedSessionChangeToken: UInt64 = 0
    @Published private(set) var lastFocusedSessionId: UUID?
    @Published var showAIPanel: Bool = true
    @Published var showAISettingsSheet: Bool = false
    @Published var isSessionDragModeEnabled: Bool = false {
        didSet {
            if isSessionDragModeEnabled {
                focusedSessionId = nil
                if let window = NSApp.keyWindow {
                    _ = window.makeFirstResponder(window.contentView)
                }
            }
        }
    }
    @Published var showDragModeKeyboardAlert: Bool = false
    @Published var isAIInputActive: Bool = false
    @Published var aiConfig: AIConfig = AIConfig()
    @Published var language: AppLanguage = .traditionalChinese {
        didSet { L10n.setCurrentLanguage(language) }
    }
    private var sessionWindowFrames: [UUID: CGRect] = [:]

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
        activateSession(session)
    }

    func closeSession(_ session: SSHSession) {
        sessions.removeAll { $0.id == session.id }
        if focusedSessionId == session.id {
            if let nextSession = sessions.last {
                activateSession(nextSession)
            } else {
                focusedSessionId = nil
            }
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

    func canMoveSession(_ session: SSHSession, offset: Int) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return false }
        let destinationIndex = index + offset
        return sessions.indices.contains(destinationIndex)
    }

    func moveSession(_ session: SSHSession, offset: Int) {
        guard canMoveSession(session, offset: offset),
              let sourceIndex = sessions.firstIndex(where: { $0.id == session.id })
        else { return }

        let destinationIndex = sourceIndex + offset
        sessions.swapAt(sourceIndex, destinationIndex)
        activateSession(session)
    }

    func activateSession(_ session: SSHSession) {
        focusedSessionId = session.id
        _ = session.focusTerminal()
    }

    func updateSessionWindowFrame(_ frame: CGRect?, for sessionID: UUID) {
        if let frame, !frame.isEmpty {
            sessionWindowFrames[sessionID] = frame
        } else {
            sessionWindowFrames.removeValue(forKey: sessionID)
        }
    }

    func session(atWindowPoint point: CGPoint) -> SSHSession? {
        let containingIDs = sessionWindowFrames.compactMap { sessionID, frame in
            frame.contains(point) ? sessionID : nil
        }

        guard !containingIDs.isEmpty else { return nil }
        return sessions.first(where: { containingIDs.contains($0.id) })
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

    enum SessionFocusDirection {
        case up
        case down
        case left
        case right
    }

    func moveFocusedSession(_ direction: SessionFocusDirection) {
        let visibleSessions = displayedSessionsOnCurrentPage
        guard !visibleSessions.isEmpty else {
            focusedSessionId = nil
            return
        }

        let (rows, cols) = gridDimensions(for: visibleSessions.count)
        let capacity = rows * cols
        let slots: [SSHSession?] = visibleSessions + Array(repeating: nil, count: max(0, capacity - visibleSessions.count))

        let currentSession = focusedSession.flatMap { session in
            visibleSessions.contains(where: { $0.id == session.id }) ? session : nil
        } ?? visibleSessions.first
        guard let currentSession,
              let currentIndex = slots.firstIndex(where: { $0?.id == currentSession.id })
        else {
            focusedSessionId = visibleSessions.first?.id
            return
        }

        let currentRow = currentIndex / cols
        let currentCol = currentIndex % cols
        let delta: (row: Int, col: Int)
        switch direction {
        case .up:
            delta = (-1, 0)
        case .down:
            delta = (1, 0)
        case .left:
            delta = (0, -1)
        case .right:
            delta = (0, 1)
        }

        var nextRow = currentRow + delta.row
        var nextCol = currentCol + delta.col

        while (0..<rows).contains(nextRow), (0..<cols).contains(nextCol) {
            let nextIndex = nextRow * cols + nextCol
            if let targetSession = slots[nextIndex] {
                activateSession(targetSession)
                return
            }
            nextRow += delta.row
            nextCol += delta.col
        }
    }

    private var displayedSessionsOnCurrentPage: [SSHSession] {
        if sessions.count < 5 {
            return sessions
        }
        let start = currentPage * 9
        let end = min(start + 9, sessions.count)
        guard start < end else { return [] }
        return Array(sessions[start..<end])
    }

    private func gridDimensions(for count: Int) -> (rows: Int, cols: Int) {
        switch count {
        case 0, 1: return (1, 1)
        case 2:    return (1, 2)
        case 3:    return (3, 1)
        case 4:    return (2, 2)
        default:   return (3, 3)
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
