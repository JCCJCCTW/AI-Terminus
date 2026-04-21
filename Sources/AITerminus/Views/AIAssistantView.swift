import SwiftUI
import AppKit

struct AIAssistantView: View {
    private static let confirmedCommandMarker = "\u{200B}"
    private static let subsystemFailureDomain = "AIAssistantSubsystem"
    private static let streamFlushInterval: Duration = .milliseconds(80)
    private static let streamFlushChunkThreshold = 384
    private static let messageHistoryLimit = 40

    struct SessionMentionOption: Identifiable, Equatable {
        let id: UUID
        let token: String
        let title: String
    }

    struct InputCompletionOption: Identifiable, Equatable {
        enum Kind: Equatable {
            case session(UUID)
            case slashCommand(SlashCommand)
        }

        let id: String
        let token: String
        let title: String
        let kind: Kind
    }

    enum SlashCommand: String, CaseIterable, Equatable {
        case `do` = "do"

        var token: String { "/\(rawValue)" }

        var title: String {
            switch self {
            case .do:
                return localizedAppText("執行控制操作", "Execute session control")
            }
        }
    }

    struct ParsedControlAction {
        let sessionID: UUID?
        let sessionToken: String?
        let action: SSHSession.AIControlAction
    }

    struct SessionContextSnapshot {
        let id: UUID
        let token: String
        let displayTitle: String
        let connectionLabel: String
        let authMethodLabel: String
        let statusLabel: String
        let transcript: String
    }

    private struct PreparedSendRequest {
        let requestID: UUID
        let assistantID: UUID
        let sendMessages: [ChatMessage]
        let config: AIConfig
        let mentionedSessions: [String: UUID]
        let allowsSessionAutomation: Bool
        let systemPrompt: String
    }

    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedSessionId: UUID?
    @State private var lockControlSession = false
    @State private var completionQuery: String?
    @State private var completionTrigger: Character?
    @State private var selectedCompletionIndex = 0
    @State private var currentCompletionRange: NSRange?
    @State private var requestedSelectionLocation: Int?
    @State private var currentTask: Task<Void, Never>?
    @State private var activeRequestID = UUID()
    let onSubsystemFailure: ((String) -> Void)?

