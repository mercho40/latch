import Foundation

struct ResolvedAgentCommand {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
}

/// Filesystem-only discovery. Never consults the working directory or a shell.
struct AgentLaunchEnvironment {
    let environment: [String: String]
    let searchDirectories: [String]
    private let home: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
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
            for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
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
        self.environment = childEnvironment
    }

    func executable(named name: String) -> String? {
        guard !name.isEmpty, !name.contains("\0") else { return nil }
        let candidates: [String]
        if name.hasPrefix("/") {
            candidates = [name]
        } else if name.hasPrefix("~/") {
            candidates = [home.appendingPathComponent(String(name.dropFirst(2))).path]
        } else if name.contains("/") {
            return nil
        } else {
            candidates = searchDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
        }
        return candidates.first(where: Self.isExecutableFile)
    }

    func resolve(_ command: AgentCommand) throws -> ResolvedAgentCommand {
        guard let executable = executable(named: command.executable) else {
            throw CommandError.executableNotFound
        }
        return ResolvedAgentCommand(executable: executable, arguments: command.arguments, environment: environment)
    }

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
