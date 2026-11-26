import Foundation

// MARK: - Domain Models

enum ThreadStatus: String, Codable, Sendable {
    case idle
    case preparing
    case queued
    case starting
    case running
    case waiting
    case completed
    case interrupted
    case failed
    case cancelled
    case rolledBack = "rolled_back"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ThreadStatus(rawValue: raw) ?? .unknown
    }

    var isActive: Bool {
        switch self {
        case .preparing, .queued, .starting, .running, .waiting:
            return true
        default:
            return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .interrupted, .cancelled, .rolledBack:
            return true
        default:
            return false
        }
    }

    var displayLabel: String {
        switch self {
        case .running: return "Working"
        case .starting: return "Starting"
        case .preparing: return "Preparing"
        case .queued: return "Queued"
        case .waiting: return "Waiting"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .interrupted: return "Stopped"
        case .cancelled: return "Cancelled"
        case .rolledBack: return "Rolled back"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }
}

struct T3Project: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let title: String
    let workspaceRoot: String?
}

struct T3Thread: Identifiable, Sendable, Equatable {
    let threadId: String
    let projectId: String?
    let title: String
    let deepLinkURL: URL?
    let status: ThreadStatus
    let providerInstanceId: String?
    let model: String?
    let parentThreadId: String?
    let relationshipToParent: String?
    let createdAt: Date?
    let updatedAt: Date?
    let archived: Bool
    let settled: Bool

    // Enriched from t3_thread_read(view: "activity") for active threads
    var pendingRequestCount: Int = 0
    var activeRunStartedAt: Date? = nil
    var latestStepText: String? = nil

    // Enriched from t3_pending_request(action: "list" / "read") for waiting threads
    var pendingUserRequests: [PendingUserRequest] = []
    var didCheckPendingQuestions: Bool = false

    var id: String { threadId }

    var isSubagent: Bool {
        parentThreadId != nil || relationshipToParent == "subagent"
    }

    var needsAttention: Bool {
        pendingRequestCount > 0 || !pendingUserRequests.isEmpty || status == .waiting
    }

    var hasAnswerableQuestions: Bool {
        !pendingUserRequests.isEmpty
    }

    var needsPermissionApprovalInT3: Bool {
        needsAttention && didCheckPendingQuestions && pendingUserRequests.isEmpty
    }

    var isDelegatedTask: Bool {
        threadId.hasPrefix("thread:delegated-task:")
    }

    var derivedDelegatedTaskId: String? {
        guard isDelegatedTask else { return nil }
        return "node:" + threadId.dropFirst("thread:".count)
    }

    var shortModelName: String {
        guard let raw = model, !raw.isEmpty else {
            return providerInstanceId?.capitalized ?? "Agent"
        }
        return raw
            .replacingOccurrences(of: "gemini-4-", with: "Gemini 4 ")
            .replacingOccurrences(of: "gpt-", with: "GPT-")
            .replacingOccurrences(of: "claude-", with: "Claude ")
            .replacingOccurrences(of: "-sol", with: " Sol")
            .replacingOccurrences(of: "-neon", with: " Neon")
            .replacingOccurrences(of: "-hydrogen", with: " Hydrogen")
            .trimmingCharacters(in: .whitespaces)
    }

    var effectiveStartDate: Date? {
        activeRunStartedAt ?? updatedAt ?? createdAt
    }
}

struct AgentTreeItem: Identifiable, Sendable, Equatable {
    let thread: T3Thread
    let projectName: String?
    let children: [AgentTreeItem]

    var id: String { thread.id }
}

// MARK: - Connection & Stored Config

struct SavedConnection: Codable, Sendable, Equatable {
    var mcpURL: String
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
    var clientId: String?
    var tokenEndpoint: String?
    var useManualToken: Bool

    var isExpiredOrNearExpiry: Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(60) >= expiresAt
    }
}

enum ConnectionState: Sendable, Equatable {
    case unconfigured
    case connecting
    case connected(lastUpdated: Date)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Raw MCP JSON Decoding Shapes

struct ProjectListPayload: Decodable, Sendable {
    let projects: [T3Project]
}

struct ThreadListPayload: Decodable, Sendable {
    let threads: [RawThread]
}

struct RawThread: Decodable, Sendable {
    let threadId: String
    let projectId: String?
    let title: String?
    let link: String?
    let status: ThreadStatus?
    let providerInstanceId: String?
    let model: String?
    let parentThreadId: String?
    let relationshipToParent: String?
    let createdAt: String?
    let updatedAt: String?
    let archived: Bool?
    let settled: Bool?

    func toDomain() -> T3Thread {
        T3Thread(
            threadId: threadId,
            projectId: projectId,
            title: (title?.isEmpty == false ? title! : "Untitled Thread"),
            deepLinkURL: Self.extractDeepLink(from: link),
            status: status ?? .unknown,
            providerInstanceId: providerInstanceId,
            model: model,
            parentThreadId: parentThreadId,
            relationshipToParent: relationshipToParent,
            createdAt: ISO8601DateParser.parse(createdAt),
            updatedAt: ISO8601DateParser.parse(updatedAt),
            archived: archived ?? false,
            settled: settled ?? false
        )
    }

