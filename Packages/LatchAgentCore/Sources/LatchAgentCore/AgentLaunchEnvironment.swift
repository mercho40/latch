import Foundation

public struct ResolvedAgentCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
}

/// Filesystem-only discovery. Never consults the working directory or a shell.
public struct AgentLaunchEnvironment: Sendable {
    let environment: [String: String]
    let searchDirectories: [String]
    private let home: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = AgentLaunchEnvironment.defaultHome,
        includeCommonLocations: Bool = true
    ) {
        self.home = home
        var directories: [String] = []
        var seen = Set<String>()
        func append(_ path: String) {
            // A colon cannot be represented as part of a directory in PATH.
            guard path.hasPrefix("/"), !path.contains(":"), !path.contains("\0") else { return }
            let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(absolute).inserted { directories.append(absolute) }
        }
        for path in (environment["PATH"] ?? "").components(separatedBy: ":") {
            append(path)
        }
        if includeCommonLocations {
            for path in [".local/bin", ".fx/bin", ".opencode/bin", ".bun/bin", ".npm-global/bin", ".volta/bin"] {
                append(home.appendingPathComponent(path).path)
            }
            for path in Self.systemDirectories {
                append(path)
            }

            var fnmRoots = [String]()
            if let root = environment["FNM_DIR"], root.hasPrefix("/") { fnmRoots.append(root) }
            fnmRoots += [".local/share/fnm", "Library/Application Support/fnm", ".fnm"].map {
                home.appendingPathComponent($0).path
            }
            for root in fnmRoots {
                let rootURL = URL(fileURLWithPath: root)
                let defaultBin = rootURL.appendingPathComponent("aliases/default/installation/bin").path
                if Self.isDirectory(defaultBin) { append(defaultBin) }
                for bin in Self.versionBins(root: rootURL.appendingPathComponent("node-versions"), suffix: "installation/bin") {
                    append(bin)
                }
            }
            var nvmRoots = [String]()
            if let root = environment["NVM_DIR"], root.hasPrefix("/") { nvmRoots.append(root) }
            nvmRoots.append(home.appendingPathComponent(".nvm").path)
            for root in nvmRoots {
                for bin in Self.versionBins(root: URL(fileURLWithPath: root).appendingPathComponent("versions/node"), suffix: "bin") {
                    append(bin)
                }
            }
        }
        searchDirectories = directories
        var childEnvironment = environment
        childEnvironment["PATH"] = directories.joined(separator: ":")
        // The Claude Code ACP adapter runs the Claude Code it bundles, which trails the user's
        // own by however long ago the adapter was pinned and lacks the models released since,
        // unless CLAUDE_CODE_EXECUTABLE names another. Name the user's, unless they named one.
        if childEnvironment["CLAUDE_CODE_EXECUTABLE"] == nil, let claude = Self.executable(named: "claude", in: directories) {
            childEnvironment["CLAUDE_CODE_EXECUTABLE"] = claude
        }
        self.environment = childEnvironment
    }

    /// iOS runs no agents and has no home of its own, only the app's container, which it
    /// stands in for so presets still describe themselves there.
    @usableFromInline static var defaultHome: URL {
        #if os(iOS)
        URL(fileURLWithPath: NSHomeDirectory())
        #else
        FileManager.default.homeDirectoryForCurrentUser
        #endif
    }

    public func executable(named name: String) -> String? {
        guard !name.isEmpty, !name.contains("\0") else { return nil }
        if name.hasPrefix("/") {
            return Self.isExecutableFile(name) ? name : nil
        } else if name.hasPrefix("~/") {
            let path = home.appendingPathComponent(String(name.dropFirst(2))).path
            return Self.isExecutableFile(path) ? path : nil
        } else if name.contains("/") {
            return nil
        }
        return Self.executable(named: name, in: searchDirectories)
    }

    /// The first executable file called `name`, a bare name, in `directories`.
    private static func executable(named name: String, in directories: [String]) -> String? {
        directories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }.first(where: isExecutableFile)
    }

    public func resolve(_ command: AgentCommand) throws -> ResolvedAgentCommand {
        guard let executable = executable(named: command.executable) else {
            throw CommandError.executableNotFound
        }
        return ResolvedAgentCommand(executable: executable, arguments: command.arguments, environment: environment)
    }

    #if os(Linux)
    // Homebrew ahead of the system directories, as on macOS; snaps after them.
    private static let systemDirectories = [
        "/home/linuxbrew/.linuxbrew/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        "/snap/bin",
    ]
    #else
    private static let systemDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    #endif

    private static func isExecutableFile(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: target)
        return attributes?[.type] as? FileAttributeType == .typeRegular
            && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// One directory listing per known root, followed by fixed-depth bin checks.
    private static func versionBins(root: URL, suffix: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { name in
            guard name.first == "v" else { return false }
            let components = name.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
            return !components.isEmpty && components.allSatisfy {
                !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" }
            }
        }.sorted {
            let order = $0.compare($1, options: .numeric)
            return order == .orderedSame ? $0 > $1 : order == .orderedDescending
        }.map { root.appendingPathComponent($0).appendingPathComponent(suffix).path }
            .filter(isDirectory)
    }
}
