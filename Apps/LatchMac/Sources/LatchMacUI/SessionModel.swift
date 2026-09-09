import Foundation
import LatchACP
import LatchAgentCore
import LatchServiceProtocol

@MainActor
final class SessionModel {
    enum Phase { case disconnected, connecting, ready, prompting, stopping }
    private(set) var phase: Phase = .disconnected
    private(set) var status = "Not connected"
    private(set) var transcript = ""
    private(set) var errorMessage: String?
    private(set) var cancellationRequested = false
    var onChange: (() -> Void)?

    let permissions = PermissionQueue()
    private var sessionID: String?
    private let registry = AgentRuntimeRegistry()
    private let service: LatchAgentService
    private var eventTask: Task<Void, Never>?
    private var runtimeID: AgentRuntimeID?
    private var generation = UUID()
    private var promptGeneration = UUID()
    private var messageRole: String?

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

    func connect(command: String, workspace: URL?) async {
        guard phase == .disconnected else { return }
        errorMessage = nil
        let parsed: AgentCommand
        do {
            parsed = try AgentCommand(command)
            guard FileManager.default.isExecutableFile(atPath: parsed.executable) else {
                throw CommandError.executableNotFound
            }
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
        transcript = ""
        messageRole = nil
        phase = .connecting
        status = "Connecting…"
        onChange?()
        do {
            let result = try await service.execute(.startRuntime(id: id, profile: ACPCommandProfile(
                executablePath: parsed.executable, arguments: parsed.arguments,
                workingDirectoryPath: workspace.path
            )))
            guard generation == token else { return }
            let runtime = try await registry.runtime(for: id)
            try await runtime.setPermissionHandler { [weak self] request in
                await self?.requestPermission(request, runtimeID: id) ?? .cancelled
            }
            guard generation == token else { return }
            let session = try await service.execute(.newSession(runtimeID: id, cwd: workspace.path))
            guard generation == token else { return }
            if case let .sessionCreated(_, response) = session { sessionID = response.sessionId }
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

    func send(_ text: String) async {
        guard phase == .ready, let id = runtimeID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = generation
        errorMessage = nil
        phase = .prompting
        promptGeneration = UUID()
        cancellationRequested = false
        status = "Working…"
        append(text, role: "You", newMessage: true)
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
            switch notification.event {
            case let .messageChunk(chunk) where chunk.role == .agent:
                if let text = chunk.text { append(text, role: "Agent") }
            case let .toolCall(tool, _):
                append("\(tool.title ?? tool.toolCallID) · \(tool.status ?? "updated")", role: "Tool", newMessage: true)
            default: break
            }
        case let .standardError(id, data) where id == runtimeID:
            append(String(decoding: data, as: UTF8.self), role: "Agent diagnostics")
        case let .processTerminated(id, status) where id == runtimeID:
            generation = UUID()
            runtimeID = nil
            sessionID = nil
            cancellationRequested = false
            permissions.cancelAll()
            phase = .disconnected
            self.status = "Agent exited (\(status))"
            errorMessage = "The agent process ended. Connect again to start a new session."
            onChange?()
        default: break
        }
    }

    private func append(_ text: String, role: String, newMessage: Bool = false) {
        if role != messageRole || newMessage {
            transcript += (transcript.isEmpty ? "" : "\n\n") + "\(role)\n"
            messageRole = role
        }
        transcript += text
        // Bound the preview's visible history. There is no persistence or replay yet.
        if transcript.count > 200_000 { transcript = String(transcript.suffix(160_000)) }
        onChange?()
    }
}