    private static func extractDeepLink(from markdownLink: String?) -> URL? {
        guard let markdownLink, !markdownLink.isEmpty else { return nil }
        if markdownLink.hasPrefix("t3-thread://"), let url = URL(string: markdownLink) {
            return url
        }
        if let start = markdownLink.range(of: "(t3-thread://"),
           let end = markdownLink.range(of: ")", range: start.upperBound..<markdownLink.endIndex) {
            let urlStr = "t3-thread://" + markdownLink[start.upperBound..<end.lowerBound]
            return URL(string: urlStr)
        }
        return nil
    }
}

struct ThreadReadPayload: Decodable, Sendable {
    let thread: RawThreadDetail?
    let recentRuns: [RawRun]?
    let items: [RawActivityItem]?
}

struct RawThreadDetail: Decodable, Sendable {
    let pendingRequestCount: Int?
    let status: ThreadStatus?
}

struct RawRun: Decodable, Sendable {
    let runId: String?
    let status: String?
    let startedAt: String?
    let completedAt: String?
}

struct RawActivityItem: Decodable, Sendable {
    let type: String?
    let status: String?
    let title: String?
    let text: String?
    let updatedAt: String?
}

// MARK: - Pending User Questions (t3_pending_request)

struct PendingRequestListPayload: Decodable, Sendable {
    let requestIds: [String]

    private enum CodingKeys: String, CodingKey {
        case requestIds
        case requests
    }

    private struct RawRequestRef: Decodable {
        let requestId: String?
        let id: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ids = try container.decodeIfPresent([String].self, forKey: .requestIds) {
            self.requestIds = ids
        } else if let refs = try container.decodeIfPresent([RawRequestRef].self, forKey: .requests) {
            self.requestIds = refs.compactMap { $0.requestId ?? $0.id }
        } else {
            self.requestIds = []
        }
    }
}

struct PendingUserQuestionOption: Identifiable, Sendable, Equatable, Decodable {
    let label: String
    let description: String?
    let value: String?

    var id: String { value ?? label }
    var answerValue: String { value ?? label }

    private enum CodingKeys: String, CodingKey {
        case label
        case title
        case text
        case description
        case value
    }

    init(label: String, description: String? = nil, value: String? = nil) {
        self.label = label
        self.description = description
        self.value = value
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let plainString = try? single.decode(String.self) {
            self.label = plainString
            self.description = nil
            self.value = plainString
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedLabel = try container.decodeIfPresent(String.self, forKey: .label)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .text)
            ?? container.decodeIfPresent(String.self, forKey: .value)
            ?? "Option"
        self.label = decodedLabel
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
    }
}

struct PendingUserQuestion: Identifiable, Sendable, Equatable, Decodable {
    let id: String
    let header: String?
    let question: String
    let options: [PendingUserQuestionOption]
    let multiSelect: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case key
        case header
        case title
        case question
        case prompt
        case text
        case options
        case multiSelect
        case isMultiSelect
        case is_multi_select
    }

    init(id: String, header: String? = nil, question: String, options: [PendingUserQuestionOption] = [], multiSelect: Bool = false) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let qText = try container.decodeIfPresent(String.self, forKey: .question)
            ?? container.decodeIfPresent(String.self, forKey: .prompt)
            ?? container.decodeIfPresent(String.self, forKey: .text)
            ?? "Agent needs your input"
        self.question = qText
        self.header = try container.decodeIfPresent(String.self, forKey: .header)
            ?? container.decodeIfPresent(String.self, forKey: .title)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .key)
            ?? self.header
            ?? qText
        self.options = try container.decodeIfPresent([PendingUserQuestionOption].self, forKey: .options) ?? []
        let ms1 = try container.decodeIfPresent(Bool.self, forKey: .multiSelect)
        let ms2 = try container.decodeIfPresent(Bool.self, forKey: .isMultiSelect)
        let ms3 = try container.decodeIfPresent(Bool.self, forKey: .is_multi_select)
        self.multiSelect = ms1 ?? ms2 ?? ms3 ?? false
    }
}

struct PendingUserRequest: Identifiable, Sendable, Equatable {
    let requestId: String
    let threadId: String
    let questions: [PendingUserQuestion]
    let createdAt: Date?

    var id: String { requestId }
}

struct PendingRequestReadPayload: Decodable, Sendable {
    let requestId: String?
    let threadId: String?
    let questions: [PendingUserQuestion]?
    let prompt: String?
    let question: String?
    let options: [PendingUserQuestionOption]?
    let createdAt: String?
    let request: NestedRequest?

    struct NestedRequest: Decodable, Sendable {
        let requestId: String?
        let id: String?
        let threadId: String?
        let questions: [PendingUserQuestion]?
        let prompt: String?
        let question: String?
        let options: [PendingUserQuestionOption]?
        let createdAt: String?
    }

    func toDomain(fallbackRequestId: String, fallbackThreadId: String) -> PendingUserRequest {
        let reqId = request?.requestId ?? request?.id ?? requestId ?? fallbackRequestId
        let tid = request?.threadId ?? threadId ?? fallbackThreadId
        let created = ISO8601DateParser.parse(request?.createdAt ?? createdAt)

        var resolvedQuestions = request?.questions ?? questions ?? []
        if resolvedQuestions.isEmpty {
            let singlePrompt = request?.question ?? request?.prompt ?? question ?? prompt
            if let singlePrompt, !singlePrompt.isEmpty {
                resolvedQuestions = [
                    PendingUserQuestion(
                        id: "answer",
                        header: nil,
                        question: singlePrompt,
                        options: request?.options ?? options ?? [],
                        multiSelect: false
                    )
                ]
            }
        }

        return PendingUserRequest(
            requestId: reqId,
            threadId: tid,
            questions: resolvedQuestions,
            createdAt: created
        )
    }
}

enum ISO8601DateParser {
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
