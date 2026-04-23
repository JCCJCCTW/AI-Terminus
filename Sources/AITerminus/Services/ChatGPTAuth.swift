import Foundation
import AppKit
import CryptoKit
import Network

// MARK: - OAuth Configuration

private enum OAuthConfig {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let callbackPort: UInt16 = 1455
    static let redirectURI = "http://localhost:\(callbackPort)/auth/callback"
    static let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"
}

// MARK: - Data Model

struct ChatGPTAccount {
    let accessToken: String
    let refreshToken: String?
    let expiryDate: Date?
    let email: String?
    let accountID: String?  // chatgpt_account_id from JWT — needed as HTTP header
}

// MARK: - Error Types

enum ChatGPTAuthError: LocalizedError {
    case invalidResponse
    case serverError(String)
    case portInUse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return localizedAppText("OpenAI 認證伺服器回應無效", "Invalid response from OpenAI auth server.")
        case .serverError(let detail):
            return detail
        case .portInUse:
            return localizedAppText(
                "無法啟動認證伺服器（port \(OAuthConfig.callbackPort) 被佔用）",
                "Cannot start auth server (port \(OAuthConfig.callbackPort) in use)"
            )
        }
    }
}

// MARK: - PKCE Helper

private struct PKCEPair {
    let verifier: String
    let challenge: String

    static func generate() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = challengeData.base64URLEncoded
        return PKCEPair(verifier: verifier, challenge: challenge)
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - OAuth Flow (System Browser + Localhost Server)

/// Performs OpenAI OAuth PKCE login using the system browser.
/// Starts a temporary localhost HTTP server on port 1455 to capture the
/// authorization callback — the same approach used by the Codex CLI.
enum ChatGPTAuthWindow {

    private static var listener: NWListener?
    private static var activeConnections: [NWConnection] = []
    private static var pkce: PKCEPair?
    private static var onSuccess: ((ChatGPTAccount) -> Void)?
    private static var onFailure: ((Error) -> Void)?

    @MainActor
    static func present(
        onTokenRetrieved: @escaping (ChatGPTAccount) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        // Cancel any previous in-flight auth.
        stop()

        let pkce = PKCEPair.generate()
        self.pkce = pkce
        self.onSuccess = onTokenRetrieved
        self.onFailure = onError

        // 1) Start localhost HTTP server on the callback port.
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let newListener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: OAuthConfig.callbackPort)!) else {
            onError(ChatGPTAuthError.portInUse)
            return
        }
        listener = newListener

        newListener.stateUpdateHandler = { state in
            if case .failed = state {
                DispatchQueue.main.async { onError(ChatGPTAuthError.portInUse) }
                stop()
            }
        }

        newListener.newConnectionHandler = { connection in
            handleConnection(connection)
        }

        newListener.start(queue: .main)

        // 2) Build the OAuth authorize URL.
        var stateBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
        let state = Data(stateBytes).base64URLEncoded

        var components = URLComponents(string: OAuthConfig.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: OAuthConfig.scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Include org/project info in id_token for API key token-exchange.
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        ]

