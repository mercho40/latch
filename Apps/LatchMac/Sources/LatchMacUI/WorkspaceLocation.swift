import Foundation

/// Where a session's agent works: a folder on this Mac, or a path on a server from Settings.
/// Code that needs a real folder asks for `localURL`, so a remote session can never reach
/// the Finder, Terminal or a local launch by accident.
enum WorkspaceLocation: Hashable {
    case local(URL)
    case remote(serverID: UUID, path: String)

    init(_ saved: SavedSession) {
        if let serverID = saved.serverID {
            self = .remote(serverID: serverID, path: saved.workspacePath)
        } else {
            self = .local(URL(fileURLWithPath: saved.workspacePath))
        }
    }

    /// The folder on this Mac. Nil for a remote session.
    var localURL: URL? {
        guard case let .local(url) = self else { return nil }
        return url
    }

    var serverID: UUID? {
        guard case let .remote(serverID, _) = self else { return nil }
        return serverID
    }

    var isRemote: Bool { serverID != nil }

    /// The path as it is saved and copied: a file path here, or the server's own path there.
    var path: String {
        switch self {
        case let .local(url): url.path
        case let .remote(_, path): path
        }
    }

    /// The folder's own name, for headings and group rows.
    var folderName: String {
        switch self {
        case let .local(url): return url.lastPathComponent
        case let .remote(_, path):
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        }
    }

    /// Two sessions share a sidebar group only when this matches: the same folder on this
    /// Mac, or the same path on the same server. A server path is never compared with a
    /// local one, even when the strings agree.
    var groupKey: WorkspaceLocation {
        switch self {
        case let .local(url): .local(url.standardizedFileURL)
        case .remote: self
        }
    }
}
