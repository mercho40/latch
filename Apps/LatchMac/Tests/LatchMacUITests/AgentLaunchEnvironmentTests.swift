import Foundation
import XCTest
@testable import LatchMacUI

final class AgentLaunchEnvironmentTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("Latch discovery \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func file(_ relative: String, executable: Bool = true) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Discovery must not execute this file.
        try Data("not a runnable program".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    func testResolvesAbsoluteHomeAndBareNamesPreservingArgumentsAndEnvironment() throws {
        let agent = try file("tools with spaces/my agent")
        let inherited = ["PATH": agent.deletingLastPathComponent().path, "TOKEN": "unchanged", "HOME": "/not/the/injected/home"]
        let launch = AgentLaunchEnvironment(environment: inherited, home: home, includeCommonLocations: false)
        for name in [agent.path, "~/tools with spaces/my agent", "my agent"] {
            let parsed = try AgentCommand(AgentCommand.quotedArgument(name) + " '' 'two words' '$HOME' '|'")
            let resolved = try launch.resolve(parsed)
            XCTAssertEqual(resolved.executable, agent.path)
            XCTAssertEqual(resolved.arguments, ["", "two words", "$HOME", "|"])
            XCTAssertEqual(resolved.environment, inherited)
        }
    }

    func testSanitizesPATHAndKeepsFirstOccurrence() throws {
        let first = try file("first/agent")
        let second = try file("second/agent")
        let a = first.deletingLastPathComponent().path
        let b = second.deletingLastPathComponent().path
        let launch = AgentLaunchEnvironment(environment: ["PATH": ":.:relative:./bin:../bin:~/bin:\(a):\(b):\(a):"], home: home, includeCommonLocations: false)
        XCTAssertEqual(launch.searchDirectories, [a, b])
        XCTAssertEqual(launch.environment["PATH"], "\(a):\(b)")
        XCTAssertEqual(launch.executable(named: "agent"), first.path)
    }

    func testRejectsDirectoriesNonExecutableFilesAndRelativePaths() throws {
        let executable = try file("bin/agent")
        try file("bin/no-permission", executable: false)
        let bin = executable.deletingLastPathComponent()
        let launch = AgentLaunchEnvironment(environment: ["PATH": bin.path], home: home, includeCommonLocations: false)
        for name in [bin.path, "~/bin", "no-permission", "./agent", "bin/agent", "../agent", "", "bad\0name"] {
            XCTAssertNil(launch.executable(named: name), name)
        }
        XCTAssertThrowsError(try launch.resolve(AgentCommand("missing"))) {
            guard case CommandError.executableNotFound = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testEmptyAndRelativePATHNeverSearchWorkingDirectoryOrFallbacks() throws {
        try file(".local/bin/agent")
        // Package.swift exists in swift test's package working directory, but must not be searched.
        for path in ["", ":.:relative:"] {
            let launch = AgentLaunchEnvironment(environment: ["PATH": path], home: home, includeCommonLocations: false)
            XCTAssertEqual(launch.searchDirectories, [])
            XCTAssertEqual(launch.environment["PATH"], "")
            XCTAssertNil(launch.executable(named: "agent"))
            XCTAssertNil(launch.executable(named: "Package.swift"))
        }
    }

    func testFinderFallbacksAndFnmDefaultBeforeNumericVersions() throws {
        let root = home.appendingPathComponent("Library/Application Support/fnm")
        let old = try file("Library/Application Support/fnm/node-versions/v9.11.0/installation/bin/node")
        let newest = try file("Library/Application Support/fnm/node-versions/v22.10.0/installation/bin/node")
        let middle = try file("Library/Application Support/fnm/node-versions/v22.9.0/installation/bin/node")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aliases"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("aliases/default"), withDestinationURL: old.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        let agent = try file(".fx/bin/fx")
        let launch = AgentLaunchEnvironment(environment: ["PATH": "/usr/bin:/bin", "KEEP": "value"], home: home)
        XCTAssertEqual(launch.executable(named: "fx"), agent.path)
        let defaultBin = root.appendingPathComponent("aliases/default/installation/bin").path
        XCTAssertTrue(launch.searchDirectories.contains(defaultBin))
        let versionBins = launch.searchDirectories.filter { $0.hasPrefix(root.path) }
        XCTAssertEqual(versionBins, [defaultBin, newest.deletingLastPathComponent().path, middle.deletingLastPathComponent().path, old.deletingLastPathComponent().path])
        XCTAssertEqual(launch.environment["KEEP"], "value")
        XCTAssertEqual(launch.environment["PATH"], launch.searchDirectories.joined(separator: ":"))
        XCTAssertTrue(launch.searchDirectories.allSatisfy { $0.hasPrefix("/") })
        // Resolve the alias directly, independent of system-installed Node versions.
        XCTAssertNotNil(launch.executable(named: defaultBin + "/node"))
    }

    func testAllManagerRootsAndNumericNvmOrdering() throws {
        let fnmRoots = ["custom fnm", ".local/share/fnm", "Library/Application Support/fnm", ".fnm"]
        let nvmRoots = ["custom nvm", ".nvm"]
        for root in fnmRoots {
            try file(root + "/node-versions/v20.0.0/installation/bin/node")
            try file(root + "/node-versions/not-a-version/installation/bin/node")
            try file(root + "/nested/node-versions/v99.0.0/installation/bin/node")
        }
        for root in nvmRoots {
            for version in ["v9.0.0", "v22.9.0", "v22.10.0"] {
                try file(root + "/versions/node/" + version + "/bin/node")
            }
        }
        let launch = AgentLaunchEnvironment(environment: ["FNM_DIR": home.appendingPathComponent("custom fnm").path, "NVM_DIR": home.appendingPathComponent("custom nvm").path], home: home)
        for root in fnmRoots {
            XCTAssertTrue(launch.searchDirectories.contains(home.appendingPathComponent(root + "/node-versions/v20.0.0/installation/bin").path))
        }
        for root in nvmRoots {
            let prefix = home.appendingPathComponent(root).path + "/"
            XCTAssertEqual(launch.searchDirectories.filter { $0.hasPrefix(prefix) }, ["v22.10.0", "v22.9.0", "v9.0.0"].map { prefix + "versions/node/" + $0 + "/bin" })
        }
        XCTAssertFalse(launch.searchDirectories.contains { $0.contains("not-a-version") || $0.contains("/nested/") })
        let relative = AgentLaunchEnvironment(environment: ["FNM_DIR": "custom fnm", "NVM_DIR": "~/custom nvm"], home: home)
        XCTAssertFalse(relative.searchDirectories.contains { $0.contains("custom fnm") || $0.contains("custom nvm") })
    }
}
