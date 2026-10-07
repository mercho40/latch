import Foundation
import LatchRemoteProtocol

/// `latch-server runtimes`' table, and what its failures mean.
enum RuntimeTable {
    /// One row per agent, in the order the server lists them, in aligned columns.
    static func render(_ summaries: [LatchRemoteRuntimeSummary], homeDirectory: String) -> String {
        let rows = [["ID", "STATE", "AGENT", "WORKSPACE", "TITLE"]] + summaries.map { summary in
            [summary.runtimeID.rawValue, state(of: summary), summary.agentTitle,
             abbreviated(summary.workspace, homeDirectory: homeDirectory), summary.title ?? ""]
        }
        let widths = (0..<4).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            (0..<4).map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
                + "  " + row[4]
        }.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")
    }

    /// What the agent is doing, from the user's side: waiting for an answer comes first.
    static func state(of summary: LatchRemoteRuntimeSummary) -> String {
        switch summary.lifecycle {
        case .starting: return "starting"
        case .exited: return "exited"
        default:
            if summary.pendingPermissionCount > 0 { return "waiting for you" }
            return summary.activeTurnID == nil ? "idle" : "working"
        }
    }

    static func describe(_ failure: ServerLocalClient.Failure, at address: ServerSocketAddress, configDirectory: String) -> String {
        switch failure {
        case .nothingListening: "nothing listens at \(address): start latch-server, or pass the --listen address it serves on"
        case let .unreachable(reason): "\(address) cannot be reached: \(reason)"
        case .rejected(.unauthorized): "the latch-server at \(address) refuses the token in \(configDirectory): it reads another config directory"
        case .rejected: "the latch-server at \(address) refused the connection; `latch-server doctor` says why"
        case .notLatch: "something other than latch-server listens at \(address)"
        case .closed: "the latch-server at \(address) closed the connection"
        }
    }

    private static func abbreviated(_ path: String, homeDirectory: String) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
