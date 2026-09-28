import AppKit
import LatchACP
import LatchServiceProtocol
import UniformTypeIdentifiers
import XCTest
@testable import LatchMacUI
@testable import LatchSessionKit

final class ComposerAttachmentTests: XCTestCase {
    private func png(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("latch-test-\(UUID().uuidString)"))
        board.clearContents()
        fill(board)
        return board
    }

    // MARK: What becomes an attachment

    func testFilesAndBareImagesAttachButTextWithAPictureStaysText() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("latch-attach-\(UUID().uuidString).txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let image = try png(width: 4, height: 4)

        XCTAssertTrue(ComposerAttachment.canAttach(from: pasteboard { $0.writeObjects([file as NSURL]) }))
        XCTAssertTrue(ComposerAttachment.canAttach(from: pasteboard { $0.setData(image, forType: .png) }))
        XCTAssertFalse(ComposerAttachment.canAttach(from: pasteboard {
            $0.declareTypes([.string, .png], owner: nil)
            $0.setString("A paragraph with a picture", forType: .string)
            $0.setData(image, forType: .png)
        }))
        XCTAssertFalse(ComposerAttachment.canAttach(from: pasteboard { $0.setString("plain", forType: .string) }))
        XCTAssertTrue(ComposerAttachment.canAttach(from: pasteboard {
            $0.declareTypes([.string, .tiff], owner: nil)
            $0.setString("https://example.com/diagram.png", forType: .string)
            $0.setData(image, forType: .tiff)
        }), "A browser's Copy Image brings the image's address along; the image still wins")

        let attached = ComposerAttachment.attachments(from: pasteboard { $0.writeObjects([file as NSURL]) })
        XCTAssertEqual(attached.map(\.record), [ChatAttachment(kind: .file, name: file.lastPathComponent, path: file.path)])
    }

    func testAPastedScreenshotIsScaledToTheRecommendedEdgeAndNamed() throws {
        let attached = ComposerAttachment.attachments(from: pasteboard { $0.setData(try! png(width: 3136, height: 2000), forType: .png) })
        let attachment = try XCTUnwrap(attached.first)
        XCTAssertEqual(attachment.record, ChatAttachment(kind: .image, name: "Pasted image.png", path: nil))
        guard case let .image(data, mimeType, source) = attachment.content else { return XCTFail("Expected an image") }
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertNil(source)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 1568)
        XCTAssertEqual(bitmap.pixelsHigh, 1000)
    }

    func testASmallImageKeepsItsSize() throws {
        let image = try XCTUnwrap(ComposerAttachment.normalizedImage(try png(width: 300, height: 200)))
        XCTAssertEqual(image.pixelSize, NSSize(width: 300, height: 200))
    }

    // MARK: What the agent receives

    func testAnImageGoesAsPixelsOnlyToAnAgentThatAcceptsThem() throws {
        let attachment = try XCTUnwrap(ComposerAttachment.attachments(from: pasteboard { $0.setData(try! png(width: 8, height: 8), forType: .png) }).first)
        guard case let .image(data, mimeType) = try attachment.block(acceptsImages: true) else { return XCTFail("Expected an image block") }
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertFalse(data.isEmpty)

        // Without image support, a pasted image is written out and linked.
        guard case let .resourceLink(uri, name, linkType) = try attachment.block(acceptsImages: false) else {
            return XCTFail("Expected a link")
        }
        let written = try XCTUnwrap(URL(string: uri))
        defer { try? FileManager.default.removeItem(at: written.deletingLastPathComponent()) }
        XCTAssertTrue(written.isFileURL)
        XCTAssertEqual(written.lastPathComponent, "Pasted image.png")
        XCTAssertEqual(name, "Pasted image.png")
        XCTAssertEqual(linkType, "image/png")
        XCTAssertEqual(try Data(contentsOf: written), data)
    }

    func testAnImageFileWithoutImageSupportLinksTheOriginal() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("latch-shot-\(UUID().uuidString).png")
        try png(width: 16, height: 16).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let attachment = ComposerAttachment.fromFile(file)
        XCTAssertEqual(attachment.record, ChatAttachment(kind: .image, name: file.lastPathComponent, path: file.path))
        XCTAssertEqual(try attachment.block(acceptsImages: false),
                       .resourceLink(uri: file.absoluteString, name: file.lastPathComponent, mimeType: "image/png"))
    }

    // MARK: History and saving

    func testAnAttachmentOnlyMessageIsKeptAndSavedWithoutBreakingOlderSessions() throws {
        var history = ChatHistory()
        let record = ChatAttachment(kind: .image, name: "Pasted image.png", path: nil)
        history.appendUser("", attachments: [record])
        XCTAssertEqual(history.messages.map(\.attachments), [[record]])

        var restored = ChatHistory()
        restored.restore(history.messages)
        XCTAssertEqual(restored.messages, history.messages, "Restoring drops empty text, not attachments")

        let plain = ChatMessage(role: .assistant, text: "Answer")
        let encoded = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("attachments"),
                       "A message without attachments saves as it did before they existed")
        let older = #"{"id":"00000000-0000-0000-0000-000000000009","role":"user","text":"Saved before"}"#
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: Data(older.utf8)).attachments, [])
        let withAttachment = try JSONDecoder().decode(ChatMessage.self, from: try JSONEncoder().encode(history.messages[0]))
        XCTAssertEqual(withAttachment, history.messages[0])
    }

    // MARK: The prompt

    @MainActor func testAttachmentsGoBeforeTheTextAndFollowTheAgentsImageSupport() async throws {
        for acceptsImages in [true, false] {
            let client = PromptClient(acceptsImages: acceptsImages)
            let model = SessionModel(makeClient: { client })
            await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
            XCTAssertEqual(model.acceptsImages, acceptsImages)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("latch-notes-\(UUID().uuidString).txt")
            try "notes".write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let image = try XCTUnwrap(ComposerAttachment.attachments(from: pasteboard { $0.setData(try! png(width: 8, height: 8), forType: .png) }).first)
            let notes = ComposerAttachment.fromFile(file)

            await model.send("What changed?", attachments: [image.prompt, notes.prompt])

            let blocks = await client.promptBlocks
            XCTAssertEqual(blocks.count, 3)
            if acceptsImages {
                guard case .image = blocks[0] else { return XCTFail("Expected pixels for an agent that accepts images") }
            } else {
                guard case let .resourceLink(uri, _, _) = blocks[0] else { return XCTFail("Expected a link instead") }
                try? FileManager.default.removeItem(at: URL(string: uri)!.deletingLastPathComponent())
            }
            XCTAssertEqual(blocks[1], .resourceLink(uri: file.absoluteString, name: file.lastPathComponent, mimeType: "text/plain"))
            XCTAssertEqual(blocks[2], .text("What changed?"))
            XCTAssertEqual(model.messages.last?.attachments.map(\.name), ["Pasted image.png", file.lastPathComponent])
            await model.disconnect()
        }
    }
}

private actor PromptClient: AgentServiceClient {
    nonisolated let transportDescription = "prompt capture mock"
    nonisolated let events: AsyncStream<LatchAgentEvent>
    private nonisolated let continuation: AsyncStream<LatchAgentEvent>.Continuation
    private let acceptsImages: Bool
    private(set) var promptBlocks: [ACPPromptBlock] = []

    init(acceptsImages: Bool) {
        self.acceptsImages = acceptsImages
        let pair = AsyncStream<LatchAgentEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    nonisolated func close() { continuation.finish() }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        switch command {
        case let .startRuntime(id, _):
            return .runtimeStarted(runtimeID: id, initialization: ACPInitializeResponse(protocolVersion: 1, agentCapabilities: .init(
                promptCapabilities: .object(["image": .bool(acceptsImages)]))))
        case let .newSession(id, _):
            return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: "session-1"))
        case let .prompt(id, blocks):
            promptBlocks = blocks
            return .promptCompleted(runtimeID: id, response: ACPPromptResponse(stopReason: "end_turn"))
        case let .stopRuntime(id):
            return .runtimeStopped(runtimeID: id)
        default:
            throw LatchAgentFailure(code: .commandFailed, message: "Unexpected mock command")
        }
    }
}
