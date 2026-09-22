import AppKit
import LatchACP
import UniformTypeIdentifiers

/// A file or image waiting in the composer to go out with the next prompt.
struct ComposerAttachment: Identifiable {
    enum Content {
        /// Already resized for the agent. `source` is the file it came from, when there was one.
        case image(data: Data, mimeType: String, source: URL?)
        case file(URL)
    }

    /// The long edge Anthropic's vision guidance recommends; larger images are scaled down by
    /// the model anyway, so sending more only costs transfer and tokens.
    static let maximumImageEdge: CGFloat = 1568
    /// A PNG over this is re-encoded as JPEG, which keeps a photo or a busy screenshot small.
    static let maximumPNGBytes = 1_000_000
    /// Larger image files are attached as files rather than read into memory.
    static let maximumImageFileBytes = 30_000_000
    static let maximumCount = 10

    let id = UUID()
    let name: String
    let content: Content
    let thumbnail: NSImage

    var record: ChatAttachment {
        switch content {
        case let .image(_, _, source): ChatAttachment(kind: .image, name: name, path: source?.path)
        case let .file(url): ChatAttachment(kind: .file, name: name, path: url.path)
        }
    }

    /// An agent that accepts images gets the pixels. One that does not gets a link to a file it
    /// can open itself: the original, or for a pasted image a copy written for the purpose.
    func block(acceptsImages: Bool) throws -> ACPPromptBlock {
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

    // MARK: Reading a pasteboard

    /// Whether a paste or drop should become attachments rather than text: any file, or an
    /// image that arrives without text (a screenshot, an image copied from a browser, which
    /// may bring its own address along as text). Copied text that happens to carry a picture,
    /// as rich text from a document does, stays text.
    static func canAttach(from pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        let types = pasteboard.types ?? []
        guard types.contains(where: { [.png, .tiff].contains($0) }) else { return false }
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return true }
        return !text.contains(where: \.isWhitespace) && URL(string: text)?.scheme != nil
    }

    static func attachments(from pasteboard: NSPasteboard) -> [ComposerAttachment] {
        guard canAttach(from: pasteboard) else { return [] }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map(fromFile)
        }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let image = normalizedImage(data) else { return [] }
        return [ComposerAttachment(name: "Pasted image.\(image.fileExtension)",
                                   content: .image(data: image.data, mimeType: image.mimeType, source: nil),
                                   thumbnail: image.thumbnail)]
    }

    static func fromFile(_ url: URL) -> ComposerAttachment {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey])
        if values?.isDirectory != true, values?.contentType?.conforms(to: .image) == true,
           (values?.fileSize ?? .max) <= maximumImageFileBytes,
           let data = try? Data(contentsOf: url), let image = normalizedImage(data) {
            return ComposerAttachment(name: url.lastPathComponent,
                                      content: .image(data: image.data, mimeType: image.mimeType, source: url),
                                      thumbnail: image.thumbnail)
        }
        return ComposerAttachment(name: url.lastPathComponent, content: .file(url),
                                  thumbnail: NSWorkspace.shared.icon(forFile: url.path))
    }

    struct NormalizedImage {
        let data: Data
        let mimeType: String
        let fileExtension: String
        let pixelSize: NSSize
        let thumbnail: NSImage
    }

    /// Scaled so its long edge is at most `maximumImageEdge`, as PNG, or JPEG when the PNG is
    /// large. Nil for data that is not an image.
    static func normalizedImage(_ data: Data) -> NormalizedImage? {
        guard let source = NSBitmapImageRep(data: data), source.pixelsWide > 0, source.pixelsHigh > 0 else { return nil }
        let width = CGFloat(source.pixelsWide), height = CGFloat(source.pixelsHigh)
        let scale = min(1, maximumImageEdge / max(width, height))
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        // Drawn over white, so the result is opaque: a window screenshot's transparent shadow
        // would otherwise turn black as JPEG. The bitmap still has an alpha channel, because a
        // graphics context cannot draw into 24-bit RGB.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let thumbnail = NSImage(size: size)
        thumbnail.addRepresentation(bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]), png.count <= maximumPNGBytes {
            return NormalizedImage(data: png, mimeType: "image/png", fileExtension: "png", pixelSize: size, thumbnail: thumbnail)
        }
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return NormalizedImage(data: jpeg, mimeType: "image/jpeg", fileExtension: "jpg", pixelSize: size, thumbnail: thumbnail)
    }
}
