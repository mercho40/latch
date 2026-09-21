import Foundation
import LatchACP
import LatchAgentCore
import LatchServiceProtocol

@MainActor
final class SessionModel {
    enum Phase { case disconnected, connecting, ready, prompting, stopping }
    private(set) var phase: Phase = .disconnected
    private(set) var status = "Not connected"
    // Read a snapshot on demand rather than retaining a second array/String copy
    // that forces history's next streaming append to copy its growing response.
    var messages: [ChatMessage] { history.messages }
    var transcript: String { history.transcript }
    private var history = ChatHistory()
    private(set) var errorMessage: String?
    static let idleSavedStatus = "Saved · Not connected"
    private(set) var cancellationRequested = false
    private(set) var configuration = SessionConfiguration()
    private(set) var isChangingConfiguration = false
    /// State changes (including permissions) are delivered immediately.
    var onChange: (() -> Void)?
    /// History is already current; consumers may coalesce its rendering only.
    var onTranscriptChange: (() -> Void)?
    var serviceTransportDescription: String { client.transportDescription }

    let permissions = PermissionQueue()
    private var sessionID: String?
    /// Agent-owned context identity survives runtime teardown. Never persist a runtime ID.
    private(set) var savedAgentSessionID: String?
    /// History restored without the agent's session ID. It can be read, never continued: there is
    /// no context to resume, and prompting a fresh agent under an old transcript would misrepresent it.
    private(set) var archivedWithoutContext = false
    private var loadedThroughSequence: UInt64?

    func restore(messages: [ChatMessage], agentSessionID: String?) {
        guard phase == .disconnected else { return }
        history.restore(messages)
        savedAgentSessionID = agentSessionID
        archivedWithoutContext = agentSessionID == nil && !messages.isEmpty
        status = Self.idleSavedStatus
        onChange?()
    }
    private var client: AgentServiceClient
    private let makeClient: @MainActor () -> AgentServiceClient
    private var eventTask: Task<Void, Never>?
    /// Brokered permission decisions in flight, keyed by the service's request ID.
    private var permissionTasks: [UUID: Task<Void, Never>] = [:]
    private var runtimeID: AgentRuntimeID?
    private var generation = UUID()
    private var promptGeneration = UUID()
    private var authenticationStop: (token: UUID, task: Task<Void, Never>)?
    private var configurationSequence: UInt64 = 0
    private var legacyModelSequence: UInt64 = 0
    private var legacyModeSequence: UInt64 = 0
    private var pendingConfigurationUpdates: [ACPSessionNotification] = []

    init(makeClient: @escaping @MainActor () -> AgentServiceClient = AgentServiceClients.makeDefault) {
        self.makeClient = makeClient
        client = makeClient()
        permissions.onChange = { [weak self] in self?.onChange?() }
        startEventTask()
    }

    deinit {
        eventTask?.cancel()
        permissionTasks.values.forEach { $0.cancel() }
        client.close()
    }

    private func startEventTask() {
        eventTask?.cancel()
        eventTask = Task { [weak self, events = client.events] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
            guard !Task.isCancelled else { return }
            self?.serviceConnectionLost()
        }
    }

    /// The service channel ended (XPC interruption or invalidation). Any runtime it owned is
    /// unreachable now; present that like an agent exit and open a fresh channel for next time.
    private func serviceConnectionLost() {
        client.close()
        client = makeClient()
        startEventTask()
        guard phase != .disconnected else { return }
        resetAfterLoss(status: "Agent service disconnected",
                       error: "Lost the connection to the Latch agent service. Select the agent again to reconnect.")
    }

    private func resetAfterLoss(status: String, error: String) {
        generation = UUID()
        runtimeID = nil
        sessionID = nil
        clearConfiguration()
        cancellationRequested = false
        permissions.cancelAll()
        permissionTasks.values.forEach { $0.cancel() }
        permissionTasks.removeAll()
        phase = .disconnected
        self.status = status
        errorMessage = error
        onChange?()
    }

