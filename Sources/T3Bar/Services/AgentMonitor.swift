import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AgentMonitor {
    var settings = AppSettings()

    var connectionState: ConnectionState = .unconfigured
    var savedMCPURL: String = ""
    var isConnectedWithManualToken: Bool = false

    var allThreads: [T3Thread] = []
    var projectsById: [String: String] = [:]

    var isRefreshing: Bool = false
    var isAuthorizing: Bool = false
    var authError: String? = nil
    var actionBanner: String? = nil
    var stoppingThreadIds: Set<String> = []
    var respondingRequestIds: Set<String> = []
    var showSetup: Bool = false

    var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "t3bar.notificationsEnabled")
            if notificationsEnabled {
                NotificationService.shared.setup()
            }
        }
    }

    var launchAtLogin: Bool {
        didSet {
            setLaunchAtLogin(launchAtLogin)
        }
    }

    private let client = T3MCPClient()
    private let oauthManager = OAuthManager()
    private var pollingTask: Task<Void, Never>?
    private var previousSnapshot: [String: (status: ThreadStatus, pending: Int)] = [:]
    private var hasCompletedInitialPoll = false
    private var lastProjectsFetch: Date = .distantPast

    init() {
        let savedNotif = UserDefaults.standard.object(forKey: "t3bar.notificationsEnabled") as? Bool
        self.notificationsEnabled = savedNotif ?? true
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)

        if let saved = KeychainStore.load() {
            self.savedMCPURL = saved.mcpURL
            self.isConnectedWithManualToken = saved.useManualToken
            self.connectionState = .connecting
            Task {
                await client.configure(with: saved)
                startPolling()
            }
        } else {
            self.connectionState = .unconfigured
            self.showSetup = true
        }

        if notificationsEnabled {
            NotificationService.shared.setup()
        }
    }

    // MARK: - Computed Views of State

    var needsAttentionThreads: [T3Thread] {
        allThreads
            .filter { $0.needsAttention && !$0.archived }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    var activeTrees: [AgentTreeItem] {
        let active = allThreads.filter { $0.status.isActive && !$0.archived }
        let byId = Dictionary(uniqueKeysWithValues: active.map { ($0.threadId, $0) })

        var childrenMap: [String: [T3Thread]] = [:]
        var roots: [T3Thread] = []

        for thread in active {
            if let parentId = thread.parentThreadId, byId[parentId] != nil {
                childrenMap[parentId, default: []].append(thread)
            } else {
                roots.append(thread)
            }
        }

        roots.sort { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }

        return roots.map { root in
            let kids: [AgentTreeItem]
            if settings.showSubagents {
                kids = (childrenMap[root.threadId] ?? [])
                    .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
                    .map { child in
                        AgentTreeItem(
                            thread: child,
                            projectName: child.projectId.flatMap { projectsById[$0] },
                            children: []
                        )
                    }
            } else {
                kids = []
            }
            return AgentTreeItem(
                thread: root,
                projectName: root.projectId.flatMap { projectsById[$0] },
                children: kids
            )
        }
    }

    var recentThreads: [T3Thread] {
        guard settings.recentCountLimit > 0 else { return [] }
        return allThreads
            .filter { $0.status.isTerminal && !$0.archived }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(settings.recentCountLimit)
            .map { $0 }
    }

    var activeCount: Int {
        allThreads.filter { $0.status.isActive && !$0.archived }.count
    }

    var attentionCount: Int {
        needsAttentionThreads.count
    }

    func projectName(for thread: T3Thread) -> String? {
        thread.projectId.flatMap { projectsById[$0] }
    }

    // MARK: - Auth & Connection

    func connectWithOAuth(mcpURL: String) {
        let cleaned = mcpURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            authError = "Please paste your T3 Code MCP URL."
            return
        }

        isAuthorizing = true
        authError = nil
        connectionState = .connecting

        Task {
            do {
                let conn = try await oauthManager.authorize(mcpURLString: cleaned)
                try KeychainStore.save(conn)
                await client.configure(with: conn)
                self.savedMCPURL = conn.mcpURL
                self.isConnectedWithManualToken = false
                self.isAuthorizing = false
                self.showSetup = false
                self.hasCompletedInitialPoll = false
                self.startPolling()
            } catch {
                self.isAuthorizing = false
                self.authError = error.localizedDescription
                self.connectionState = .error(error.localizedDescription)
            }
        }
    }

    func connectWithManualToken(mcpURL: String, bearerToken: String) {
        let cleanedURL = mcpURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleanedURL),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil else {
            authError = "Please enter a valid http(s) MCP URL."
            return
        }

        let conn = SavedConnection(
            mcpURL: cleanedURL,
            accessToken: cleanedToken.isEmpty ? nil : cleanedToken,
            refreshToken: nil,
            expiresAt: nil,
            clientId: nil,
            tokenEndpoint: nil,
            useManualToken: true
        )

        isAuthorizing = true
        authError = nil
        connectionState = .connecting

        Task {
            do {
                await client.configure(with: conn)
                _ = try await client.listProjects()
                try KeychainStore.save(conn)
                self.savedMCPURL = cleanedURL
                self.isConnectedWithManualToken = true
                self.isAuthorizing = false
                self.showSetup = false
                self.hasCompletedInitialPoll = false
                self.startPolling()
            } catch {
                await client.configure(with: nil)
                self.isAuthorizing = false
                self.authError = error.localizedDescription
                self.connectionState = .error(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        KeychainStore.clear()
        Task { await client.configure(with: nil) }
        allThreads = []
        projectsById = [:]
        previousSnapshot = [:]
        hasCompletedInitialPoll = false
        connectionState = .unconfigured
        authError = nil
        actionBanner = nil
        showSetup = true
    }

    // MARK: - Polling & Enrichment

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshNow()
                let delaySeconds = UInt64(
                    self.activeCount > 0 ? self.settings.activePollSeconds : self.settings.idlePollSeconds
                )
                try? await Task.sleep(for: .seconds(max(1, delaySeconds)))
            }
        }
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        guard await client.currentConnection() != nil else {
            connectionState = .unconfigured
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            // Refresh project names every 5 minutes (or on first poll)
            if Date().timeIntervalSince(lastProjectsFetch) > 300 || projectsById.isEmpty {
                if let projects = try? await client.listProjects() {
                    projectsById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.title) })
                    lastProjectsFetch = Date()
                }
            }

            var threads = try await client.listThreads(limit: 40)

            // Enrich active threads (cap at 10 concurrent reads) with latest step & pending requests
            let activeIndices = threads.indices.filter { threads[$0].status.isActive }.prefix(10)
            if !activeIndices.isEmpty {
                let activeIds = activeIndices.map { ($0, threads[$0].threadId) }
                let enrichedResults = await withTaskGroup(of: (Int, ThreadReadPayload?).self) { group in
                    for (idx, tid) in activeIds {
                        group.addTask { [client] in
                            let detail = try? await client.readThreadActivity(threadId: tid, limit: 4)
                            return (idx, detail)
                        }
                    }
                    var collected: [(Int, ThreadReadPayload?)] = []
                    for await pair in group {
                        collected.append(pair)
                    }
                    return collected
                }

                for (idx, payload) in enrichedResults {
                    guard let payload else { continue }
                    if let pending = payload.thread?.pendingRequestCount {
                        threads[idx].pendingRequestCount = pending
                    }
                    if let runStart = payload.recentRuns?.first?.startedAt {
                        threads[idx].activeRunStartedAt = ISO8601DateParser.parse(runStart)
                    }
                    threads[idx].latestStepText = Self.extractProgressSummary(from: payload.items ?? [])
                }
            }

            // Load answerable pending user questions for waiting / attention threads (cap at 5)
            let attentionIndices = threads.indices.filter { threads[$0].needsAttention && !threads[$0].archived }.prefix(5)
            if !attentionIndices.isEmpty {
                let attentionTargets = attentionIndices.map { ($0, threads[$0].threadId) }
                let pendingResults = await withTaskGroup(of: (Int, Bool, [PendingUserRequest]).self) { group in
                    for (idx, tid) in attentionTargets {
                        group.addTask { [client] in
                            do {
                                let ids = try await client.listPendingRequests(threadId: tid)
                                var requests: [PendingUserRequest] = []
                                for rid in ids.prefix(3) {
                                    if let detail = try? await client.readPendingRequest(threadId: tid, requestId: rid),
                                       !detail.questions.isEmpty {
                                        requests.append(detail)
                                    }
                                }
                                return (idx, true, requests)
                            } catch {
                                return (idx, false, [])
                            }
                        }
                    }
                    var collected: [(Int, Bool, [PendingUserRequest])] = []
                    for await item in group {
                        collected.append(item)
                    }
                    return collected
                }

                for (idx, didCheck, requests) in pendingResults {
                    threads[idx].didCheckPendingQuestions = didCheck
                    threads[idx].pendingUserRequests = requests
                }
            }

            processNotificationsIfNeeded(newThreads: threads)
            self.allThreads = threads
            self.connectionState = .connected(lastUpdated: Date())
        } catch {
            self.connectionState = .error(error.localizedDescription)
        }
    }

    // MARK: - Actions

    func openInT3Code(_ thread: T3Thread) {
        if let url = thread.deepLinkURL {
            NSWorkspace.shared.open(url)
            return
        }
        // Fallback: activate T3 Code app directly
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "codes.t3.desktop")
            ?? ["/Applications/T3 Code (Beta).app", "/Applications/T3 Code.app"]
                .map(URL.init(fileURLWithPath:))
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func stopAgent(_ thread: T3Thread) {
        guard !stoppingThreadIds.contains(thread.threadId) else { return }
        stoppingThreadIds.insert(thread.threadId)
        actionBanner = nil

        Task {
            do {
                try await client.stopThread(thread)
                stoppingThreadIds.remove(thread.threadId)
                await refreshNow()
            } catch {
                stoppingThreadIds.remove(thread.threadId)
                let msg = error.localizedDescription
                if msg.localizedCaseInsensitiveContains("scope")
                    || msg.localizedCaseInsensitiveContains("permission")
                    || msg.localizedCaseInsensitiveContains("read")
                    || msg.localizedCaseInsensitiveContains("forbidden") {
                    actionBanner = "Read-only connection — grant control scope in T3 Code to stop agents."
                } else {
                    actionBanner = "Could not stop agent: \(msg)"
                }
            }
        }
    }

    func respondToPendingRequest(thread: T3Thread, request: PendingUserRequest, answers: [String: String]) {
        guard !respondingRequestIds.contains(request.requestId) else { return }
        respondingRequestIds.insert(request.requestId)
        actionBanner = nil

        Task {
            do {
                try await client.respondToPendingRequest(
                    threadId: thread.threadId,
                    requestId: request.requestId,
                    answers: answers
                )
                respondingRequestIds.remove(request.requestId)
                // Optimistically remove the answered question for instant feedback
                if let idx = allThreads.firstIndex(where: { $0.threadId == thread.threadId }) {
                    allThreads[idx].pendingUserRequests.removeAll { $0.requestId == request.requestId }
                    if allThreads[idx].pendingRequestCount > 0 {
                        allThreads[idx].pendingRequestCount -= 1
                    }
                }
                await refreshNow()
            } catch {
                respondingRequestIds.remove(request.requestId)
                let msg = error.localizedDescription
                if msg.localizedCaseInsensitiveContains("scope")
                    || msg.localizedCaseInsensitiveContains("read")
                    || msg.localizedCaseInsensitiveContains("forbidden") {
                    actionBanner = "Read-only connection — grant control scope in T3 Code to answer questions."
                } else if msg.localizedCaseInsensitiveContains("not found") {
                    actionBanner = "Question was already answered or closed in T3 Code."
                    await refreshNow()
                } else {
                    actionBanner = "Could not send answer: \(msg)"
                }
            }
        }
    }

    // MARK: - Helpers

    private func processNotificationsIfNeeded(newThreads: [T3Thread]) {
        defer {
            previousSnapshot = Dictionary(
                uniqueKeysWithValues: newThreads.map { ($0.threadId, ($0.status, $0.pendingRequestCount)) }
            )
            hasCompletedInitialPoll = true
        }

        guard hasCompletedInitialPoll, notificationsEnabled else { return }

        for thread in newThreads {
            guard let prev = previousSnapshot[thread.threadId] else { continue }

            // Transition: active -> completed
            if settings.notifyOnCompleted && prev.status.isActive && thread.status == .completed {
                NotificationService.shared.notify(
                    title: "Agent finished",
                    body: thread.title,
                    threadURL: thread.deepLinkURL
                )
            }
            // Transition: active -> failed
            else if settings.notifyOnFailed && prev.status.isActive && thread.status == .failed {
                NotificationService.shared.notify(
                    title: "Agent failed",
                    body: thread.title,
                    threadURL: thread.deepLinkURL
                )
            }
            // Transition: new pending question/request or entered waiting state
            else if settings.notifyOnNeedsInput && ((prev.pending == 0 && thread.pendingRequestCount > 0) || (prev.status != .waiting && thread.status == .waiting)) {
                let title: String
                if thread.hasAnswerableQuestions {
                    title = "Question from agent"
                } else if thread.needsPermissionApprovalInT3 {
                    title = "Approval needed in T3 Code"
                } else {
                    title = "Needs your input"
                }
                NotificationService.shared.notify(
                    title: title,
                    body: thread.title,
                    threadURL: thread.deepLinkURL
                )
            }
        }
    }

    func sendTestNotification() {
        NotificationService.shared.setup()
        NotificationService.shared.notify(
            title: "T3Bar Notifications Active",
            body: "You'll be alerted when agents finish, fail, or need input.",
            threadURL: nil
        )
    }

    private static func extractProgressSummary(from items: [RawActivityItem]) -> String? {
        guard !items.isEmpty else { return nil }
        for item in items.reversed() {
            let type = (item.type ?? "").lowercased()
            if type == "user_message" { continue }

            if let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                if item.status == "running" || item.status == "in_progress" {
                    return "\(title)…"
                }
                return title
            }

            if let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let firstLine = text
                    .replacingOccurrences(of: "**", with: "")
                    .components(separatedBy: .newlines)
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? text
                let compact = firstLine.trimmingCharacters(in: .whitespaces)
                if compact.count > 72 {
                    return String(compact.prefix(71)) + "…"
                }
                return compact
            }
        }
        return nil
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Ignore registration failure outside /Applications or unsigned dev runs
        }
    }
}
