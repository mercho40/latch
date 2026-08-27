import Darwin
import Foundation
import LatchACP

@main
struct LatchACPProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("LatchACPProbe: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let invocation = try parseArguments(Array(CommandLine.arguments.dropFirst()))
        let workingDirectory = FileManager.default.currentDirectoryPath
        let configuration = ACPProcessConfiguration(
            executableURL: URL(fileURLWithPath: invocation.command),
            arguments: invocation.arguments,
            workingDirectoryURL: URL(fileURLWithPath: workingDirectory)
        )
        let runtime = ACPAgentRuntime(
            configuration: configuration,
            clientInfo: ACPImplementation(
                name: "latch-acp-probe",
                title: "Latch ACP Probe",
                version: "0.1.0"
            )
        )
        let errorTask = Task {
            for await data in runtime.standardError {
                FileHandle.standardError.write(data)
            }
        }

        do {
            let initialized = try await runtime.start()
            print("initialized protocol=\(initialized.protocolVersion) agent=\(initialized.agentInfo?.name ?? "unknown")")
            print("capabilities loadSession=\(initialized.agentCapabilities.loadSession)")

            if let prompt = invocation.prompt {
                try await runtime.setPermissionHandler { request in
                    print("permission requested tool=\(toolTitle(request.toolCall) ?? "unknown")")
                    if let reject = request.options.first(where: { $0.kind.hasPrefix("reject") }) {
                        return .selected(optionID: reject.optionId)
                    }
                    return .cancelled
                }
                let session = try await runtime.newSession(cwd: workingDirectory)
                print("session id=\(session.sessionId)")

                print("assistant> ", terminator: "")
                fflush(stdout)
                let updateTask = Task {
                    for await notification in runtime.sessionUpdates {
                        render(notification.event)
                    }
                }
                let cancelTask = invocation.cancelAfterMilliseconds.map { delay in
                    Task {
                        try? await Task.sleep(for: .milliseconds(delay))
                        guard !Task.isCancelled else { return }
                        do {
                            try await runtime.cancelPrompt()
                            print("\n[cancel requested]")
                        } catch {
                            FileHandle.standardError.write(Data("cancel failed: \(error)\n".utf8))
                        }
                    }
                }
                let response = try await runtime.prompt(prompt)
                cancelTask?.cancel()
                _ = await cancelTask?.result
                print("\ncompleted stopReason=\(response.stopReason)")
                updateTask.cancel()
                _ = await updateTask.result
            }
        } catch {
            await runtime.stop()
            errorTask.cancel()
            _ = await errorTask.result
            throw error
        }

        await runtime.stop()
        _ = await errorTask.result
    }

    private static func parseArguments(_ arguments: [String]) throws -> Invocation {
        guard !arguments.isEmpty else { throw ProbeError.invalidArguments }

        if arguments.first?.hasPrefix("--") != true {
            return Invocation(
                command: arguments[0],
                arguments: Array(arguments.dropFirst()),
                prompt: nil,
                cancelAfterMilliseconds: nil
            )
        }

        guard let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count else {
            throw ProbeError.invalidArguments
        }
        var prompt: String?
        var cancelAfterMilliseconds: Int?
        var index = 0
        while index < separator {
            guard index + 1 < separator else { throw ProbeError.invalidArguments }
            switch arguments[index] {
            case "--prompt":
                prompt = arguments[index + 1]
            case "--cancel-after-ms":
                guard let delay = Int(arguments[index + 1]), delay > 0 else {
                    throw ProbeError.invalidArguments
                }
                cancelAfterMilliseconds = delay
            default:
                throw ProbeError.invalidArguments
            }
            index += 2
        }
        guard prompt != nil || cancelAfterMilliseconds == nil else {
            throw ProbeError.invalidArguments
        }
        return Invocation(
            command: arguments[separator + 1],
            arguments: Array(arguments.dropFirst(separator + 2)),
            prompt: prompt,
            cancelAfterMilliseconds: cancelAfterMilliseconds
        )
    }

    private static func render(_ event: ACPSessionEvent) {
        switch event {
        case let .messageChunk(chunk) where chunk.role == .agent:
            guard let text = chunk.text else { return }
            print(text, terminator: "")
            fflush(stdout)
        case let .messageChunk(chunk):
            if let text = chunk.text {
                print("\n[\(chunk.role.rawValue)] \(text)")
            }
        case let .toolCall(tool, initial):
            let phase = initial ? "tool" : "tool update"
            let title = tool.title.map { " \($0)" } ?? ""
            let status = tool.status.map { " status=\($0)" } ?? ""
            print("\n[\(phase) \(tool.toolCallID)]\(title)\(status)")
        case .plan:
            print("\n[plan updated]")
        case .usage:
            break
        case let .other(kind, _):
            print("\n[update \(kind ?? "unknown")]")
        }
    }

    private static func toolTitle(_ toolCall: ACPJSONValue) -> String? {
        guard
            case let .object(object) = toolCall,
            case let .string(title)? = object["title"]
        else {
            return nil
        }
        return title
    }

    struct Invocation {
        let command: String
        let arguments: [String]
        let prompt: String?
        let cancelAfterMilliseconds: Int?
    }

    enum ProbeError: Error, CustomStringConvertible {
        case invalidArguments

        var description: String {
            "usage: LatchACPProbe [--prompt <text> [--cancel-after-ms <milliseconds>] --] <absolute-acp-command> [arguments...]"
        }
    }
}
