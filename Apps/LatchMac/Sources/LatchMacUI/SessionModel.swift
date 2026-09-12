import Foundation
import LatchACP
import LatchAgentCore
import LatchServiceProtocol

@MainActor
final class SessionModel {
    enum Phase { case disconnected, connecting, ready, prompting, stopping }
    private(set) var phase: Phase = .disconnected
    private(set) var status = "Not connected"
    private(set) var messages: [ChatMessage] = []
    var transcript: String { history.transcript }
    private var history = ChatHistory()
    private(set) var errorMessage: String?
    private(set) var cancellationRequested = false
    private(set) var configuration = SessionConfiguration()
    private(set) var isChangingConfiguration = false
    var onChange: (() -> Void)?

    let permissions = PermissionQueue()
    private var sessionID: String?
    private let registry = AgentRuntimeRegistry()
    private let service: LatchAgentService
    private var eventTask: Task<Void, Never>?
    private var runtimeID: AgentRuntimeID?
    private var generation = UUID()
    private var promptGeneration = UUID()
    private var configurationSequence: UInt64 = 0
    private var legacyModelSequence: UInt64 = 0
    private var pendingConfigurationUpdates: [ACPSessionNotification] = []

    init() {
        service = LatchAgentService(registry: registry)
        permissions.onChange = { [weak self] in self?.onChange?() }
        eventTask = Task { [weak self, events = service.events] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
        }
    }

    deinit { eventTask?.cancel() }

