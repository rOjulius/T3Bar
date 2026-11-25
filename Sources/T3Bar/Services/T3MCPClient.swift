import Foundation

enum MCPError: LocalizedError {
    case notConfigured
    case unauthorized
    case httpError(Int, String)
    case protocolError(String)
    case toolError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Not connected to T3 Code."
        case .unauthorized: return "Authentication expired. Please reconnect."
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .protocolError(let msg): return "MCP error: \(msg)"
        case .toolError(let msg): return msg
        }
    }
}

actor T3MCPClient {
    private var connection: SavedConnection?
    private var sessionId: String?
    private var initialized = false
    private var requestId = 1
    private let urlSession: URLSession
    private let oauthManager = OAuthManager()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.urlSession = URLSession(configuration: config)
    }

    func configure(with connection: SavedConnection?) {
        self.connection = connection
        self.sessionId = nil
        self.initialized = false
    }

    func currentConnection() -> SavedConnection? {
        connection
    }

    // MARK: - High-Level T3 Code MCP Calls

    func listProjects() async throws -> [T3Project] {
        let data = try await callTool(name: "t3_project_list", arguments: [:])
        let decoded = try JSONDecoder().decode(ProjectListPayload.self, from: data)
        return decoded.projects
    }

    func listThreads(limit: Int = 40) async throws -> [T3Thread] {
        let data = try await callTool(
            name: "t3_thread_list",
            arguments: [
                "allProjects": true,
                "includeSubagents": true,
                "limit": limit
            ]
        )
        let decoded = try JSONDecoder().decode(ThreadListPayload.self, from: data)
        return decoded.threads.map { $0.toDomain() }
    }

    func readThreadActivity(threadId: String, limit: Int = 4) async throws -> ThreadReadPayload {
        let data = try await callTool(
            name: "t3_thread_read",
            arguments: [
                "threadId": threadId,
                "view": "activity",
                "limit": limit,
                "maxCharsPerItem": 400
            ]
        )
        return try JSONDecoder().decode(ThreadReadPayload.self, from: data)
    }

    func stopThread(_ thread: T3Thread) async throws {
        if let taskId = thread.derivedDelegatedTaskId {
            do {
                _ = try await callTool(
                    name: "task_cancel",
                    arguments: [
                        "taskId": taskId,
                        "reason": "Stopped from T3Bar"
                    ]
                )
                return
            } catch {
                // Fall back to t3_thread_interrupt if task_cancel is unavailable or rejected
                _ = try await callTool(
                    name: "t3_thread_interrupt",
                    arguments: [
                        "threadId": thread.threadId,
                        "reason": "Stopped from T3Bar"
                    ]
                )
                return
            }
        }

        _ = try await callTool(
            name: "t3_thread_interrupt",
            arguments: [
                "threadId": thread.threadId,
                "reason": "Stopped from T3Bar"
            ]
        )
    }

    // MARK: - Streamable HTTP MCP Transport

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        _ = try await sendJSONRPC(
            method: "initialize",
            params: [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "T3Bar",
                    "version": "0.1.0"
                ]
            ],
            isNotification: false
        )
        // Fire-and-forget initialized notification
        _ = try? await sendJSONRPC(
            method: "notifications/initialized",
            params: nil,
            isNotification: true
        )
        initialized = true
    }

    private func callTool(name: String, arguments: [String: Any]) async throws -> Data {
        try await ensureInitialized()

        let resultObject: [String: Any]
        do {
            resultObject = try await sendJSONRPC(
                method: "tools/call",
                params: [
                    "name": name,
                    "arguments": arguments
                ],
                isNotification: false
            )
        } catch MCPError.httpError(let code, _) where code == 400 || code == 404 {
            // Session may have expired on T3 server restart; re-initialize once
            sessionId = nil
            initialized = false
            try await ensureInitialized()
            resultObject = try await sendJSONRPC(
                method: "tools/call",
                params: [
                    "name": name,
                    "arguments": arguments
                ],
                isNotification: false
            )
        }

        if let isError = resultObject["isError"] as? Bool, isError {
            let msg = Self.extractTextContent(from: resultObject) ?? "Tool returned an error."
            throw MCPError.toolError(msg)
        }

        if let structured = resultObject["structuredContent"],
           JSONSerialization.isValidJSONObject(structured) {
            return try JSONSerialization.data(withJSONObject: structured)
        }

        if let text = Self.extractTextContent(from: resultObject),
           let data = text.data(using: .utf8) {
            return data
        }

        return Data("{}".utf8)
    }

    private func sendJSONRPC(
        method: String,
        params: [String: Any]?,
        isNotification: Bool,
        didRefresh: Bool = false
    ) async throws -> [String: Any] {
        guard var conn = connection, let url = URL(string: conn.mcpURL) else {
            throw MCPError.notConfigured
        }

        // Proactively refresh expired OAuth token
        if !conn.useManualToken, conn.isExpiredOrNearExpiry, conn.refreshToken != nil, !didRefresh {
            if let refreshed = try? await oauthManager.refresh(connection: conn) {
                conn = refreshed
                self.connection = refreshed
                try? KeychainStore.save(refreshed)
            }
        }

        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        let currentId = requestId
        if !isNotification {
            body["id"] = currentId
            requestId += 1
        }
        if let params {
            body["params"] = params
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token = conn.accessToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let sid = sessionId, !sid.isEmpty {
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.protocolError("Invalid HTTP response")
        }

        if let newSid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !newSid.isEmpty {
            sessionId = newSid
        }

        if http.statusCode == 401 {
            if !conn.useManualToken, conn.refreshToken != nil, !didRefresh {
                let refreshed = try await oauthManager.refresh(connection: conn)
                self.connection = refreshed
                try? KeychainStore.save(refreshed)
                return try await sendJSONRPC(method: method, params: params, isNotification: isNotification, didRefresh: true)
            }
            throw MCPError.unauthorized
        }

        if isNotification && (200..<300).contains(http.statusCode) {
            return [:]
        }

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw MCPError.httpError(http.statusCode, text.prefix(200).description)
        }

        let jsonObj = try Self.parseMCPResponsePayload(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"), expectedId: currentId)

        if let err = jsonObj["error"] as? [String: Any] {
            let message = (err["message"] as? String) ?? "Unknown JSON-RPC error"
            throw MCPError.protocolError(message)
        }

        return (jsonObj["result"] as? [String: Any]) ?? [:]
    }

    private static func parseMCPResponsePayload(data: Data, contentType: String?, expectedId: Int) throws -> [String: Any] {
        let isSSE = contentType?.lowercased().contains("text/event-stream") == true
        let rawString = String(data: data, encoding: .utf8) ?? ""

        if isSSE || rawString.hasPrefix("event:") || rawString.hasPrefix("data:") {
            var lastValid: [String: Any]?
            for line in rawString.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }
                let jsonStr = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !jsonStr.isEmpty, jsonStr != "[DONE]",
                      let jsonData = jsonStr.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continue
                }
                if let id = parsed["id"] as? Int, id == expectedId {
                    return parsed
                }
                if parsed["result"] != nil || parsed["error"] != nil {
                    lastValid = parsed
                }
            }
            if let lastValid {
                return lastValid
            }
            throw MCPError.protocolError("Empty SSE response from server.")
        }

        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.protocolError("Malformed JSON response.")
        }
        return parsed
    }

    private static func extractTextContent(from result: [String: Any]) -> String? {
        guard let content = result["content"] as? [[String: Any]] else { return nil }
        for block in content {
            if let text = block["text"] as? String {
                return text
            }
        }
        return nil
    }
}
