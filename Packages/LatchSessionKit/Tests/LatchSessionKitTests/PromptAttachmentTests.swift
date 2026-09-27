import Foundation
import LatchACP
import LatchRemoteProtocol
import XCTest
@testable import LatchSessionKit

/// What an attachment becomes in a prompt, whichever app's composer made it. The bytes here
/// need not be a real image: the session sends what it was given.
final class PromptAttachmentTests: XCTestCase {
    private let pixels = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

    func testAPastedImageGoesAsPixelsOrAsAFileWrittenForIt() throws {
        let attachment = PromptAttachment(name: "Pasted image.png", content: .image(data: pixels, mimeType: "image/png", source: nil))
        XCTAssertTrue(attachment.isImage)
        XCTAssertEqual(attachment.record, ChatAttachment(kind: .image, name: "Pasted image.png", path: nil))
        XCTAssertEqual(try attachment.block(acceptsImages: true), .image(data: pixels, mimeType: "image/png"))

        guard case let .resourceLink(uri, name, mimeType) = try attachment.block(acceptsImages: false) else {
            return XCTFail("Expected a link")
        }
        let written = try XCTUnwrap(URL(string: uri))
        defer { try? FileManager.default.removeItem(at: written.deletingLastPathComponent()) }
        XCTAssertTrue(written.isFileURL)
        XCTAssertEqual(written.lastPathComponent, "Pasted image.png")
        XCTAssertEqual(name, "Pasted image.png")
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertEqual(try Data(contentsOf: written), pixels)
    }

    func testAnImageFromAFileLinksTheOriginalAndAFileIsAlwaysALink() throws {
        let shot = URL(fileURLWithPath: "/tmp/latch-shot.jpg")
        let image = PromptAttachment(name: "latch-shot.jpg", content: .image(data: pixels, mimeType: "image/jpeg", source: shot))
        XCTAssertEqual(image.record, ChatAttachment(kind: .image, name: "latch-shot.jpg", path: shot.path))
        XCTAssertEqual(try image.block(acceptsImages: false),
                       .resourceLink(uri: shot.absoluteString, name: "latch-shot.jpg", mimeType: "image/jpeg"))

        let notes = URL(fileURLWithPath: "/tmp/notes.txt")
        let file = PromptAttachment(name: "notes.txt", content: .file(notes))
        XCTAssertFalse(file.isImage)
        XCTAssertEqual(file.record, ChatAttachment(kind: .file, name: "notes.txt", path: notes.path))
        for acceptsImages in [true, false] {
            XCTAssertEqual(try file.block(acceptsImages: acceptsImages),
                           .resourceLink(uri: notes.absoluteString, name: "notes.txt", mimeType: "text/plain"))
        }
    }

    @MainActor func testARemoteSessionRefusesFilesAlwaysAndImagesOnlyOnceTheAgentSaysSo() throws {
        let model = SessionModel(makeClient: { UnconnectedAgentServiceClient() })
        let image = PromptAttachment(name: "Pasted image.png", content: .image(data: pixels, mimeType: "image/png", source: nil))
        let file = PromptAttachment(name: "notes.txt", content: .file(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(model.refusesRemotely(file), "A session on this device may link any file")
        model.sendsAttachmentsRemotely = true
        XCTAssertTrue(model.refusesRemotely(file))
        XCTAssertFalse(model.refusesRemotely(image), "Not refused before the agent's capabilities are known")

        // A channel to a server implies it, whether or not the app said so.
        let connector = ChannelRemoteSessionConnector(servers: InMemoryServerStore())
        let server = ServerProfile(name: "vps", host: "127.0.0.1", token: LatchRemoteToken.generate())
        try connector.servers.save(server)
        let remote = SessionModel(makeClient: { connector.makeClient(serverID: server.id) })
        XCTAssertTrue(remote.refusesRemotely(file))
        XCTAssertFalse(remote.refusesRemotely(image))
    }
}