        // 3) Open in the system browser.
        NSWorkspace.shared.open(components.url!)
    }

    @MainActor
    static func dismiss() { stop() }

    // MARK: - Connection Handling

    private static func handleConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        connection.stateUpdateHandler = { state in
            if case .cancelled = state {
                activeConnections.removeAll { $0 === connection }
            }
        }
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data, let requestStr = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse: GET /auth/callback?code=xxx&... HTTP/1.1
            guard let firstLine = requestStr.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }
            let pathAndQuery = String(parts[1])

            // Only handle the callback path.
            guard pathAndQuery.hasPrefix("/auth/callback") else {
                // Browsers may also request /favicon.ico etc. — ignore.
                sendHTTP(connection: connection, status: 404, html: "Not found")
                return
            }

            let components = URLComponents(string: "http://localhost\(pathAndQuery)")

            // Check for OAuth error.
            if let errorParam = components?.queryItems?.first(where: { $0.name == "error" })?.value {
                let desc = components?.queryItems?.first(where: { $0.name == "error_description" })?.value ?? errorParam
                sendHTTP(connection: connection, status: 400, html: errorHTML(desc))
                DispatchQueue.main.async {
                    onFailure?(ChatGPTAuthError.serverError(desc))
                    stop()
                }
                return
            }

            // Extract authorization code.
            guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value else {
                sendHTTP(connection: connection, status: 400, html: errorHTML("No authorization code."))
                DispatchQueue.main.async {
                    onFailure?(ChatGPTAuthError.invalidResponse)
                    stop()
                }
                return
            }

            // Send success page to browser.
            sendHTTP(connection: connection, status: 200, html: successHTML())

            // Exchange code for tokens.
            Task { @MainActor in
                let savedPKCE = pkce
                stop() // Stop server now that we have the code.

                do {
                    guard let savedPKCE else { throw ChatGPTAuthError.invalidResponse }
                    let account = try await exchangeCode(code, pkce: savedPKCE)
                    onSuccess?(account)
                } catch {
                    onFailure?(error)
                }
                onSuccess = nil
                onFailure = nil
            }
        }
    }

    // MARK: - HTTP Response Helpers

    private static func sendHTTP(connection: NWConnection, status: Int, html: String) {
        let statusText = status == 200 ? "OK" : "Bad Request"
        let body = html.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = (header.data(using: .utf8) ?? Data()) + body
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func successHTML() -> String {
        """
        <!DOCTYPE html><html><body style="font-family:system-ui;text-align:center;padding:80px">
        <h1 style="color:#10a37f">&#10003;</h1>
        <h2>\(localizedAppText("登入成功", "Login Successful"))</h2>
        <p>\(localizedAppText("您可以關閉此頁面並返回 AI Terminus。", "You can close this tab and return to AI Terminus."))</p>
        </body></html>
        """
    }

    private static func errorHTML(_ detail: String) -> String {
        """
        <!DOCTYPE html><html><body style="font-family:system-ui;text-align:center;padding:80px">
        <h2 style="color:red">\(localizedAppText("登入失敗", "Login Failed"))</h2>
        <p>\(detail)</p>
        </body></html>
        """
    }

    // MARK: - Token Exchange

    private static func exchangeCode(_ code: String, pkce: PKCEPair) async throws -> ChatGPTAccount {
        guard let url = URL(string: OAuthConfig.tokenURL) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Use form-urlencoded (same as Codex CLI).
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.redirectURI),
            URLQueryItem(name: "client_id", value: OAuthConfig.clientID),
            URLQueryItem(name: "code_verifier", value: pkce.verifier),
        ]
        request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw ChatGPTAuthError.serverError(
                localizedAppText(
                    "Token 交換失敗 (HTTP \(statusCode)): \(bodyStr)",
                    "Token exchange failed (HTTP \(statusCode)): \(bodyStr)"
                )
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw ChatGPTAuthError.invalidResponse
        }

        let refreshToken = json["refresh_token"] as? String
        let idToken = json["id_token"] as? String
        let expiresIn = json["expires_in"] as? Int
        let email = extractEmail(from: idToken)
        let accountID = extractAccountID(from: idToken)

        return ChatGPTAccount(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryDate: Date().addingTimeInterval(TimeInterval(expiresIn ?? 3600)),
            email: email,
            accountID: accountID
        )
    }

    /// Decode a JWT id_token payload into a dictionary.
    private static func decodeJWTPayload(_ idToken: String) -> [String: Any]? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Extract email from JWT id_token payload.
    private static func extractEmail(from idToken: String?) -> String? {
        guard let idToken, let payload = decodeJWTPayload(idToken) else { return nil }
        return payload["email"] as? String
    }

    /// Extract chatgpt_account_id from JWT id_token — required as HTTP header for backend-api.
    private static func extractAccountID(from idToken: String?) -> String? {
        guard let idToken, let payload = decodeJWTPayload(idToken) else { return nil }
        guard let auth = payload["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    // MARK: - Cleanup

    private static func stop() {
        for conn in activeConnections { conn.cancel() }
        activeConnections.removeAll()
        listener?.cancel()
        listener = nil
        pkce = nil
    }
}

// MARK: - Token Manager (OAuth refresh)

/// Manages the OAuth access token lifecycle with automatic refresh.
/// Tokens are persisted in UserDefaults and refreshed via the OAuth token endpoint.
actor ChatGPTTokenManager {

    static let shared = ChatGPTTokenManager()

    private var cachedToken: String?
    private var tokenExpiry: Date?
    private var refreshToken: String?
    private var accountID: String?

    /// Cache tokens after successful OAuth login.
    func cacheTokens(access: String, refresh: String?, expiry: Date?, accountID: String?) {
        cachedToken = access
        tokenExpiry = expiry
        refreshToken = refresh
        self.accountID = accountID
        persistTokens()
    }

    /// Returns a valid access token, refreshing via OAuth if expired.
    static func validAccessToken() async throws -> String {
        try await shared.getValidToken()
    }

    /// Returns the cached ChatGPT account ID (for the ChatGPT-Account-ID header).
    static func chatGPTAccountID() async -> String? {
        await shared.getAccountID()
    }

    private func getAccountID() -> String? {
        if accountID == nil { loadPersistedTokens() }
        return accountID
    }

    private func getValidToken() async throws -> String {
        // Try in-memory cache first.
        if let token = cachedToken, let expiry = tokenExpiry,
           expiry.timeIntervalSinceNow > 300 {
            return token
        }

        // Load persisted tokens if not in memory.
        if cachedToken == nil { loadPersistedTokens() }

        // Check if persisted token is still valid.
        if let token = cachedToken, let expiry = tokenExpiry,
           expiry.timeIntervalSinceNow > 300 {
            return token
        }

        // Need to refresh.
        guard let rt = refreshToken else {
            throw ChatGPTAuthError.serverError(
                localizedAppText("登入已過期，請重新以 ChatGPT 帳號登入", "Session expired, please sign in with ChatGPT again")
            )
        }

        return try await refreshAccessToken(rt)
    }

    private func refreshAccessToken(_ rt: String) async throws -> String {
        guard let url = URL(string: OAuthConfig.tokenURL) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: OAuthConfig.clientID),
            URLQueryItem(name: "refresh_token", value: rt),
        ]
        request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            clearAll()
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ChatGPTAuthError.serverError(
                localizedAppText(
                    "Token 更新失敗 (HTTP \(statusCode))，請重新登入",
                    "Token refresh failed (HTTP \(statusCode)), please sign in again"
                )
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            throw ChatGPTAuthError.invalidResponse
        }

        if let newRT = json["refresh_token"] as? String { refreshToken = newRT }

        let expiresIn = json["expires_in"] as? Int
        cachedToken = newAccessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn ?? 3600))
        persistTokens()

        return newAccessToken
    }

    static func clearTokens() async {
        await shared.clearAll()
    }

    private func clearAll() {
        cachedToken = nil
        tokenExpiry = nil
        refreshToken = nil
        accountID = nil
        UserDefaults.standard.removeObject(forKey: "chatgpt_access_token")
        UserDefaults.standard.removeObject(forKey: "chatgpt_refresh_token")
        UserDefaults.standard.removeObject(forKey: "chatgpt_token_expiry")
        UserDefaults.standard.removeObject(forKey: "chatgpt_account_id")
    }

    private func persistTokens() {
        if let t = cachedToken { UserDefaults.standard.set(t, forKey: "chatgpt_access_token") }
        if let r = refreshToken { UserDefaults.standard.set(r, forKey: "chatgpt_refresh_token") }
        if let e = tokenExpiry { UserDefaults.standard.set(e.timeIntervalSince1970, forKey: "chatgpt_token_expiry") }
        if let a = accountID { UserDefaults.standard.set(a, forKey: "chatgpt_account_id") }
    }

    private func loadPersistedTokens() {
        cachedToken = UserDefaults.standard.string(forKey: "chatgpt_access_token")
        refreshToken = UserDefaults.standard.string(forKey: "chatgpt_refresh_token")
        let ts = UserDefaults.standard.double(forKey: "chatgpt_token_expiry")
        tokenExpiry = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        accountID = UserDefaults.standard.string(forKey: "chatgpt_account_id")
    }
}
