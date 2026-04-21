import Foundation
import SwiftUI
import SwiftTerm

@MainActor
class SSHSession: ObservableObject, Identifiable {
    enum ControlKey: String, CaseIterable {
        case ctrlC = "ctrl+c"
        case ctrlD = "ctrl+d"
        case ctrlL = "ctrl+l"
        case ctrlR = "ctrl+r"
        case tab
        case escape
        case enter
        case up
        case down
        case left
        case right

        var payload: String {
            switch self {
            case .ctrlC: return "\u{03}"
            case .ctrlD: return "\u{04}"
            case .ctrlL: return "\u{0C}"
            case .ctrlR: return "\u{12}"
            case .tab: return "\t"
            case .escape: return "\u{1B}"
            case .enter: return "\r"
            case .up: return "\u{1B}[A"
            case .down: return "\u{1B}[B"
            case .right: return "\u{1B}[C"
            case .left: return "\u{1B}[D"
            }
        }

        var transcriptLabel: String {
            rawValue.uppercased()
        }
    }

    enum AIControlAction {
        case command(String)
        case type(String)
        case paste(String, submit: Bool)
        case keys([ControlKey])

        var summary: String {
            switch self {
            case .command(let command):
                return "command: \(command)"
            case .type(let text):
                return "type: \(text)"
            case .paste(let text, let submit):
                let suffix = submit ? " + enter" : ""
                return "paste: \(text)\(suffix)"
            case .keys(let keys):
                return "keys: \(keys.map(\.rawValue).joined(separator: ", "))"
            }
        }
    }

    enum CommandSource {
        case user
        case ai

        var transcriptLabel: String {
            switch self {
            case .user: return "$"
            case .ai: return "[AI]$"
            }
        }
    }

    let id: UUID = UUID()
    let host: SSHHost

