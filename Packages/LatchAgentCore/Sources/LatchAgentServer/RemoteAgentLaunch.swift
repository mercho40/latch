import Foundation
import LatchAgentCore
import LatchRemoteProtocol
import LatchServiceProtocol

/// A `launchAgent` resolved against the server's own environment. Nothing the client sent
/// reaches the process except the workspace, and that only after it proved to be a folder.
struct RemoteAgentLaunch {
    let agentTitle: String
    /// The workspace on the server, after `~/` expansion.
    let workingDirectory: String
    let profile: ACPCommandProfile

    init(
        agent: LatchRemoteAgent,
        workspace: String,
        environment: AgentLaunchEnvironment,
        homeDirectory: String
    ) throws(LatchRemoteError) {
        workingDirectory = try Self.workingDirectory(for: workspace, homeDirectory: homeDirectory)

        let command: AgentCommand
        let missingExecutable: String
        switch agent {
        case let .preset(rawValue):
            guard let preset = AgentPreset(rawValue: rawValue), let recipe = preset.recipe(in: environment) else {
                throw LatchRemoteError(code: .unknownPreset, message: "This server does not know that agent.")
            }
            if let problem = recipe.problem(in: environment) {
                // A recipe's problem is its setup text unless what is missing is Node.
                throw LatchRemoteError(code: problem == recipe.setup ? .executableNotFound : .nodeMissing, message: problem)
            }
            do {
                command = try AgentCommand(recipe.command)
            } catch {
                throw LatchRemoteError(code: .commandFailed, message: "Agent command failed.")
            }
            agentTitle = preset.title
            missingExecutable = recipe.setup
        case let .custom(line):
            do {
                command = try AgentCommand(line)
            } catch {
                throw LatchRemoteError(code: .invalidRequest, message: error.localizedDescription)
            }
            agentTitle = URL(fileURLWithPath: command.executable).lastPathComponent
            missingExecutable = CommandError.executableNotFound.localizedDescription
        case .unknown:
            throw LatchRemoteError(code: .invalidRequest, message: "An agent is exactly one of preset or custom.")
        }

        let resolved: ResolvedAgentCommand
        do {
            resolved = try environment.resolve(command)
        } catch {
            throw LatchRemoteError(code: .executableNotFound, message: missingExecutable)
        }
        profile = ACPCommandProfile(
            executablePath: resolved.executable,
            arguments: resolved.arguments,
            workingDirectoryPath: workingDirectory,
            environment: resolved.environment
        )
    }

    /// An absolute path, or one under the server user's home written `~/…`, that is a folder.
    /// Messages echo only what the client sent.
    static func workingDirectory(for workspace: String, homeDirectory: String) throws(LatchRemoteError) -> String {
        let path: String
        if workspace.hasPrefix("/") {
            path = workspace
        } else if workspace.hasPrefix("~/") {
            path = URL(fileURLWithPath: homeDirectory).appendingPathComponent(String(workspace.dropFirst(2))).path
        } else {
            throw LatchRemoteError(code: .workspaceNotFound, message: "Use an absolute workspace path or one starting with ~/.")
        }
        var isDirectory: ObjCBool = false
        guard !path.contains("\0"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LatchRemoteError(code: .workspaceNotFound, message: "There is no folder at \(workspace) on the server.")
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