    init(onSubsystemFailure: ((String) -> Void)? = nil) {
        self.onSubsystemFailure = onSubsystemFailure
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(appState.t("AI 助理", "AI Assistant")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(providerBadge)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor).clipShape(Capsule())
                Button { messages = []; errorMessage = nil } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help(appState.t("清除對話", "Clear Conversation"))
                .disabled(isLoading)
                if isLoading {
                    Button {
                        activeRequestID = UUID()
                        currentTask?.cancel()
                        currentTask = nil
                        isLoading = false
                        errorMessage = appState.t("已中斷本次對話。", "The current conversation was interrupted.")
                    } label: {
                        Image(systemName: "stop.circle").font(.system(size: 13)).foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help(appState.t("中斷思考", "Stop Response"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Session selector
            SessionSelectorView(
                sessions: appState.sessions,
                selectedSessionId: $selectedSessionId,
                lockControlSession: $lockControlSession,
                targetSession: targetSession
            )

            Divider()

            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            emptyStateView
                        }
                        ForEach(stableMessages) { msg in
                            stableMessageBubble(for: msg)
                        }
                        if let streamingMessage {
                            streamingMessageBubble(for: streamingMessage)
                        }
                        if isLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(appState.t("思考中...", "Thinking...")).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).id("loading")
                        }
                        if let err = errorMessage {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(.red)
                                .padding(.horizontal, 12)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: isLoading) { loading in
                    if loading { withAnimation { proxy.scrollTo("loading", anchor: .bottom) } }
                }
            }

            Divider()

            // Input
            VStack(spacing: 6) {
                if !appState.aiConfig.isReady {
                    Button { openWindow(id: "app-settings") } label: {
                        Text(appState.aiConfig.notReadyMessage)
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 8) {
                        SessionMentionTextEditor(
                            text: $inputText,
                            sessions: sessionMentionOptions,
                            slashCommandToken: confirmedDoToken,
                            completionQuery: $completionQuery,
                            completionTrigger: $completionTrigger,
                            completionRange: $currentCompletionRange,
                            requestedSelectionLocation: $requestedSelectionLocation,
                            onMoveSelectionUp: { moveCompletionSelection(up: true) },
                            onMoveSelectionDown: { moveCompletionSelection(up: false) }
                        ) {
                            if confirmCurrentCompletionSelection() { return }
                            guard canSend else { return }
                            startSendingMessage()
                        } onConfirmMention: {
                            confirmCurrentCompletionSelection()
                        }
                        .frame(minHeight: 42, maxHeight: 110)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(NSColor.textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                        )

                        Button { startSendingMessage() } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(canSend ? Color.accentColor : Color.gray.opacity(0.4))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                    }

                    if !filteredCompletionOptions.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filteredCompletionOptions.enumerated()), id: \.element.id) { index, option in
                                Button {
                                    applyCompletion(option)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(option.token)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        Text(option.title)
                                            .font(.system(size: 12))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == selectedCompletionIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(Color(NSColor.windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                    }

                    HStack(spacing: 6) {
                        Image(systemName: allowsSessionAutomationPreview ? "bolt.fill" : "text.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(allowsSessionAutomationPreview ? Color.orange : Color.secondary)
                        Text(inputModeStatusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(10).background(Color(NSColor.windowBackgroundColor))
        }
        .onChange(of: appState.sessions.count) { count in
            guard count > 0 else {
                selectedSessionId = nil
                return
            }
            if let selectedSessionId,
               !appState.sessions.contains(where: { $0.id == selectedSessionId }) {
                self.selectedSessionId = nil
            }
        }
        .onAppear {
            selectedSessionId = appState.lastFocusedSessionId
        }
        .onChange(of: appState.lastFocusedSessionId) { lastFocusedSessionId in
            if !lockControlSession && !isLoading {
                selectedSessionId = lastFocusedSessionId
            }
        }
        .onDisappear {
            cancelCurrentRequest()
        }
    }

    // MARK: - Computed

    private var providerBadge: String {
        switch appState.aiConfig.provider {
        case .anthropic: return "Claude"
        case .openai:    return "GPT"
        case .gemini:    return "Gemini"
        case .ollama:    return "Ollama"
        }
    }

    private var emptyStateText: String {
        appState.t(
            "詢問 AI 助理\nSSH 指令或系統問題",
            "Ask the AI assistant\nabout SSH commands or systems"
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.purple.opacity(0.4))
            Text(emptyStateText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    @ViewBuilder
    private func stableMessageBubble(for message: ChatMessage) -> some View {
        MessageBubble(message: message, isTextSelectionEnabled: true) { content in
            sendToTerminal(content)
        }
        .id(message.id)
    }

    @ViewBuilder
    private func streamingMessageBubble(for message: ChatMessage) -> some View {
        MessageBubble(message: message, isTextSelectionEnabled: false) { content in
            sendToTerminal(content)
        }
        .id(message.id)
    }

    var targetSession: SSHSession? {
        guard let selectedSessionId else { return nil }
        return appState.sessions.first { $0.id == selectedSessionId }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isLoading && appState.aiConfig.isReady
    }

    private var activeStreamingMessageID: UUID? {
        guard isLoading, let lastMessage = messages.last, lastMessage.role == "assistant" else {
            return nil
        }
        return lastMessage.id
    }

    private var stableMessages: [ChatMessage] {
        guard let activeStreamingMessageID else { return messages }
        return messages.filter { $0.id != activeStreamingMessageID }
    }

    private var streamingMessage: ChatMessage? {
        guard let activeStreamingMessageID else { return nil }
        return messages.first(where: { $0.id == activeStreamingMessageID })
    }

    private var sessionMentionOptions: [SessionMentionOption] {
        appState.sessions.enumerated().map { index, session in
            SessionMentionOption(
                id: session.id,
                token: "@S\(index + 1)",
                title: session.host.displayTitle
            )
        }
    }

    private var confirmedDoToken: String {
        "/do\(Self.confirmedCommandMarker)"
    }

    private var slashCommands: [SlashCommand] {
        [.do]
    }

    private var completionOptions: [InputCompletionOption] {
        let sessionOptions = sessionMentionOptions.map { option in
            InputCompletionOption(
                id: option.id.uuidString,
                token: option.token,
                title: option.title,
                kind: .session(option.id)
            )
        }

        let commandOptions = slashCommands.map { command in
            InputCompletionOption(
                id: "command-\(command.rawValue)",
                token: command.token,
                title: command.title,
                kind: .slashCommand(command)
            )
        }

        return sessionOptions + commandOptions
    }

    private var allowsSessionAutomationPreview: Bool {
        containsAutomationDirective(in: inputText)
    }

    private var mentionedSessionsPreview: [SSHSession] {
        resolvedSessions(from: sanitizedUserInput(inputText))
    }

    private var inputModeStatusText: String {
        if allowsSessionAutomationPreview {
            if lockControlSession, let targetSession {
                let label = sessionReferenceLabel(for: targetSession)
                return appState.t("控制模式已啟用，已鎖定操作 \(label)", "Control mode enabled, locked to \(label)")
            }
            if !mentionedSessionsPreview.isEmpty {
                let labels = mentionedSessionsPreview.map(sessionReferenceLabel).joined(separator: ", ")
                return appState.t("控制模式已啟用，將優先操作 \(labels)", "Control mode enabled, will target \(labels)")
            }
            if let targetSession {
                let label = sessionReferenceLabel(for: targetSession)
                return appState.t("控制模式已啟用，將操作 \(label)", "Control mode enabled, will operate \(label)")
            }
            return appState.t("控制模式已啟用，將操作目前選定的 Session", "Control mode enabled for the selected session")
        }

        if !mentionedSessionsPreview.isEmpty {
            let labels = mentionedSessionsPreview.map(sessionReferenceLabel).joined(separator: ", ")
            return appState.t("分析模式：將優先分析 \(labels) 的狀態；只有高亮 /do 才會真的操作 Session", "Analyze mode: Will prioritize \(labels); session control only activates when /do is confirmed")
        }

        return appState.t("分析模式：只有從 / 指令選單確認高亮 /do 才會真的操作 Session", "Analyze mode: Session control only activates when /do is confirmed from the slash command menu")
    }

    private var filteredCompletionOptions: [InputCompletionOption] {
        guard let completionQuery, let completionTrigger else { return [] }
        let normalized = completionQuery.lowercased()
        let options: [InputCompletionOption]

        switch completionTrigger {
        case "@":
            options = completionOptions.filter {
                if case .session = $0.kind {
                    return normalized.isEmpty ||
                        $0.token.lowercased().contains(normalized) ||
                        $0.title.lowercased().contains(normalized)
                }
                return false
            }
        case "/":
            options = completionOptions.filter {
                if case .slashCommand(let command) = $0.kind {
                    return normalized.isEmpty || command.rawValue.contains(normalized)
                }
                return false
            }
        default:
            options = []
        }

        let boundedIndex = min(selectedCompletionIndex, max(0, options.count - 1))
        if boundedIndex != selectedCompletionIndex {
            DispatchQueue.main.async { selectedCompletionIndex = boundedIndex }
        }
        return options
    }

    // MARK: - Actions

    private func startSendingMessage() {
        let previousTask = currentTask
        let requestID = UUID()
        activeRequestID = requestID
        currentTask = Task { [previousTask] in
            previousTask?.cancel()
            _ = await previousTask?.value
            await sendMessage(requestID: requestID)
        }
    }

    private func sendMessage(requestID: UUID) async {
        guard let preparedRequest = await MainActor.run(body: { prepareSendRequest(requestID: requestID) }) else { return }

        do {
            let assistantText = try await streamAssistantResponse(for: preparedRequest)
            guard await MainActor.run(body: { activeRequestID == requestID }) else { throw CancellationError() }
            if preparedRequest.allowsSessionAutomation {
                await handleAssistantAutomation(
                    for: assistantText,
                    messageID: preparedRequest.assistantID,
                    mentionedSessions: preparedRequest.mentionedSessions
                )
            }
        } catch is CancellationError {
            // Keep any partial assistant text and stop silently.
        } catch {
            await MainActor.run {
                guard activeRequestID == requestID else { return }
                if isIsolatableSubsystemFailure(error) {
                    isolateSubsystem(with: error)
                } else {
                    removeMessage(id: preparedRequest.assistantID)
                    errorMessage = error.localizedDescription
                }
            }
        }

        await MainActor.run {
            if activeRequestID == requestID {
                isLoading = false
                currentTask = nil
            }
        }
    }

    @MainActor
    private func prepareSendRequest(requestID: UUID) -> PreparedSendRequest? {
        let rawText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = sanitizedUserInput(rawText)
        guard !text.isEmpty, appState.aiConfig.isReady else { return nil }
        inputText = ""
        completionQuery = nil
        completionTrigger = nil
        currentCompletionRange = nil
        errorMessage = nil

        messages.append(ChatMessage(role: "user", content: text))
        messages.append(ChatMessage(role: "assistant", content: ""))
        trimMessageHistoryIfNeeded()
        guard let assistantID = messages.last?.id else {
            isLoading = false
            return nil
        }
        isLoading = true

        let sendMessages = messages
            .dropLast()
            .filter { $0.role == "user" || $0.role == "assistant" }
        let mentionedSessions = mentionedSessionMap(in: text)
        let allowsSessionAutomation = containsAutomationDirective(in: rawText)
        let selectedSnapshot = makeSessionSnapshot(for: selectedSessionId)
        let contextSnapshots = transcriptContextSnapshots(
            mentionedSessions: mentionedSessions,
            fallbackSessionID: selectedSessionId
        )
        let systemPrompt = buildSystemPrompt(
            selectedSession: selectedSnapshot,
            contextSessions: contextSnapshots,
            mentionedSessions: mentionedSessions,
            allowsSessionAutomation: allowsSessionAutomation
        )

        return PreparedSendRequest(
            requestID: requestID,
            assistantID: assistantID,
            sendMessages: sendMessages,
            config: appState.aiConfig,
            mentionedSessions: mentionedSessions,
            allowsSessionAutomation: allowsSessionAutomation,
            systemPrompt: systemPrompt
        )
    }

    private func streamAssistantResponse(for preparedRequest: PreparedSendRequest) async throws -> String {
        let stream = AIService.streamChat(
            messages: preparedRequest.sendMessages,
            config: preparedRequest.config,
            systemPrompt: preparedRequest.systemPrompt
        )

        var bufferedChunk = ""
        var fullResponse = ""
        let clock = ContinuousClock()
        var lastFlushAt = clock.now

        for try await chunk in stream {
            guard await MainActor.run(body: { activeRequestID == preparedRequest.requestID }) else { throw CancellationError() }

            bufferedChunk += chunk
            fullResponse += chunk

            let shouldFlush = bufferedChunk.count >= Self.streamFlushChunkThreshold ||
                lastFlushAt.duration(to: clock.now) >= Self.streamFlushInterval

            if shouldFlush {
                let chunkToFlush = bufferedChunk
                bufferedChunk.removeAll(keepingCapacity: true)
                lastFlushAt = clock.now
                await MainActor.run {
                    appendAssistantChunk(chunkToFlush, to: preparedRequest.assistantID)
                }
            }
        }

        if !bufferedChunk.isEmpty {
            await MainActor.run {
                appendAssistantChunk(bufferedChunk, to: preparedRequest.assistantID)
            }
        }

        return fullResponse
    }

    private func buildSystemPrompt(
        selectedSession: SessionContextSnapshot?,
        contextSessions: [SessionContextSnapshot],
        mentionedSessions: [String: UUID],
        allowsSessionAutomation: Bool
    ) -> String {
        var prompt = appState.language == .english
            ? """
            You are an SSH and Linux systems expert helping the user operate remote servers.
            When the user asks for commands, provide concrete commands and briefly explain their purpose.
            If a command is risky, warn the user clearly.
            Reply in English.
            """
            : """
            你是一位 SSH 與 Linux 系統管理專家，協助使用者操作遠端伺服器。
            當使用者詢問指令時，請提供具體的命令，並簡單說明用途。
            如果要執行的命令有風險，請提醒使用者注意。
            回答請使用繁體中文。
            """
        if let session = selectedSession {
            prompt += "\n\n目前控制的 Session：\(session.token) — \(session.displayTitle)（\(session.connectionLabel)）"
            let sessionMap = appState.sessions.enumerated().map { index, session in
                "S\(index + 1)=Session \(index + 1)=\(session.host.displayTitle)"
            }.joined(separator: "，")
            if !sessionMap.isEmpty {
                prompt += "\n所有可控制的 Session 對照：\(sessionMap)"
                prompt += "\n當使用者說「對 S1 下 top」或「在 s2 執行 Ctrl+C」時，S1 / S2 就是上面對照表中的 Session 編號。"
            }
            prompt += "\n主機認證方式：\(session.authMethodLabel)"
            prompt += "\n連線狀態：\(session.statusLabel)"
            if !mentionedSessions.isEmpty {
                prompt += "\n當使用者有標記 Session 時，分析與回答請優先根據被標記的 Session 狀態，不要只看目前控制中的 Session。"
                prompt += "\n若使用者標記了 Session 但沒有 `/do`，你的任務是分析那些被標記 Session 的 transcript 與狀態，而不是執行命令。"
            }
            if !contextSessions.isEmpty {
                prompt += "\n\n以下是本輪應優先參考的 Session 終端機輸入與輸出："
                for contextSession in contextSessions {
                    guard !contextSession.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    prompt += "\n\n[\(contextSession.token) — \(contextSession.displayTitle)]"
                    prompt += "\n```text\n\(contextSession.transcript)\n```"
                }
            }
            prompt += "\n\n目前偏好的 Session 控制模式：\(appState.aiConfig.sessionControlMode.label)。"
            prompt += "\n\(appState.aiConfig.sessionControlMode.guidance)"
            if !mentionedSessions.isEmpty {
                let mentionSummary = mentionedSessions.keys.sorted().joined(separator: "、")
                prompt += "\n使用者在本輪訊息中標記了以下 Session：\(mentionSummary)。"
            }
            if allowsSessionAutomation {
                prompt += "\n\n本輪訊息包含明確操作指令 `/do`。只有在使用者訊息包含 `/do` 時，你才可以真的操作 Session。"
                prompt += "\n如果你要實際操作 Session，請不要輸出任何說明文字、不要輸出額外符號，只輸出唯一一個 ```session JSON 區塊。"
                prompt += "\nJSON 格式只允許以下四種："
                prompt += "\n1. {\"type\":\"command\",\"content\":\"ls -la\"}"
                prompt += "\n2. {\"type\":\"type\",\"content\":\"q\"}"
                prompt += "\n3. {\"type\":\"paste\",\"content\":\"python manage.py shell\",\"submit\":true}"
                prompt += "\n4. {\"type\":\"keys\",\"keys\":[\"ctrl+c\",\"up\",\"enter\"]}"
                prompt += "\n允許的 keys: ctrl+c, ctrl+d, ctrl+l, ctrl+r, tab, escape, enter, up, down, left, right。"
                prompt += "\n對於 top、less、vim 這類互動式程式：單鍵操作如 q 請使用 type；中斷程式優先使用 keys 搭配 ctrl+c。"
                prompt += "\n對於要執行一般 shell 命令如 top、ls、free -h，請使用 command，不要使用 type。"
                prompt += "\n若訊息中有多個被標記的 Session，請在 JSON 中額外加入 \"session\":\"S1\" 這種欄位，明確指定目標。"
                prompt += "\n若訊息中沒有標記 Session，請使用目前下拉或鎖定中的 Session 作為目標。"
                prompt += "\n不要輸出 ```json 區塊、不要輸出 shell 以外的 fenced block 當作控制指令，也不要把說明文字放進 JSON content。"
                prompt += "\n你不能宣稱已經執行某個命令，除非該操作真的會由這個程式送進指定 Session。"
            } else {
                prompt += "\n\n本輪訊息沒有 `/do`。這代表你只能分析、解釋、提供建議、解讀 transcript。"
                prompt += "\n絕對不要輸出任何 session 控制 JSON，也不要假設自己已經執行了任何命令。"
                prompt += "\n如果使用者想真正操作 Session，必須明確輸入 `/do`，例如：`@S2 /do 查看現在記憶體用量`。"
                prompt += "\n如果使用者問『@S1 現在怎麼了』，你必須把 @S1 視為分析目標，直接分析 S1 的 transcript 與狀態。"
            }
        }
        return prompt
    }

    private func sendToTerminal(_ text: String) {
        guard let session = targetSession else { return }
        guard let parsedAction = extractControlAction(from: text) else { return }
        if !session.performAIControlAction(parsedAction.action) {
            errorMessage = appState.t("目前選定的 Session 尚未就緒，無法送出輸入。", "The selected session is not ready and cannot receive input.")
        }
    }

    private func extractCommand(from text: String) -> String? {
        extractCodeBlock(from: text, languages: ["", "sh", "bash", "zsh", "shell"])
    }

    private func extractControlAction(from text: String) -> ParsedControlAction? {
        if let action = extractSessionJSONAction(from: text) {
            return action
        }
        if let command = extractCommand(from: text) {
            return ParsedControlAction(sessionID: nil, sessionToken: nil, action: .command(command))
        }
        return nil
    }

    private func extractSessionJSONAction(from text: String) -> ParsedControlAction? {
        let jsonString =
            extractCodeBlock(from: text, languages: ["session", "json", "json session"]) ??
            extractInlineJSONObject(from: text)
        guard let jsonString else { return nil }

        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        let sessionToken = (object["session"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        switch type {
        case "command":
            guard let content = object["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return ParsedControlAction(sessionID: nil, sessionToken: sessionToken, action: .command(content))
        case "type":
            guard let content = object["content"] as? String,
                  !content.isEmpty
            else { return nil }
            let submit = object["submit"] as? Bool ?? false
            let action: SSHSession.AIControlAction = submit ? .paste(content, submit: true) : .type(content)
            return ParsedControlAction(sessionID: nil, sessionToken: sessionToken, action: action)
        case "paste":
            guard let content = object["content"] as? String,
                  !content.isEmpty
            else { return nil }
            let submit = object["submit"] as? Bool ?? false
            return ParsedControlAction(sessionID: nil, sessionToken: sessionToken, action: .paste(content, submit: submit))
        case "keys":
            guard let keyNames = object["keys"] as? [String] else { return nil }
            let keys = keyNames.compactMap { SSHSession.ControlKey(rawValue: $0.lowercased()) }
            guard !keys.isEmpty else { return nil }
            return ParsedControlAction(sessionID: nil, sessionToken: sessionToken, action: .keys(keys))
        default:
            return nil
        }
    }

    private func extractCodeBlock(from text: String, languages: Set<String>) -> String? {
        let lines = text.components(separatedBy: "\n")
        var inBlock = false
        var blockLines: [String] = []

        for line in lines {
            if line.hasPrefix("```") {
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if inBlock {
                    break
                }
                if languages.contains(language) {
                    inBlock = true
                    blockLines.removeAll(keepingCapacity: true)
                }
            } else if inBlock {
                blockLines.append(line)
            }
        }

        let content = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    private func extractInlineJSONObject(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSessionControlJSONObject(trimmed) {
            return trimmed
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}")
        else { return nil }

        let candidate = String(trimmed[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return isSessionControlJSONObject(candidate) ? candidate : nil
    }

    private func isSessionControlJSONObject(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return false }

        return ["command", "type", "paste", "keys"].contains(type)
    }

    @MainActor
    private func handleAssistantAutomation(
        for text: String,
        messageID: UUID,
        mentionedSessions: [String: UUID]
    ) async {
        guard let parsedAction = extractControlAction(from: text) else { return }
        guard let session = resolveTargetSession(for: parsedAction, mentionedSessions: mentionedSessions) else { return }

        guard session.performAIControlAction(parsedAction.action) else {
            errorMessage = appState.t("目前選定的 Session 尚未就緒，AI 無法送出輸入。", "The selected session is not ready, so AI could not send input.")
            return
        }
        replaceMessageContent(id: messageID, with: displaySummary(for: parsedAction.action, session: session))
    }

    @MainActor
    private func appendAssistantChunk(_ chunk: String, to messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].content += chunk
    }

    @MainActor
    private func messageContent(for messageID: UUID) -> String? {
        messages.first(where: { $0.id == messageID })?.content
    }

    @MainActor
    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    @MainActor
    private func replaceMessageContent(id: UUID, with content: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content = content
    }

    @MainActor
    private func trimMessageHistoryIfNeeded() {
        let overflow = messages.count - Self.messageHistoryLimit
        guard overflow > 0 else { return }
        messages.removeFirst(overflow)
    }

    private func displaySummary(for action: SSHSession.AIControlAction, session: SSHSession) -> String {
        let sessionLabel: String
        if let index = appState.sessions.firstIndex(where: { $0.id == session.id }) {
            sessionLabel = "S\(index + 1)"
        } else {
            sessionLabel = session.host.displayTitle
        }

        switch action {
        case .command(let command):
            return appState.t("已對 \(sessionLabel) 執行命令：`\(command)`", "Ran command on \(sessionLabel): `\(command)`")
        case .type(let text):
            return appState.t("已對 \(sessionLabel) 輸入按鍵文字：`\(text)`", "Typed into \(sessionLabel): `\(text)`")
        case .paste(let text, let submit):
            let suffix = submit ? appState.t(" 並送出", " and submitted") : ""
            return appState.t("已對 \(sessionLabel) 貼上內容\(suffix)：`\(text)`", "Pasted into \(sessionLabel)\(suffix): `\(text)`")
        case .keys(let keys):
            return appState.t("已對 \(sessionLabel) 發送按鍵：`\(keys.map(\.rawValue).joined(separator: ", "))`", "Sent keys to \(sessionLabel): `\(keys.map(\.rawValue).joined(separator: ", "))`")
        }
    }

    private func mentionedSessionMap(in text: String) -> [String: UUID] {
        let normalizedText = text.uppercased()
        var result: [String: UUID] = [:]

        for (index, option) in sessionMentionOptions.enumerated() {
            let token = "S\(index + 1)"
            let explicitMentionPattern = "(?<![A-Z0-9])@\(token)(?![A-Z0-9])"

            if normalizedText.containsMatch(for: explicitMentionPattern) {
                result[token] = option.id
            }
        }

        return result
    }

    private func transcriptContextSnapshots(
        mentionedSessions: [String: UUID],
        fallbackSessionID: UUID?
    ) -> [SessionContextSnapshot] {
        if mentionedSessions.isEmpty {
            guard let fallbackSessionID else { return [] }
            return makeSessionSnapshot(for: fallbackSessionID).map { [$0] } ?? []
        }

        return mentionedSessions.keys.sorted().compactMap { token in
            guard let sessionID = mentionedSessions[token] else { return nil }
            return makeSessionSnapshot(for: sessionID)
        }
    }

    private func containsAutomationDirective(in text: String) -> Bool {
        text.contains(confirmedDoToken)
    }

    private func sessionReferenceLabel(for session: SSHSession) -> String {
        if let index = appState.sessions.firstIndex(where: { $0.id == session.id }) {
            return "S\(index + 1) \(session.host.displayTitle)"
        }
        return session.host.displayTitle
    }

    private func cancelCurrentRequest() {
        activeRequestID = UUID()
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
    }

    private func isIsolatableSubsystemFailure(_ error: Error) -> Bool {
        if error is URLError {
            return false
        }
        let nsError = error as NSError
        return nsError.domain != "AIService"
    }

    @MainActor
    private func isolateSubsystem(with error: Error) {
        cancelCurrentRequest()
        let message = appState.t(
            "AI 子系統發生內部錯誤，已將 AI 面板隔離。SSH Session 不受影響。",
            "The AI subsystem encountered an internal error and has been isolated. SSH sessions remain unaffected."
        )
        errorMessage = message
        onSubsystemFailure?(message)
    }

    private func resolveTargetSession(
        for parsedAction: ParsedControlAction,
        mentionedSessions: [String: UUID]
    ) -> SSHSession? {
        if let token = parsedAction.sessionToken?.replacingOccurrences(of: "@", with: ""),
           let sessionID = mentionedSessions[token],
           let session = appState.sessions.first(where: { $0.id == sessionID }) {
            return session
        }

        if mentionedSessions.count == 1,
           let sessionID = mentionedSessions.values.first,
           let session = appState.sessions.first(where: { $0.id == sessionID }) {
            return session
        }

        if lockControlSession, let selectedSessionId {
            return appState.sessions.first { $0.id == selectedSessionId }
        }

        if let selectedSessionId {
            return appState.sessions.first { $0.id == selectedSessionId }
        }

        return targetSession
    }

    private func resolvedSessions(from text: String) -> [SSHSession] {
        let mentions = mentionedSessionMap(in: text)
        guard !mentions.isEmpty else { return [] }
        return mentions.keys.sorted().compactMap { token in
            guard let sessionID = mentions[token] else { return nil }
            return appState.sessions.first(where: { $0.id == sessionID })
        }
    }

    private func makeSessionSnapshot(for sessionID: UUID?) -> SessionContextSnapshot? {
        guard let sessionID,
              let index = appState.sessions.firstIndex(where: { $0.id == sessionID })
        else { return nil }

        let session = appState.sessions[index]
        return SessionContextSnapshot(
            id: session.id,
            token: "S\(index + 1)",
            displayTitle: session.host.displayTitle,
            connectionLabel: session.host.connectionLabel,
            authMethodLabel: session.host.authMethod.rawValue,
            statusLabel: session.status.label,
            transcript: session.recentTranscript()
        )
    }

    private func applyCompletion(_ option: InputCompletionOption) {
        let replacement: String
        switch option.kind {
        case .session:
            replacement = "\(option.token) "
        case .slashCommand(let command):
            replacement = "\(confirmedSlashCommandToken(for: command)) "
        }

        if let range = currentCompletionRange, let swiftRange = Range(range, in: inputText) {
            inputText.replaceSubrange(swiftRange, with: replacement)
            requestedSelectionLocation = range.location + (replacement as NSString).length
        } else {
            if !inputText.isEmpty, !inputText.hasSuffix(" ") {
                inputText += " "
            }
            inputText += replacement
            requestedSelectionLocation = (inputText as NSString).length
        }
        completionQuery = nil
        completionTrigger = nil
        currentCompletionRange = nil
    }

    private func confirmCurrentCompletionSelection() -> Bool {
        guard !filteredCompletionOptions.isEmpty else { return false }
        let index = min(selectedCompletionIndex, filteredCompletionOptions.count - 1)
        applyCompletion(filteredCompletionOptions[index])
        return true
    }

    private func moveCompletionSelection(up: Bool) -> Bool {
        guard !filteredCompletionOptions.isEmpty else { return false }
        if up {
            selectedCompletionIndex = max(0, selectedCompletionIndex - 1)
        } else {
            selectedCompletionIndex = min(filteredCompletionOptions.count - 1, selectedCompletionIndex + 1)
        }
        return true
    }

    private func sanitizedUserInput(_ text: String) -> String {
        text.replacingOccurrences(of: Self.confirmedCommandMarker, with: "")
    }

    private func confirmedSlashCommandToken(for command: SlashCommand) -> String {
        "\(command.token)\(Self.confirmedCommandMarker)"
    }
}

private extension String {
    func containsMatch(for pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}

// MARK: - Session Selector

struct SessionSelectorView: View {
    @EnvironmentObject var appState: AppState
    let sessions: [SSHSession]
    @Binding var selectedSessionId: UUID?
    @Binding var lockControlSession: Bool
    let targetSession: SSHSession?

    var body: some View {
        VStack(spacing: 0) {
            if sessions.isEmpty {
                HStack {
                    Image(systemName: "terminal").foregroundStyle(.tertiary)
                    Text(appState.t("尚無連線中的 Session", "No active sessions"))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            } else {
                HStack(spacing: 8) {
                    Text(appState.t("控制 Session", "Control Session"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: selectionBinding) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { i, session in
                            Text("S\(i + 1) \(session.host.displayTitle)").tag(Optional(session.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Toggle(appState.t("鎖定控制 Session", "Lock Control Session"), isOn: $lockControlSession)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)

                // Active session info
                if let session = targetSession {
                    let num = (sessions.firstIndex(where: { $0.id == session.id }) ?? 0) + 1
                    HStack(spacing: 6) {
                        Circle().fill(session.status.color).frame(width: 6, height: 6)
                        Text("S\(num) — \(session.host.connectionLabel)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(appState.t("AI 會直接模擬輸入到這個 Session", "AI will send input directly to this session"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 6)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .onAppear {
            syncSelectedSessionIfNeeded()
        }
        .onChange(of: sessions.map(\.id)) { _ in
            syncSelectedSessionIfNeeded()
        }
    }

    private var validSelectedSessionId: UUID? {
        if let selectedSessionId, sessions.contains(where: { $0.id == selectedSessionId }) {
            return selectedSessionId
        }
        return sessions.first?.id
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: {
                validSelectedSessionId
            },
            set: { newValue in
                guard let newValue, sessions.contains(where: { $0.id == newValue }) else {
                    selectedSessionId = sessions.first?.id
                    return
                }
                selectedSessionId = newValue
            }
        )
    }

    private func syncSelectedSessionIfNeeded() {
        let validId = validSelectedSessionId
        if selectedSessionId != validId {
            selectedSessionId = validId
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    let isTextSelectionEnabled: Bool
    let onSendToTerminal: (String) -> Void
    var isUser: Bool { message.role == "user" }
    var isSystem: Bool { message.role == "system" }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 32) }
            VStack(alignment: bubbleAlignment, spacing: 4) {
                bubbleText
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if !isUser && !isSystem && !message.content.isEmpty {
                    Button { onSendToTerminal(message.content) } label: {
                        Label("發送到 Session", systemImage: "terminal").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: isSystem ? .infinity : 250, alignment: bubbleFrameAlignment)
            if !isUser { Spacer(minLength: isSystem ? 0 : 32) }
        }
    }

    @ViewBuilder
    private var bubbleText: some View {
        let text = Text(message.content.isEmpty ? "▋" : message.content)
            .font(.system(size: 13))
        if isTextSelectionEnabled {
            text.textSelection(.enabled)
        } else {
            text
        }
    }

    private var bubbleAlignment: HorizontalAlignment {
        isUser ? .trailing : .leading
    }

    private var bubbleFrameAlignment: Alignment {
        isUser ? .trailing : .leading
    }

    private var bubbleColor: Color {
        if isUser { return Color.accentColor.opacity(0.2) }
        if isSystem { return Color.orange.opacity(0.12) }
        return Color(NSColor.controlBackgroundColor)
    }
}

struct SessionMentionTextEditor: NSViewRepresentable {
    @Binding var text: String
    let sessions: [AIAssistantView.SessionMentionOption]
    let slashCommandToken: String
    @Binding var completionQuery: String?
    @Binding var completionTrigger: Character?
    @Binding var completionRange: NSRange?
    @Binding var requestedSelectionLocation: Int?
    let onMoveSelectionUp: () -> Bool
    let onMoveSelectionDown: () -> Bool
    let onSubmit: () -> Void
    let onConfirmMention: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            sessions: sessions,
            slashCommandToken: slashCommandToken,
            completionQuery: $completionQuery,
            completionTrigger: $completionTrigger,
            completionRange: $completionRange,
            requestedSelectionLocation: $requestedSelectionLocation,
            onMoveSelectionUp: onMoveSelectionUp,
            onMoveSelectionDown: onMoveSelectionDown,
            onSubmit: onSubmit,
            onConfirmMention: onConfirmMention
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = MentionTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.submitHandler = onSubmit
        textView.confirmMentionHandler = onConfirmMention
        textView.moveMentionSelectionUpHandler = onMoveSelectionUp
        textView.moveMentionSelectionDownHandler = onMoveSelectionDown
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.applyTextStorage(text)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.sessions = sessions
        context.coordinator.submitHandler = onSubmit
        context.coordinator.confirmMentionHandler = onConfirmMention
        context.coordinator.moveMentionSelectionUpHandler = onMoveSelectionUp
        context.coordinator.moveMentionSelectionDownHandler = onMoveSelectionDown
        context.coordinator.requestedSelectionLocation = $requestedSelectionLocation
        if let textView = nsView.documentView as? MentionTextView {
            textView.submitHandler = onSubmit
            textView.confirmMentionHandler = onConfirmMention
            textView.moveMentionSelectionUpHandler = onMoveSelectionUp
            textView.moveMentionSelectionDownHandler = onMoveSelectionDown
        }
        context.coordinator.applyTextStorage(text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var completionQuery: String?
        @Binding var completionTrigger: Character?
        @Binding var completionRange: NSRange?
        var requestedSelectionLocation: Binding<Int?>
        var sessions: [AIAssistantView.SessionMentionOption]
        let slashCommandToken: String
        weak var textView: MentionTextView?
        var submitHandler: () -> Void
        var confirmMentionHandler: () -> Bool
        var moveMentionSelectionUpHandler: () -> Bool
        var moveMentionSelectionDownHandler: () -> Bool
        private var isUpdating = false

        init(
            text: Binding<String>,
            sessions: [AIAssistantView.SessionMentionOption],
            slashCommandToken: String,
            completionQuery: Binding<String?>,
            completionTrigger: Binding<Character?>,
            completionRange: Binding<NSRange?>,
            requestedSelectionLocation: Binding<Int?>,
            onMoveSelectionUp: @escaping () -> Bool,
            onMoveSelectionDown: @escaping () -> Bool,
            onSubmit: @escaping () -> Void,
            onConfirmMention: @escaping () -> Bool
        ) {
            _text = text
            _completionQuery = completionQuery
            _completionTrigger = completionTrigger
            _completionRange = completionRange
            self.requestedSelectionLocation = requestedSelectionLocation
            self.sessions = sessions
            self.slashCommandToken = slashCommandToken
            self.moveMentionSelectionUpHandler = onMoveSelectionUp
            self.moveMentionSelectionDownHandler = onMoveSelectionDown
            self.submitHandler = onSubmit
            self.confirmMentionHandler = onConfirmMention
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            guard !isUpdating else { return }
            text = textView.string
            refreshMentionState()
            applyHighlighting()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            refreshMentionState()
        }

        func applyTextStorage(_ newText: String) {
            guard let textView else { return }
            guard textView.string != newText || isUpdating else { return }
            isUpdating = true
            let selectedRange = textView.selectedRange()
            textView.string = newText
            applyHighlighting()
            applySelection(usingFallbackLocation: selectedRange.location)
            refreshMentionState()
            isUpdating = false
        }

        private func applyHighlighting() {
            guard let textView else { return }
            let selectedRange = textView.selectedRange()
            let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
            let attributed = NSMutableAttributedString(string: textView.string)
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ], range: fullRange)

            for session in sessions {
                let pattern = NSRegularExpression.escapedPattern(for: session.token) + #"(?=\s|$)"#
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                for match in regex.matches(in: textView.string, range: fullRange) {
                    attributed.addAttributes([
                        .foregroundColor: NSColor.controlAccentColor,
                        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.15)
                    ], range: match.range)
                }
            }

            if let regex = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: slashCommandToken) + #"(?=\s|$)"#,
                options: []
            ) {
                for match in regex.matches(in: textView.string, range: fullRange) {
                    attributed.addAttributes([
                        .foregroundColor: NSColor.systemOrange,
                        .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.15)
                    ], range: match.range)
                }
            }

            textView.textStorage?.setAttributedString(attributed)
            let clampedRange = NSRange(
                location: min(selectedRange.location, textView.string.utf16.count),
                length: 0
            )
            textView.setSelectedRange(clampedRange)
            textView.typingAttributes = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ]
        }

        private func applySelection(usingFallbackLocation fallbackLocation: Int) {
            guard let textView else { return }
            let targetLocation = requestedSelectionLocation.wrappedValue ?? fallbackLocation
            let clampedRange = NSRange(
                location: min(targetLocation, textView.string.utf16.count),
                length: 0
            )
            textView.setSelectedRange(clampedRange)
            if requestedSelectionLocation.wrappedValue != nil {
                DispatchQueue.main.async {
                    self.requestedSelectionLocation.wrappedValue = nil
                }
            }
        }

        private func refreshMentionState() {
            guard let textView else { return }
            let cursor = textView.selectedRange().location
            let textNSString = textView.string as NSString
            let prefix = textNSString.substring(to: min(cursor, textNSString.length))
            let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "@/")))
            let parts = prefix.components(separatedBy: separators)
            guard let lastPart = parts.last, let trigger = lastPart.first, trigger == "@" || trigger == "/" else {
                completionQuery = nil
                completionTrigger = nil
                completionRange = nil
                return
            }

            let query = String(lastPart.dropFirst())
            let range = NSRange(location: prefix.utf16.count - lastPart.utf16.count, length: lastPart.utf16.count)
            completionQuery = query
            completionTrigger = trigger
            completionRange = range
        }
    }

}

final class MentionTextView: NSTextView {
    var submitHandler: (() -> Void)?
    var confirmMentionHandler: (() -> Bool)?
    var moveMentionSelectionUpHandler: (() -> Bool)?
    var moveMentionSelectionDownHandler: (() -> Bool)?

    override func mouseDown(with event: NSEvent) {
        NSLog("[Focus] MentionTextView mouseDown responder=%@", String(describing: type(of: window?.firstResponder)))
        if let window {
            _ = window.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            AppState.shared.isAIInputActive = true
            needsDisplay = true
            displayIfNeeded()
            NSLog("[Focus] MentionTextView becomeFirstResponder accepted=%@", accepted.description)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            AppState.shared.isAIInputActive = false
            NSLog("[Focus] MentionTextView resignFirstResponder accepted=%@", accepted.description)
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if hasActiveMarkedText {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            if confirmMentionHandler?() == true {
                return
            }
            submitHandler?()
        case 125:
            if moveMentionSelectionDownHandler?() == true {
                return
            }
            super.keyDown(with: event)
        case 126:
            if moveMentionSelectionUpHandler?() == true {
                return
            }
            super.keyDown(with: event)
        case 48:
            if confirmMentionHandler?() == true {
                return
            }
            super.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }

    private var hasActiveMarkedText: Bool {
        let range = markedRange()
        return range.location != NSNotFound && range.length > 0
    }
}

// MARK: - AI Settings

struct AISettingsView: View {
    @EnvironmentObject var appState: AppState
    @Binding var config: AIConfig
    @Binding var language: AppLanguage
    let onSave: () -> Void
    let onCancel: () -> Void
    var showsChrome: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if showsChrome {
                HStack {
                    Text(appState.t("AI 助理設定", "AI Settings")).font(.title2).fontWeight(.semibold)
                    Spacer()
                }
                .padding(20)
                Divider()
            }

            AISettingsForm(config: $config, language: $language)

            if showsChrome {
                Divider()
                HStack {
                    Spacer()
                    Button(appState.t("取消", "Cancel")) { onCancel() }.keyboardShortcut(.escape)
                    Button(appState.t("儲存", "Save")) { onSave() }.keyboardShortcut(.return).buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
        }
        .frame(width: showsChrome ? 440 : nil, height: showsChrome ? 420 : nil)
    }
}

struct AISettingsForm: View {
    @EnvironmentObject var appState: AppState
    @Binding var config: AIConfig
    @Binding var language: AppLanguage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProviderSection(title: appState.t("語言", "Language")) {
                    LabeledRow(label: appState.t("介面語言", "UI Language")) {
                        Picker("", selection: $language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.label).tag(language)
                            }
                        }
                        .labelsHidden()
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(appState.t("AI 提供者", "AI Provider")).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Picker("", selection: $config.provider) {
                        ForEach(AIProvider.allCases) { p in Text(p.rawValue).tag(p) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }
                Divider()
                switch config.provider {
                case .openai:
                    ProviderSection(title: "OpenAI / ChatGPT") {
                        SecretField(label: "API Key", placeholder: "sk-...", value: $config.openaiKey)
                        ModelNameField(label: appState.t("模型", "Model"), placeholder: "gpt-4o", value: $config.openaiModel)
                        HStack(alignment: .top, spacing: 0) {
                            Text(appState.t("登入方式", "Sign In"))
                                .frame(width: 90, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Text(appState.t("目前 OpenAI 官方公開文件僅明確提供 API Key 呼叫 API；ChatGPT OAuth 公開流程未提供給一般第三方桌面 app 直接串接。", "OpenAI's public API documentation currently supports API key authentication. A public ChatGPT OAuth flow for direct third-party desktop app integration is not available."))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .anthropic:
                    ProviderSection(title: "Anthropic / Claude") {
                        SecretField(label: "API Key", placeholder: "sk-ant-...", value: $config.anthropicKey)
                        ModelNameField(label: appState.t("模型", "Model"), placeholder: "claude-sonnet-4-6", value: $config.anthropicModel)
                    }
                case .gemini:
                    ProviderSection(title: "Google Gemini / AI Studio") {
                        SecretField(label: "API Key", placeholder: "AIza...", value: $config.geminiKey)
                        ModelNameField(label: appState.t("模型", "Model"), placeholder: "gemini-2.0-flash", value: $config.geminiModel)
                    }
                case .ollama:
                    ProviderSection(title: appState.t("Ollama（本機）", "Ollama (Local)")) {
                        LabeledRow(label: appState.t("服務位址", "Base URL")) { TextField("http://localhost:11434", text: $config.ollamaBaseURL) }
                        LabeledRow(label: appState.t("模型名稱", "Model Name")) { TextField("llama3.2", text: $config.ollamaModel) }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct ProviderSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View { VStack(alignment: .leading, spacing: 10) { Text(title).font(.system(size: 13, weight: .semibold)); content() } }
}
struct SecretField: View {
    let label: String; let placeholder: String; @Binding var value: String
    var body: some View { LabeledRow(label: label) { SecureField(placeholder, text: $value) } }
}
struct ModelNameField: View {
    let label: String
    let placeholder: String
    @Binding var value: String

    var body: some View {
        LabeledRow(label: label) {
            TextField(placeholder, text: $value)
        }
    }
}
struct LabeledRow<Content: View>: View {
    let label: String; @ViewBuilder let content: () -> Content
    var body: some View { HStack { Text(label).frame(width: 90, alignment: .trailing).foregroundStyle(.secondary); content().textFieldStyle(.roundedBorder) } }
}