    @Published var status: ConnectionStatus = .connecting {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?()
        }
    }
    @Published var title: String
    @Published private(set) var transcript: String = ""
    @Published private(set) var transcriptRevision: Int = 0

    // Strong references keep the terminal host and SSH process alive across page switches.
    var terminalContainer: TerminalViewContainer?
    var terminalView: LocalProcessTerminalView?
    var onStatusChange: (() -> Void)?
    private var didAutoSubmitStoredPassword = false
    private var promptDetectionBuffer = ""
    private let transcriptLimit = 16_000
    private let promptDetectionLimit = 512

    enum ConnectionStatus {
        case connecting, connected, disconnected, failed

        var label: String {
            switch self {
            case .connecting:   return localizedAppText("連線中", "Connecting")
            case .connected:    return localizedAppText("已連線", "Connected")
            case .disconnected: return localizedAppText("已斷線", "Disconnected")
            case .failed:       return localizedAppText("失敗", "Failed")
            }
        }

        var color: SwiftUI.Color {
            switch self {
            case .connecting:   return .yellow
            case .connected:    return .green
            case .disconnected: return .gray
            case .failed:       return .red
            }
        }
    }

    init(host: SSHHost) {
        self.host = host
        self.title = host.displayTitle
    }

    func sendCommand(_ command: String, source: CommandSource = .user) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        appendTranscript("\(source.transcriptLabel) \(trimmed)\n")
        return sendText(trimmed + "\n")
    }

    func pasteText(_ text: String, source: CommandSource = .user, submit: Bool = false) -> Bool {
        guard !text.isEmpty else { return false }
        appendTranscript("\(source.transcriptLabel) \(text)\(submit ? "⏎" : "")\n")
        return sendText(text + (submit ? "\r" : ""))
    }

    func sendControl(_ key: ControlKey, source: CommandSource = .user) -> Bool {
        appendTranscript("\(source.transcriptLabel) <\(key.transcriptLabel)>\n")
        return sendText(key.payload)
    }

    func sendControls(_ keys: [ControlKey], source: CommandSource = .user) -> Bool {
        guard !keys.isEmpty else { return false }
        var didSend = false
        for key in keys {
            didSend = sendControl(key, source: source) || didSend
        }
        return didSend
    }

    func performAIControlAction(_ action: AIControlAction) -> Bool {
        switch action {
        case .command(let command):
            return sendCommand(command, source: .ai)
        case .type(let text):
            return pasteText(text, source: .ai, submit: false)
        case .paste(let text, let submit):
            return pasteText(text, source: .ai, submit: submit)
        case .keys(let keys):
            return sendControls(keys, source: .ai)
        }
    }

    func sendText(_ text: String) -> Bool {
        guard let tv = terminalView else { return false }
        if let data = text.data(using: .utf8) {
            let bytes = [UInt8](data)
            tv.send(data: bytes[...])
            return true
        }
        return false
    }

    @discardableResult
    func focusTerminal() -> Bool {
        terminalContainer?.focusTerminal() ?? false
    }

    func terminate() {
        terminalView?.terminate()
        terminalContainer?.terminalView?.terminate()
        terminalView = nil
        terminalContainer = nil
    }

    func recordTerminalOutput(_ text: String) {
        let cleaned = sanitizeTerminalText(text)
        guard !cleaned.isEmpty else { return }

        promptDetectionBuffer += cleaned.lowercased()
        if promptDetectionBuffer.count > promptDetectionLimit {
            promptDetectionBuffer = String(promptDetectionBuffer.suffix(promptDetectionLimit))
        }

        updateConnectionStatusIfNeeded(for: cleaned)
        appendTranscript(cleaned)
        autoSubmitStoredPasswordIfNeeded()
    }

    func recentTranscript(limit: Int = 6_000) -> String {
        if transcript.count <= limit { return transcript }
        return String(transcript.suffix(limit))
    }

    func transcriptDelta(since characterCount: Int) -> String {
        guard characterCount >= 0, characterCount < transcript.count else {
            return recentTranscript(limit: 3_000)
        }
        let start = transcript.index(transcript.startIndex, offsetBy: characterCount)
        return String(transcript[start...])
    }

    private func autoSubmitStoredPasswordIfNeeded() {
        guard host.authMethod == .password else { return }
        guard !host.password.isEmpty, !didAutoSubmitStoredPassword else { return }

        let hasPasswordPrompt =
            promptDetectionBuffer.contains("password:") ||
            promptDetectionBuffer.contains("password for")

        guard hasPasswordPrompt else { return }
        didAutoSubmitStoredPassword = true
        _ = sendText(host.password + "\n")
    }

    private func updateConnectionStatusIfNeeded(for text: String) {
        guard status == .connecting else { return }

        let normalized = text.lowercased()
        if containsConnectionFailure(in: normalized) {
            status = .failed
            return
        }

        if host.isLocalClient || containsConnectedPrompt(in: text) || normalized.contains("last login") {
            status = .connected
        }
    }

    private func containsConnectionFailure(in text: String) -> Bool {
        let patterns = [
            "permission denied",
            "connection refused",
            "operation timed out",
            "connection timed out",
            "no route to host",
            "could not resolve hostname",
            "connection closed by remote host",
            "connection reset by peer",
            "host key verification failed"
        ]
        return patterns.contains { text.contains($0) }
    }

    private func containsConnectedPrompt(in text: String) -> Bool {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(3)

        return lines.contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return false }
            return line.hasSuffix("$") || line.hasSuffix("#") || line.hasSuffix("%") || line.hasSuffix(">")
        }
    }

    private func appendTranscript(_ text: String) {
        transcript += text
        if transcript.count > transcriptLimit {
            transcript = String(transcript.suffix(transcriptLimit))
        }
        transcriptRevision &+= 1
    }

    private func sanitizeTerminalText(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\u{001B}\][^\u{0007}]*\u{0007}"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\u{08}", with: "")
        return cleaned
    }
}