    func connect(command: String, workspace: URL?, launchEnvironment: AgentLaunchEnvironment = AgentLaunchEnvironment()) async {
        guard phase == .disconnected else { return }
        errorMessage = nil
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
        history.reset()
        messages = history.messages
        clearConfiguration()
        phase = .connecting
        status = "Connecting…"
        onChange?()
        do {
            let result = try await service.execute(.startRuntime(id: id, profile: ACPCommandProfile(
                executablePath: parsed.executable, arguments: parsed.arguments,
                workingDirectoryPath: workspace.path, environment: parsed.environment
            )))
            guard generation == token else { return }
            let runtime = try await registry.runtime(for: id)
            try await runtime.setPermissionHandler { [weak self] request in
                await self?.requestPermission(request, runtimeID: id) ?? .cancelled
            }
            guard generation == token else { return }
            let session = try await service.execute(.newSession(runtimeID: id, cwd: workspace.path))
            guard generation == token else { return }
            if case let .sessionCreated(_, response) = session {
                sessionID = response.sessionId
                configuration = SessionConfiguration(configOptions: response.configOptions, models: response.models)
                configurationSequence = response.localSequence ?? 0
                legacyModelSequence = response.localSequence ?? 0
                for update in pendingConfigurationUpdates where update.sessionId == sessionID {
                    applyConfigurationUpdate(update)
                }
                pendingConfigurationUpdates.removeAll()
            }
            phase = .ready
            if case let .runtimeStarted(_, initialization) = result {
                status = "Connected · \(initialization.agentInfo?.title ?? initialization.agentInfo?.name ?? "ACP agent")"
            } else { status = "Connected" }
        } catch {
            _ = try? await service.execute(.stopRuntime(id: id))
            guard generation == token else { return }
            runtimeID = nil
            phase = .disconnected
            status = "Not connected"
            errorMessage = error.localizedDescription
        }
        onChange?()
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
                let result = try await service.execute(.setSessionConfigOption(runtimeID: id, configID: configID, value: value))
                guard generation == token else { return }
                if case let .sessionConfigOptionSet(_, response) = result,
                   response.localSequence.map({ $0 > configurationSequence }) ?? true {
                    configuration.apply(configOptions: response.configOptions)
                    configurationSequence = response.localSequence ?? configurationSequence
                }
            case .legacyModel:
                let result = try await service.execute(.setSessionModel(runtimeID: id, modelID: value))
                guard generation == token else { return }
                if case let .sessionModelSet(_, sequence) = result, sequence > legacyModelSequence,
                   configuration.model?.route == .legacyModel {
                    configuration.model?.currentValue = value
                    legacyModelSequence = sequence
                }
            }
        } catch {
            guard generation == token else { return }
            errorMessage = (error as? ACPJSONRPCErrorObject)?.message ?? error.localizedDescription
        }
        isChangingConfiguration = false
        onChange?()
    }

    func send(_ text: String) async {
        guard phase == .ready, !isChangingConfiguration, let id = runtimeID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = generation
        errorMessage = nil
        phase = .prompting
        promptGeneration = UUID()
        cancellationRequested = false
        status = "Working…"
        history.appendUser(text)
        publishHistory()
        do {
            let result = try await service.execute(.prompt(runtimeID: id, text: text))
            guard generation == token else { return }
            if case let .promptCompleted(_, response) = result {
                status = response.stopReason == "cancelled" ? "Cancelled" : "Ready · \(response.stopReason)"
            }
        } catch {
            guard generation == token else { return }
            errorMessage = error.localizedDescription
            status = "Prompt failed"
        }
        phase = .ready
        cancellationRequested = false
        permissions.cancelAll()
        onChange?()
    }

    func cancel() async {
        guard phase == .prompting, !cancellationRequested, let id = runtimeID else { return }
        let token = generation
        cancellationRequested = true
        permissions.cancelAll()
        status = "Cancelling…"
        onChange?()
        do { _ = try await service.execute(.cancelPrompt(runtimeID: id)) }
        catch {
            guard generation == token, phase == .prompting else { return }
            cancellationRequested = false
            errorMessage = error.localizedDescription
            onChange?()
        }
    }

    func disconnect() async {
        guard phase != .stopping else { return }
        generation = UUID()
        runtimeID = nil
        sessionID = nil
        clearConfiguration()
        permissions.cancelAll()
        phase = .stopping
        status = "Stopping…"
        onChange?()
        await service.shutdown()
        phase = .disconnected
        status = "Not connected"
        cancellationRequested = false
        onChange?()
    }

    private func requestPermission(_ request: ACPPermissionRequest, runtimeID: AgentRuntimeID) async -> ACPPermissionOutcome {
        guard self.runtimeID == runtimeID, request.sessionId == sessionID,
              phase == .prompting, !cancellationRequested else { return .cancelled }
        let token = promptGeneration
        let outcome = await permissions.request(request)
        guard self.runtimeID == runtimeID, promptGeneration == token,
              phase == .prompting, !cancellationRequested else { return .cancelled }
        return outcome
    }

    private func receive(_ event: LatchAgentEvent) {
        switch event {
        case let .sessionUpdate(id, notification) where id == runtimeID:
            if phase == .connecting, sessionID == nil, isConfigurationUpdate(notification) {
                // The event task may run before session/new's continuation. Keep a bounded
                // buffer, then replay only this session's snapshots newer than its reply.
                if pendingConfigurationUpdates.count == 32 { pendingConfigurationUpdates.removeFirst() }
                pendingConfigurationUpdates.append(notification)
                return
            }
            guard notification.sessionId == sessionID else { return }
            applyConfigurationUpdate(notification)
            switch notification.event {
            case let .messageChunk(chunk) where chunk.role == .agent:
                if let text = chunk.text {
                    history.appendAssistant(text)
                    publishHistory()
                }
            case let .toolCall(tool, _):
                history.updateTool(toolCallID: tool.toolCallID, title: tool.title, status: tool.status)
                publishHistory()
            default: break
            }
        case .standardError:
            // Process diagnostics belong to service logging, not chat or its history budget.
            break
        case let .processTerminated(id, status) where id == runtimeID:
            generation = UUID()
            runtimeID = nil
            sessionID = nil
            clearConfiguration()
            cancellationRequested = false
            permissions.cancelAll()
            phase = .disconnected
            self.status = "Agent exited (\(status))"
            errorMessage = "The agent process ended. Select the harness again or use Refresh in Settings to reconnect."
            onChange?()
        default: break
        }
    }

    private func clearConfiguration() {
        configuration = SessionConfiguration()
        configurationSequence = 0
        legacyModelSequence = 0
        pendingConfigurationUpdates.removeAll()
        isChangingConfiguration = false
    }

    private func isConfigurationUpdate(_ notification: ACPSessionNotification) -> Bool {
        guard case let .object(update) = notification.update else { return false }
        return update["sessionUpdate"] == .string("config_option_update") || update["sessionUpdate"] == .string("current_model_update")
    }

    private func applyConfigurationUpdate(_ notification: ACPSessionNotification) {
        guard case let .object(update) = notification.update else { return }
        let legacy = update["sessionUpdate"] == .string("current_model_update")
        let lastSequence = legacy ? legacyModelSequence : configurationSequence
        guard notification.localSequence.map({ $0 > lastSequence }) ?? true,
              configuration.apply(update: notification.update) else { return }
        // Replies and notifications travel through different tasks. Compare their trusted
        // ingress positions so a late continuation cannot restore an older snapshot.
        // Legacy model updates are independent of effort-only modern config snapshots.
        if legacy { legacyModelSequence = notification.localSequence ?? lastSequence }
        else { configurationSequence = notification.localSequence ?? lastSequence }
        onChange?()
    }

    private func publishHistory() {
        messages = history.messages
        onChange?()
    }
}