    func connect(command: String, workspace: URL?, launchEnvironment: AgentLaunchEnvironment = AgentLaunchEnvironment(), startNewSession: Bool = false) async {
        guard phase == .disconnected else { return }
        errorMessage = nil
        if !startNewSession, archivedWithoutContext {
            // Not a failure: nothing was attempted, so there is nothing to retry.
            status = "Saved · Read only"
            onChange?()
            return
        }
        let parsed: ResolvedAgentCommand
        do {
            parsed = try launchEnvironment.resolve(AgentCommand(command))
            var isDirectory: ObjCBool = false
            guard let workspace, workspace.isFileURL,
                  FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw CommandError.workspaceRequired }
        } catch {
            errorMessage = error.localizedDescription
            onChange?()
            return
        }
        guard let workspace else { return }
        let token = UUID()
        generation = token
        let id = AgentRuntimeID(token.uuidString)
        runtimeID = id
        if startNewSession {
            savedAgentSessionID = nil
            archivedWithoutContext = false
        }
        let resumingID = savedAgentSessionID
        if resumingID == nil { history.reset() }
        else { history.restore(messages) }
        sessionID = resumingID
        loadedThroughSequence = nil
        clearConfiguration()
        phase = .connecting
        status = resumingID == nil ? "Connecting…" : "Resuming…"
        onChange?()
        do {
            let result = try await client.execute(.startRuntime(id: id, profile: ACPCommandProfile(
                executablePath: parsed.executable, arguments: parsed.arguments,
                workingDirectoryPath: workspace.path, environment: parsed.environment
            )))
            // Superseded while starting: the service may outlive this session, so release the runtime.
            guard generation == token else { _ = try? await client.execute(.stopRuntime(id: id)); return }
            let sequence: UInt64?
            if let resumingID {
                guard case let .runtimeStarted(_, initialization) = result,
                      initialization.agentCapabilities.loadSession else {
                    throw ResumeError.unsupported
                }
                let session = try await client.execute(.loadSession(runtimeID: id, sessionID: resumingID, cwd: workspace.path))
                guard generation == token else { _ = try? await client.execute(.stopRuntime(id: id)); return }
                guard case let .sessionLoaded(_, response) = session else { throw ResumeError.invalidResponse }
                configuration = SessionConfiguration(configOptions: response.configOptions, models: response.models, modes: response.modes)
                sequence = response.localSequence
                loadedThroughSequence = sequence
            } else {
                let session = try await client.execute(.newSession(runtimeID: id, cwd: workspace.path))
                guard generation == token else { _ = try? await client.execute(.stopRuntime(id: id)); return }
                guard case let .sessionCreated(_, response) = session else { throw ResumeError.invalidResponse }
                sessionID = response.sessionId
                savedAgentSessionID = response.sessionId
                configuration = SessionConfiguration(configOptions: response.configOptions, models: response.models, modes: response.modes)
                sequence = response.localSequence
            }
            configurationSequence = sequence ?? 0
            legacyModelSequence = sequence ?? 0
            legacyModeSequence = sequence ?? 0
            for update in pendingConfigurationUpdates where update.sessionId == sessionID {
                applyConfigurationUpdate(update)
            }
            pendingConfigurationUpdates.removeAll()
            phase = .ready
            if case let .runtimeStarted(_, initialization) = result {
                status = "Connected · \(initialization.agentInfo?.title ?? initialization.agentInfo?.name ?? "ACP agent")"
            } else { status = "Connected" }
        } catch {
            _ = try? await client.execute(.stopRuntime(id: id))
            guard generation == token else { return }
            runtimeID = nil
            sessionID = nil
            clearConfiguration()
            phase = .disconnected
            status = resumingID == nil ? "Not connected" : "Saved · Resume failed"
            errorMessage = resumingID == nil ? error.localizedDescription
                : "\(error.localizedDescription) Saved history is unchanged. Retry, or create a new session."
        }
        onChange?()
    }

    private enum ResumeError: LocalizedError {
        case unsupported, invalidResponse
        var errorDescription: String? {
            switch self {
            case .unsupported: "This agent does not support resuming saved sessions."
            case .invalidResponse: "The agent returned an unexpected session response."
            }
        }
    }

    /// Only offered values may be sent, and one change must finish before another prompt or change.
    /// Keep the confirmed selection until the agent acknowledges; errors leave it unchanged.
    func select(_ kind: SessionPicker.Kind, value: String) async {
        guard phase == .ready, !isChangingConfiguration, let id = runtimeID,
              let picker = configuration[kind], value != picker.currentValue,
              picker.choices.contains(where: { $0.value == value }) else { return }
        let token = generation
        isChangingConfiguration = true
        errorMessage = nil
        onChange?()
        do {
            switch picker.route {
            case let .config(configID):
                let result = try await client.execute(.setSessionConfigOption(runtimeID: id, configID: configID, value: value))
                guard generation == token else { return }
                if case let .sessionConfigOptionSet(_, response) = result,
                   response.localSequence.map({ $0 > configurationSequence }) ?? true {
                    configuration.apply(configOptions: response.configOptions)
                    configurationSequence = response.localSequence ?? configurationSequence
                }
            case .legacyModel:
                let result = try await client.execute(.setSessionModel(runtimeID: id, modelID: value))
                guard generation == token else { return }
                if case let .sessionModelSet(_, sequence) = result, sequence > legacyModelSequence,
                   configuration.model?.route == .legacyModel {
                    configuration.model?.currentValue = value
                    legacyModelSequence = sequence
                }
            case .legacyMode:
                let result = try await client.execute(.setSessionMode(runtimeID: id, modeID: value))
                guard generation == token else { return }
                if case let .sessionModeSet(_, sequence) = result, sequence > legacyModeSequence,
                   configuration.permissionMode?.route == .legacyMode {
                    configuration.permissionMode?.currentValue = value
                    legacyModeSequence = sequence
                }
            }
        } catch {
            guard generation == token else { return }
            if await handleAuthenticationFailure(error) { return }
            errorMessage = error.localizedDescription
        }
        isChangingConfiguration = false
        onChange?()
    }

    func send(_ text: String) async {
        guard phase == .ready, !isChangingConfiguration, let id = runtimeID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = generation
        // A prompt is user-initiated work that must keep streaming while Latch is in the
        // background; App Nap would otherwise throttle the app that renders it. The Mac is
        // still allowed to sleep on its own schedule.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Agent prompt in flight")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        errorMessage = nil
        phase = .prompting
        promptGeneration = UUID()
        cancellationRequested = false
        status = "Working…"
        history.appendUser(text)
        publishHistory()
        onChange?()
        do {
            let result = try await client.execute(.prompt(runtimeID: id, text: text))
            guard generation == token else { return }
            if case let .promptCompleted(_, response) = result {
                status = response.stopReason == "cancelled" ? "Cancelled" : "Ready · \(response.stopReason)"
            }
        } catch {
            guard generation == token else { return }
            if await handleAuthenticationFailure(error) { return }
            errorMessage = error.localizedDescription
            status = "Prompt failed"
        }
        phase = .ready
        cancellationRequested = false
        permissions.cancelAll()
        onChange?()
    }

    /// An SDK can cache its account for the life of a session. Never keep a rejected
    /// authenticated session ready, or reselecting its harness would reuse that stale state.
    private func handleAuthenticationFailure(_ error: any Error) async -> Bool {
        let requiresAuthentication = (error as? ACPJSONRPCErrorObject)?.code == -32000
            || (error as? LatchAgentFailure)?.code == .authenticationRequired
        guard requiresAuthentication else { return false }
        let token = UUID()
        generation = token
        let id = runtimeID
        runtimeID = nil
        sessionID = nil
        clearConfiguration()
        permissions.cancelAll()
        permissionTasks.values.forEach { $0.cancel() }
        permissionTasks.removeAll()
        cancellationRequested = false
        phase = .stopping
        status = "Sign-in required"
        errorMessage = "\(error.localizedDescription) Sign in with the agent, then try again."
        onChange?()
        let stoppingClient = client
        let stop = Task {
            if let id { _ = try? await stoppingClient.execute(.stopRuntime(id: id)) }
            guard generation == token else { return }
            phase = .disconnected
            onChange?()
        }
        authenticationStop = (token, stop)
        await stop.value
        if authenticationStop?.token == token { authenticationStop = nil }
        return true
    }

    func cancel() async {
        guard phase == .prompting, !cancellationRequested, let id = runtimeID else { return }
        let token = generation
        cancellationRequested = true
        permissions.cancelAll()
        status = "Cancelling…"
        onChange?()
        do { _ = try await client.execute(.cancelPrompt(runtimeID: id)) }
        catch {
            guard generation == token, phase == .prompting else { return }
            cancellationRequested = false
            errorMessage = error.localizedDescription
            onChange?()
        }
    }

    func disconnect() async {
        // Reselect/quit must drain authentication teardown before reconnecting or exiting.
        if let stop = authenticationStop { await stop.task.value }
        guard phase != .stopping else { return }
        generation = UUID()
        let id = runtimeID
        runtimeID = nil
        sessionID = nil
        clearConfiguration()
        permissions.cancelAll()
        phase = .stopping
        status = "Stopping…"
        onChange?()
        // Stop only this session's runtime: the service is shared by every session in the app.
        if let id { _ = try? await client.execute(.stopRuntime(id: id)) }
        phase = .disconnected
        status = "Not connected"
        cancellationRequested = false
        onChange?()
    }

    /// The service holds the agent's request until Latch answers; the decision travels back as a command.
    private func handlePermissionRequest(_ request: ACPPermissionRequest, runtimeID: AgentRuntimeID, requestID: UUID) {
        let token = promptGeneration
        let task = Task { @MainActor [weak self] in
            var outcome = ACPPermissionOutcome.cancelled
            if let self, self.runtimeID == runtimeID, request.sessionId == self.sessionID,
               self.phase == .prompting, !self.cancellationRequested {
                let decided = await self.permissions.request(request)
                if self.runtimeID == runtimeID, self.promptGeneration == token,
                   self.phase == .prompting, !self.cancellationRequested { outcome = decided }
            }
            guard let self, !Task.isCancelled else { return }
            self.permissionTasks[requestID] = nil
            // The service may already have closed it (prompt ended); that failure is expected.
            _ = try? await self.client.execute(.resolvePermission(runtimeID: runtimeID, requestID: requestID, outcome: outcome))
        }
        permissionTasks[requestID] = task
    }

    private func closePermission(requestID: UUID) {
        permissionTasks.removeValue(forKey: requestID)?.cancel()
    }

    private func receive(_ event: LatchAgentEvent) {
        switch event {
        case let .sessionUpdate(id, notification) where id == runtimeID:
            if phase == .connecting, isConfigurationUpdate(notification) {
                // The event task may run before session/new's continuation. Keep a bounded
                // buffer, then replay only this session's snapshots newer than its reply.
                if pendingConfigurationUpdates.count == 32 { pendingConfigurationUpdates.removeFirst() }
                pendingConfigurationUpdates.append(notification)
                return
            }
            guard notification.sessionId == sessionID else { return }
            applyConfigurationUpdate(notification)
            // session/load replays old content. Keep the saved, bounded transcript (and
            // stable message IDs), rather than appending a second copy. The reply's trusted
            // ingress sequence also excludes replay delivered after its continuation.
            guard phase != .connecting,
                  !(loadedThroughSequence.map { boundary in
                      notification.localSequence.map { $0 <= boundary } ?? false
                  } ?? false) else { return }
            switch notification.event {
            case let .messageChunk(chunk) where chunk.role == .agent:
                if let text = chunk.text {
                    history.appendAssistant(text)
                    publishHistory()
                }
            case let .toolCall(tool, _):
                history.updateTool(tool)
                publishHistory()
            default: break
            }
        case .standardError:
            // Process diagnostics belong to service logging, not chat or its history budget.
            break
        case let .permissionRequested(id, requestID, request) where id == runtimeID:
            handlePermissionRequest(request, runtimeID: id, requestID: requestID)
        case let .permissionClosed(id, requestID) where id == runtimeID:
            closePermission(requestID: requestID)
        case let .processTerminated(id, status) where id == runtimeID:
            resetAfterLoss(status: "Agent exited (\(status))",
                           error: "The agent process ended. Select the agent again to reconnect.")
        default: break
        }
    }

    private func clearConfiguration() {
        configuration = SessionConfiguration()
        configurationSequence = 0
        legacyModelSequence = 0
        legacyModeSequence = 0
        pendingConfigurationUpdates.removeAll()
        isChangingConfiguration = false
    }

    private func isConfigurationUpdate(_ notification: ACPSessionNotification) -> Bool {
        guard case let .object(update) = notification.update else { return false }
        return update["sessionUpdate"] == .string("config_option_update") || update["sessionUpdate"] == .string("current_model_update") || update["sessionUpdate"] == .string("current_mode_update")
    }

    private func applyConfigurationUpdate(_ notification: ACPSessionNotification) {
        guard case let .object(update) = notification.update else { return }
        let legacy = update["sessionUpdate"] == .string("current_model_update")
        let mode = update["sessionUpdate"] == .string("current_mode_update")
        let lastSequence = mode ? legacyModeSequence : (legacy ? legacyModelSequence : configurationSequence)
        guard notification.localSequence.map({ $0 > lastSequence }) ?? true,
              configuration.apply(update: notification.update) else { return }
        // Replies and notifications travel through different tasks. Compare their trusted
        // ingress positions so a late continuation cannot restore an older snapshot.
        // Legacy model updates are independent of effort-only modern config snapshots.
        if mode { legacyModeSequence = notification.localSequence ?? lastSequence }
        else if legacy { legacyModelSequence = notification.localSequence ?? lastSequence }
        else { configurationSequence = notification.localSequence ?? lastSequence }
        onChange?()
    }

    private func publishHistory() {
        onTranscriptChange?()
    }
}
