import Darwin
import Foundation
import XCTest
@testable import LatchMacUI

@MainActor
final class SessionStoreTests: XCTestCase {
    private let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SessionStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture() -> SavedSessionLibrary {
        SavedSessionLibrary(sessions: [SavedSession(
            id: sessionID, workspacePath: "/tmp/工作 👩🏽‍💻", title: "Café 日本語",
            agentID: AgentPreset.custom.rawValue, customCommand: "my-agent --label 'é'",
            draft: "  unfinished\n\t草稿 👨‍👩‍👧‍👦\n", messages: [
                ChatMessage(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, role: .user, text: "你好\n"),
                ChatMessage(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, role: .assistant, text: "  e\u{301} 🙂"),
                ChatMessage(id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!, role: .tool, text: "Read · 完了"),
            ], agentSessionID: "opaque-agent/会話-123"
        )], selectedSessionID: sessionID)
    }

    private func assertError(
        _ expected: SessionStore.StoreError,
        file: StaticString = #filePath, line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected storage error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SessionStore.StoreError, expected, file: file, line: line)
        }
    }

    private func diskURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(SessionStore.fileName)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    func testMissingIsEmptyAndDoesNotCreateDirectory() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("not-created")
        let library = try await SessionStore(directory: directory).load()
        XCTAssertEqual(library, SavedSessionLibrary(sessions: [], selectedSessionID: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRoundTripUnicodeRolesIDsDraftAndAllHarnesses() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("Latch")
        let store = SessionStore(directory: directory)
        for preset in AgentPreset.allCases {
            var library = fixture()
            library.sessions[0].agentID = preset.rawValue
            try await store.save(library)
            let restored = try await SessionStore(directory: directory).load()
            XCTAssertEqual(restored, library)
        }
        var library = fixture()
        library.sessions[0].agentSessionID = nil
        library.selectedSessionID = nil
        try await store.save(library)
        let restored = try await store.load()
        XCTAssertEqual(restored, library)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: diskURL(directory))) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "sessions"])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertEqual(Set(sessions[0].keys), ["id", "workspacePath", "title", "agentID", "customCommand", "draft", "messages"])
    }

    func testCorruptAndFutureDataSurviveFailedLoadAndFreshStoreSave() async throws {
        let directory = try temporaryDirectory()
        let file = diskURL(directory)
        let cases: [(Data, SessionStore.StoreError)] = [
            (Data("private transcript: not JSON".utf8), .corrupt),
            (Data(), .corrupt),
            (Data(#"{"version":2,"sessions":"future payload"}"#.utf8), .unsupportedVersion),
            (Data(#"{"version":0,"sessions":[]}"#.utf8), .unsupportedVersion),
            (Data(#"{"sessions":[]}"#.utf8), .corrupt),
        ]
        for (bytes, expected) in cases {
            try bytes.write(to: file)
            let store = SessionStore(directory: directory)
            await assertError(expected) { _ = try await store.load() }
            await assertError(.saveBlocked) { try await store.save(self.fixture()) }
            await assertError(expected) { try await SessionStore(directory: directory).save(self.fixture()) }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testOnlySuccessfulExplicitLoadClearsFailedLoadLatch() async throws {
        let directory = try temporaryDirectory()
        let file = diskURL(directory)
        try Data("broken".utf8).write(to: file)
        let store = SessionStore(directory: directory)
        await assertError(.corrupt) { _ = try await store.load() }
        // Simulate deliberate external recovery; deleting the file alone does not unlock save.
        try FileManager.default.removeItem(at: file)
        await assertError(.saveBlocked) { try await store.save(self.fixture()) }
        _ = try await store.load()
        try await store.save(fixture())
        let restored = try await store.load()
        XCTAssertEqual(restored, fixture())
    }

    func testExternalCorruptionAfterSuccessfulLoadIsPreserved() async throws {
        let directory = try temporaryDirectory()
        let store = SessionStore(directory: directory)
        try await store.save(fixture())
        _ = try await store.load()
        let corrupt = Data("external corruption".utf8)
        try corrupt.write(to: diskURL(directory))
        await assertError(.corrupt) { try await store.save(self.fixture()) }
        XCTAssertEqual(try Data(contentsOf: diskURL(directory)), corrupt)
    }

    func testInvalidLibrariesRejectedOnSaveAndLoadWithoutReplacingData() async throws {
        let directory = try temporaryDirectory()
        let store = SessionStore(directory: directory)
        let good = fixture()
        try await store.save(good)
        let original = try Data(contentsOf: diskURL(directory))
        var cases: [(SavedSessionLibrary, SessionStore.StoreError)] = []
        var value = good
        value.version = -1
        cases.append((value, .unsupportedVersion))
        value = good
        value.sessions.append(value.sessions[0])
        cases.append((value, .invalidLibrary))
        value = good
        value.selectedSessionID = otherID
        cases.append((value, .invalidLibrary))
        value = good
        value.sessions[0].agentID = "unknown-harness"
        cases.append((value, .invalidLibrary))
        value = good
        value.sessions[0].messages.append(value.sessions[0].messages[0])
        cases.append((value, .invalidLibrary))
        value = good
        var second = value.sessions[0]
        second.id = otherID
        value.sessions.append(second) // Message IDs must also be unique across sessions.
        cases.append((value, .invalidLibrary))
        value = good
        value.sessions[0].messages = (0...ChatHistory.maximumMessageCount).map {
            ChatMessage(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!, role: .user, text: "x")
        }
        cases.append((value, .invalidLibrary))
        value = good
        value.sessions[0].messages[0].text = String(repeating: "x", count: ChatHistory.maximumTextCount)
        cases.append((value, .invalidLibrary)) // Total text, not just per-message text.
        for (invalid, expected) in cases {
            await assertError(expected) { try await store.save(invalid) }
            XCTAssertEqual(try Data(contentsOf: diskURL(directory)), original)
            let bytes = try JSONEncoder().encode(invalid)
            try bytes.write(to: diskURL(directory))
            await assertError(expected) { _ = try await SessionStore(directory: directory).load() }
            XCTAssertEqual(try Data(contentsOf: diskURL(directory)), bytes)
            try original.write(to: diskURL(directory))
        }
    }

    func testMalformedUUIDAndRoleAreCorruptAndDiagnosticsAreSafe() async throws {
        let directory = try temporaryDirectory()
        let original = try JSONEncoder().encode(fixture())
        let sentinel = "PRIVATE-CONTENT-DO-NOT-DIAGNOSE"
        for field in ["id", "role"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
            var messages = try XCTUnwrap(sessions[0]["messages"] as? [[String: Any]])
            messages[0][field] = sentinel
            sessions[0]["messages"] = messages
            json["sessions"] = sessions
            let bytes = try JSONSerialization.data(withJSONObject: json)
            try bytes.write(to: diskURL(directory))
            do {
                _ = try await SessionStore(directory: directory).load()
                XCTFail("Expected corrupt data error")
            } catch {
                XCTAssertEqual(error as? SessionStore.StoreError, .corrupt)
                XCTAssertFalse(error.localizedDescription.contains(sentinel))
                XCTAssertFalse(error.localizedDescription.contains(directory.path))
            }
            XCTAssertEqual(try Data(contentsOf: diskURL(directory)), bytes)
        }
    }

    func testHistoryBoundaryAndLargeDraftAreNotTruncated() async throws {
        let directory = try temporaryDirectory()
        var library = fixture()
        library.sessions[0].messages = (0..<ChatHistory.maximumMessageCount).map {
            ChatMessage(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!, role: .assistant,
                        text: String(repeating: "👨‍👩‍👧‍👦", count: ChatHistory.maximumTextCount / ChatHistory.maximumMessageCount))
        }
        library.sessions[0].draft = String(repeating: "草稿\n", count: 100_000)
        let store = SessionStore(directory: directory)
        try await store.save(library)
        let restored = try await store.load()
        XCTAssertEqual(restored, library)
    }

    func testOversizedSparseFileIsRejectedBeforeDecodeAndPreserved() async throws {
        let directory = try temporaryDirectory()
        let file = diskURL(directory)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(SessionStore.maximumFileSize + 1))
        try handle.close()
        let store = SessionStore(directory: directory)
        await assertError(.tooLarge) { _ = try await store.load() }
        await assertError(.saveBlocked) { try await store.save(self.fixture()) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, SessionStore.maximumFileSize + 1)
    }

    func testOversizedSavePreservesPreviousFile() async throws {
        let directory = try temporaryDirectory()
        let store = SessionStore(directory: directory)
        try await store.save(fixture())
        let original = try Data(contentsOf: diskURL(directory))
        var large = fixture()
        large.sessions[0].draft = String(repeating: "x", count: SessionStore.maximumFileSize)
        await assertError(.tooLarge) { try await store.save(large) }
        XCTAssertEqual(try Data(contentsOf: diskURL(directory)), original)
    }

    func testAtomicReplacementAndPrivatePermissions() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("Latch")
        let store = SessionStore(directory: directory)
        let first = fixture()
        try await store.save(first)
        let file = diskURL(directory)
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
        let oldBytes = try Data(contentsOf: file)
        // An open descriptor keeps the old inode after replacement, unlike an in-place write.
        let oldHandle = try FileHandle(forReadingFrom: file)
        defer { try? oldHandle.close() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        var second = first
        second.sessions[0].draft = "replacement"
        try await store.save(second)
        XCTAssertEqual(try oldHandle.readToEnd(), oldBytes)
        let restored = try await store.load()
        XCTAssertEqual(restored, second)
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [SessionStore.fileName])
    }

    func testSymlinkAndNonRegularFileAreRefused() async throws {
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("target.json")
        let bytes = try JSONEncoder().encode(fixture())
        try bytes.write(to: target)
        let file = diskURL(directory)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        await assertError(.unreadable) { _ = try await SessionStore(directory: directory).load() }
        await assertError(.unreadable) { try await SessionStore(directory: directory).save(self.fixture()) }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, mode_t(0o600)), 0)
        await assertError(.unreadable) { _ = try await SessionStore(directory: directory).load() }
    }
}
