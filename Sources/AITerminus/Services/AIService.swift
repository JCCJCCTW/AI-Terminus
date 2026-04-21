import Foundation

// MARK: - Models

struct ChatMessage: Identifiable, Equatable {
    let id: UUID = UUID()
    let role: String // "user" or "assistant"
    var content: String
}

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case anthropic = "Claude (Anthropic)"
    case openai    = "ChatGPT (OpenAI)"
    case gemini    = "Gemini (Google)"
    case ollama    = "Ollama（本機）"

    var id: String { rawValue }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-6"
        case .openai:    return "gpt-4o"
        case .gemini:    return "gemini-2.0-flash"
        case .ollama:    return "llama3.2"
        }
    }

    var modelOptions: [String] {
        switch self {
        case .anthropic: return ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
        case .openai:    return ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "o3-mini"]
        case .gemini:    return ["gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-pro"]
        case .ollama:    return [] // user enters model name manually
        }
    }

    var needsApiKey: Bool { self != .ollama }
}

enum AISessionControlMode: String, CaseIterable, Codable, Identifiable {
    case keys

    var id: String { rawValue }

    var label: String {
        localizedAppText("控制鍵優先", "Keys Preferred")
    }

    var guidance: String {
        localizedAppText(
            "需要控制中斷、歷史命令、方向鍵或互動式程式時優先使用 keys；一般 shell 命令仍可用 command。",
            "Prefer keys for interrupts, command history, arrow keys, and interactive programs; regular shell commands may still use command."
        )
    }

    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer().decode(String.self)
        self = .keys
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AIConfig: Codable, Equatable {
    var provider: AIProvider = .anthropic
    var anthropicKey: String  = ""
    var anthropicModel: String = "claude-sonnet-4-6"
    var openaiKey: String     = ""
    var openaiModel: String   = "gpt-4o"
    var geminiKey: String     = ""
    var geminiModel: String   = "gemini-2.0-flash"
    var ollamaBaseURL: String = "http://localhost:11434"
    var ollamaModel: String   = "llama3.2"
    var sessionControlMode: AISessionControlMode = .keys

    var isReady: Bool {
        switch provider {
        case .anthropic: return !anthropicKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .openai:    return !openaiKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .gemini:    return !geminiKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .ollama:    return !ollamaBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var activeModel: String {
        switch provider {
        case .anthropic: return anthropicModel
        case .openai:    return openaiModel
        case .gemini:    return geminiModel
        case .ollama:    return ollamaModel
        }
    }

    var notReadyMessage: String {
        switch provider {
        case .anthropic: return localizedAppText("請設定 Anthropic API Key", "Please configure an Anthropic API key")
        case .openai:    return localizedAppText("請設定 OpenAI API Key", "Please configure an OpenAI API key")
        case .gemini:    return localizedAppText("請設定 Google AI Studio API Key", "Please configure a Google AI Studio API key")
        case .ollama:    return localizedAppText("請確認 Ollama 服務位址", "Please verify the Ollama base URL")
        }
    }
}

// MARK: - Service

struct AIService {
    static func streamChat(
        messages: [ChatMessage],
        config: AIConfig,
        systemPrompt: String = ""
    ) -> AsyncThrowingStream<String, Error> {
        switch config.provider {
        case .anthropic: return streamAnthropic(messages: messages, config: config, system: systemPrompt)
        case .openai:    return streamOpenAI(messages: messages, config: config, system: systemPrompt)
        case .gemini:    return streamGemini(messages: messages, config: config, system: systemPrompt)
        case .ollama:    return streamOllama(messages: messages, config: config, system: systemPrompt)
        }
    }

    // MARK: Anthropic

    private static func streamAnthropic(
        messages: [ChatMessage], config: AIConfig, system: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw URLError(.badURL) }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(config.anthropicKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    var body: [String: Any] = [
                        "model": config.anthropicModel,
                        "max_tokens": 2048,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] }
                    ]
                    if !system.isEmpty { body["system"] = system }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    try checkHTTP(resp)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        if json == "[DONE]" { break }
                        if let text = anthropicDelta(json) { cont.yield(text) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private static func anthropicDelta(_ json: String) -> String? {
        guard
            let data = json.data(using: .utf8),
            let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (obj["type"] as? String) == "content_block_delta",
            let delta = obj["delta"] as? [String: Any],
            let text  = delta["text"] as? String
        else { return nil }
        return text
    }

    // MARK: OpenAI

    private static func streamOpenAI(
        messages: [ChatMessage], config: AIConfig, system: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { throw URLError(.badURL) }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(config.openaiKey)", forHTTPHeaderField: "Authorization")
                    var msgs: [[String: String]] = []
                    if !system.isEmpty { msgs.append(["role": "system", "content": system]) }
                    msgs += messages.map { ["role": $0.role, "content": $0.content] }
                    let body: [String: Any] = [
                        "model": config.openaiModel,
                        "stream": true,
                        "messages": msgs
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    try checkHTTP(resp)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        if json == "[DONE]" { break }
                        if let text = openAIDelta(json) { cont.yield(text) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private static func openAIDelta(_ json: String) -> String? {
        guard
            let data    = json.data(using: .utf8),
            let obj     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let delta   = choices.first?["delta"] as? [String: Any],
            let text    = delta["content"] as? String
        else { return nil }
        return text
    }

    // MARK: Gemini

    private static func streamGemini(
        messages: [ChatMessage], config: AIConfig, system: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let model = config.geminiModel
                    let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(config.geminiKey)"
                    guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    // Gemini uses "user"/"model" roles, no "assistant"
                    let contents = messages.map { msg -> [String: Any] in
                        let role = msg.role == "assistant" ? "model" : "user"
                        return ["role": role, "parts": [["text": msg.content]]]
                    }
                    var body: [String: Any] = ["contents": contents]
                    if !system.isEmpty {
                        body["systemInstruction"] = ["parts": [["text": system]]]
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    try checkHTTP(resp)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        if let text = geminiDelta(json) { cont.yield(text) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private static func geminiDelta(_ json: String) -> String? {
        guard
            let data       = json.data(using: .utf8),
            let obj        = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = obj["candidates"] as? [[String: Any]],
            let content    = candidates.first?["content"] as? [String: Any],
            let parts      = content["parts"] as? [[String: Any]],
            let text       = parts.first?["text"] as? String
        else { return nil }
        return text
    }

    // MARK: Ollama (NDJSON streaming)

    private static func streamOllama(
        messages: [ChatMessage], config: AIConfig, system: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let base = config.ollamaBaseURL.hasSuffix("/")
                        ? config.ollamaBaseURL : config.ollamaBaseURL + "/"
                    guard let url = URL(string: base + "api/chat") else { throw URLError(.badURL) }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var msgs: [[String: String]] = []
                    if !system.isEmpty { msgs.append(["role": "system", "content": system]) }
                    msgs += messages.map { ["role": $0.role, "content": $0.content] }
                    let body: [String: Any] = [
                        "model": config.ollamaModel,
                        "stream": true,
                        "messages": msgs
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    try checkHTTP(resp)
                    // Ollama responds with newline-delimited JSON (not SSE)
                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        if let text = ollamaDelta(line) { cont.yield(text) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private static func ollamaDelta(_ line: String) -> String? {
        guard
            let data    = line.data(using: .utf8),
            let obj     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = obj["message"] as? [String: Any],
            let text    = message["content"] as? String,
            !(obj["done"] as? Bool == true && text.isEmpty)
        else { return nil }
        return text
    }

    // MARK: Shared

    private static func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw NSError(
                domain: "AIService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API 錯誤：HTTP \(http.statusCode)"]
            )
        }
    }
}
