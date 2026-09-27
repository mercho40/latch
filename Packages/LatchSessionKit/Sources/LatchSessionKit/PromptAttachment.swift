import Foundation
import LatchACP
import UniformTypeIdentifiers

/// A file or image to go out with the next prompt, as the session sends it. Each app's composer
/// makes these, from a pasteboard, a drop or a photo picker, and keeps its own thumbnail beside.
public struct PromptAttachment: Identifiable, Sendable {
    public enum Content: Sendable {
        /// Already resized for the agent. `source` is the file it came from, when there was one.
        case image(data: Data, mimeType: String, source: URL?)
        /// A file or a folder on this device.
        case file(URL)
    }

    public let id: UUID
    public let name: String
    public let content: Content

    public init(id: UUID = UUID(), name: String, content: Content) {
        self.id = id
        self.name = name
        self.content = content
    }

    public var record: ChatAttachment {
        switch content {
        case let .image(_, _, source): ChatAttachment(kind: .image, name: name, path: source?.path)
        case let .file(url): ChatAttachment(kind: .file, name: name, path: url.path)
        }
    }

    /// An agent that accepts images gets the pixels. One that does not gets a link to a file it
    /// can open itself: the original, or for a pasted image a copy written for the purpose.
    public func block(acceptsImages: Bool) throws -> ACPPromptBlock {
        switch content {
        case let .image(data, mimeType, _) where acceptsImages:
            return .image(data: data, mimeType: mimeType)
        case let .image(data, mimeType, source):
            let url = try source ?? Self.writeTemporary(data, name: name, mimeType: mimeType)
            return Self.link(to: url, name: name)
        case let .file(url):
            return Self.link(to: url, name: name)
        }
    }

    /// A remote agent cannot open a file on this device, so a file or folder would go as a link
    /// to a path the server does not have. Only an image's pixels can reach it.
    public static let remoteRefusal = "Only images can be sent to a remote agent."

    public var isImage: Bool {
        if case .image = content { true } else { false }
    }

    private static func link(to url: URL, name: String) -> ACPPromptBlock {
        .resourceLink(uri: url.absoluteString, name: name,
                      mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
    }

    private static func writeTemporary(_ data: Data, name: String, mimeType: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Latch Attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png"
        let url = directory.appendingPathComponent((name as NSString).deletingPathExtension)
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }
}
