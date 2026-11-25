import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum OAuthError: LocalizedError {
    case invalidURL
    case discoveryFailed(String)
    case registrationFailed(String)
    case callbackFailed(String)
    case tokenExchangeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid T3 Code MCP URL."
        case .discoveryFailed(let msg): return "OAuth discovery failed: \(msg)"
        case .registrationFailed(let msg): return "Client registration failed: \(msg)"
        case .callbackFailed(let msg): return "Authorization callback failed: \(msg)"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .cancelled: return "Sign-in was cancelled."
        }
    }
}

private struct ProtectedResourceMetadata: Decodable {
    let resource: String?
    let authorizationServers: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
    }
}

private struct AuthorizationServerMetadata: Decodable {
    let issuer: String?
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let registrationEndpoint: String?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
    }
}

private struct DynamicClientRegistrationResponse: Decodable {
    let clientId: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

final class OAuthManager: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Runs full MCP OAuth 2.1 (RFC 9728 + RFC 8414 + DCR + PKCE) against a T3 Code `/mcp` endpoint.
    func authorize(mcpURLString: String) async throws -> SavedConnection {
        guard let mcpURL = URL(string: mcpURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = mcpURL.scheme, (scheme == "http" || scheme == "https"),
              mcpURL.host != nil else {
            throw OAuthError.invalidURL
        }

        // 1. Discover OAuth metadata (also probe /mcp to read WWW-Authenticate if present)
        let resourceMetadataURL = await probeResourceMetadataURL(for: mcpURL)
        let (authServerMetadata, resourceIdentifier) = try await discoverMetadata(
            mcpURL: mcpURL,
            hintedMetadataURL: resourceMetadataURL
        )

        // 2. Start local loopback HTTP server for callback
        let callbackServer = try LoopbackCallbackServer()
        let port = try await callbackServer.start()
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        // 3. Dynamic Client Registration (or fallback client_id)
        let clientId: String
        if let regEndpoint = authServerMetadata.registrationEndpoint,
           let regURL = URL(string: regEndpoint) {
            clientId = try await registerClient(at: regURL, redirectURI: redirectURI)
        } else {
            clientId = "t3bar-macos"
        }

        // 4. Generate PKCE verifier/challenge and state
        let verifier = Self.randomBase64URL(byteCount: 32)
        let challenge = Self.sha256Base64URL(verifier)
        let state = Self.randomBase64URL(byteCount: 16)

        guard var comps = URLComponents(string: authServerMetadata.authorizationEndpoint) else {
            callbackServer.stop()
            throw OAuthError.discoveryFailed("Invalid authorization endpoint")
        }
        var items = comps.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resourceIdentifier)
        ])
        comps.queryItems = items

        guard let authURL = comps.url else {
            callbackServer.stop()
            throw OAuthError.discoveryFailed("Could not build authorization URL")
        }

        // 5. Open browser on MainActor
        _ = await MainActor.run {
            NSWorkspace.shared.open(authURL)
        }

        // 6. Wait for loopback callback (timeout 180s)
        let callbackResult = try await callbackServer.waitForCallback(timeoutSeconds: 180)
        callbackServer.stop()

        if let err = callbackResult.error {
            throw OAuthError.callbackFailed(callbackResult.errorDescription ?? err)
        }
        guard callbackResult.state == state, let code = callbackResult.code else {
            throw OAuthError.callbackFailed("Missing authorization code or state mismatch.")
        }

        // 7. Exchange code for tokens
        guard let tokenURL = URL(string: authServerMetadata.tokenEndpoint) else {
            throw OAuthError.tokenExchangeFailed("Invalid token endpoint")
        }

        let tokenResponse = try await exchangeCode(
            tokenURL: tokenURL,
            code: code,
            redirectURI: redirectURI,
            clientId: clientId,
            codeVerifier: verifier,
            resource: resourceIdentifier
        )

        let expiresAt = tokenResponse.expiresIn.map { Date().addingTimeInterval($0) }
        return SavedConnection(
            mcpURL: mcpURL.absoluteString,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: expiresAt,
            clientId: clientId,
            tokenEndpoint: authServerMetadata.tokenEndpoint,
            useManualToken: false
        )
    }

    func refresh(connection: SavedConnection) async throws -> SavedConnection {
        guard let refreshToken = connection.refreshToken,
              let tokenEndpoint = connection.tokenEndpoint,
              let tokenURL = URL(string: tokenEndpoint) else {
            throw OAuthError.tokenExchangeFailed("No refresh token available. Please reconnect.")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var form: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "resource": connection.mcpURL
        ]
        if let clientId = connection.clientId {
            form["client_id"] = clientId
        }
        request.httpBody = Self.formEncoded(form)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        var updated = connection
        updated.accessToken = decoded.accessToken
        if let newRefresh = decoded.refreshToken {
            updated.refreshToken = newRefresh
        }
        updated.expiresAt = decoded.expiresIn.map { Date().addingTimeInterval($0) }
        return updated
    }

    // MARK: - Discovery Helpers

    private func probeResourceMetadataURL(for mcpURL: URL) async -> URL? {
        var req = URLRequest(url: mcpURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"T3Bar","version":"0.1.0"}}}"#.data(using: .utf8)

        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              let wwwAuth = http.value(forHTTPHeaderField: "WWW-Authenticate") else {
            return nil
        }

        // Parse resource_metadata="..."
        if let range = wwwAuth.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) {
            let matched = String(wwwAuth[range])
            let trimmed = matched
                .replacingOccurrences(of: "resource_metadata=\"", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return URL(string: trimmed)
        }
        return nil
    }

    private func discoverMetadata(mcpURL: URL, hintedMetadataURL: URL?) async throws -> (AuthorizationServerMetadata, String) {
        let origin = Self.originURL(from: mcpURL)
        let pathSuffix = mcpURL.path == "/" ? "" : mcpURL.path

        var prmCandidates: [URL] = []
        if let hintedMetadataURL { prmCandidates.append(hintedMetadataURL) }
        if let pathAware = URL(string: "\(origin)/.well-known/oauth-protected-resource\(pathSuffix)") {
            prmCandidates.append(pathAware)
        }
        if let rootPRM = URL(string: "\(origin)/.well-known/oauth-protected-resource") {
            prmCandidates.append(rootPRM)
        }

        var authServerBase = origin
        var resourceId = mcpURL.absoluteString

        for candidate in prmCandidates {
            if let (data, resp) = try? await session.data(from: candidate),
               let http = resp as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let prm = try? JSONDecoder().decode(ProtectedResourceMetadata.self, from: data) {
                if let server = prm.authorizationServers?.first, !server.isEmpty {
                    authServerBase = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }
                if let res = prm.resource, !res.isEmpty {
                    resourceId = res
                }
                break
            }
        }

        let asCandidates = [
            "\(authServerBase)/.well-known/oauth-authorization-server",
            "\(authServerBase)/.well-known/openid-configuration"
        ].compactMap(URL.init(string:))

        for candidate in asCandidates {
            if let (data, resp) = try? await session.data(from: candidate),
               let http = resp as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let meta = try? JSONDecoder().decode(AuthorizationServerMetadata.self, from: data) {
                return (meta, resourceId)
            }
        }

        throw OAuthError.discoveryFailed("Could not find OAuth metadata at \(authServerBase). Check that your T3 Code MCP URL is reachable.")
    }

    private func registerClient(at url: URL, redirectURI: String) async throws -> String {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "client_name": "T3Bar",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.registrationFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }

        let decoded = try JSONDecoder().decode(DynamicClientRegistrationResponse.self, from: data)
        return decoded.clientId
    }

    private func exchangeCode(
        tokenURL: URL,
        code: String,
        redirectURI: String,
        clientId: String,
        codeVerifier: String,
        resource: String
    ) async throws -> TokenResponse {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        req.httpBody = Self.formEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": codeVerifier,
            "resource": resource
        ])

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }

        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Utilities

    private static func originURL(from url: URL) -> String {
        let scheme = url.scheme ?? "https"
        let host = url.host ?? "127.0.0.1"
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private static func formEncoded(_ params: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let str = params
            .map { key, val in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = val.addingPercentEncoding(withAllowedCharacters: allowed) ?? val
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return Data(str.utf8)
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func sha256Base64URL(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback Callback Server (127.0.0.1 ephemeral port)

private struct OAuthCallbackResult: Sendable {
    let code: String?
    let state: String?
    let error: String?
    let errorDescription: String?
}

private final class LoopbackCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.juliusrook.t3bar.oauth-loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OAuthCallbackResult, Error>?
    private var delivered = false
    private var startResumed = false

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        self.listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.lock()
                    let shouldResume = !self.startResumed
                    self.startResumed = true
                    self.lock.unlock()
                    guard shouldResume else { return }
                    let port = self.listener.port?.rawValue ?? 0
                    cont.resume(returning: port)
                case .failed(let error):
                    self.lock.lock()
                    let shouldResume = !self.startResumed
                    self.startResumed = true
                    self.lock.unlock()
                    guard shouldResume else { return }
                    cont.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }

            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeoutSeconds: UInt64) async throws -> OAuthCallbackResult {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            self.continuation = cont
            lock.unlock()

            queue.asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) { [weak self] in
                self?.finish(with: .failure(OAuthError.callbackFailed("Timed out waiting for browser authorization.")))
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }

            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"

            guard path.hasPrefix("/callback"),
                  let comps = URLComponents(string: "http://127.0.0.1\(path)") else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(notFound.utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            let items = comps.queryItems ?? []
            let query: (String) -> String? = { name in items.first(where: { $0.name == name })?.value }
            let result = OAuthCallbackResult(
                code: query("code"),
                state: query("state"),
                error: query("error"),
                errorDescription: query("error_description")
            )

            let html = """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>T3Bar</title>
            <style>body{font-family:-apple-system,sans-serif;background:#111;color:#f5f5f5;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
            .card{background:#1c1c1e;border:1px solid #333;border-radius:14px;padding:28px 34px;text-align:center}
            h1{font-size:18px;margin:0 0 8px}p{font-size:13px;color:#999;margin:0}</style></head>
            <body><div class="card"><h1>\(result.error == nil ? "T3Bar Connected" : "Authorization Failed")</h1>
            <p>\(result.error == nil ? "You can close this tab and return to the menu bar." : (result.errorDescription ?? result.error ?? "Error"))</p></div></body></html>
            """
            let bodyData = Data(html.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
            var payload = Data(response.utf8)
            payload.append(bodyData)

            conn.send(content: payload, completion: .contentProcessed { _ in
                conn.cancel()
            })

            self.finish(with: .success(result))
        }
    }

    private func finish(with result: Result<OAuthCallbackResult, Error>) {
        lock.lock()
        guard !delivered, let cont = continuation else {
            lock.unlock()
            return
        }
        delivered = true
        continuation = nil
        lock.unlock()

        switch result {
        case .success(let value): cont.resume(returning: value)
        case .failure(let error): cont.resume(throwing: error)
        }
    }
}
