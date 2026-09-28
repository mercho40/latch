import UIKit

/// Small pictures of the photos sent from this device, so a prompt shows them rather than
/// their names: the shared history keeps only an attachment's name. One JPEG per photo, at
/// most 256 pixels on its longest side, in Caches, which the system may empty and no backup
/// keeps; a prompt whose pictures are gone, or that another device sent, lists its photos by
/// name as before. An in-memory cache sits in front.
@MainActor
final class SentImageCache {
    static let shared = SentImageCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SentImages", isDirectory: true))

    /// The longest side a kept picture has, in pixels: a 64 point square at 3× with room over.
    nonisolated static let maximumPixelSize: CGFloat = 256
    /// Photos per prompt whose pictures are kept.
    static let maximumCount = 8

    private let directory: URL
    private var memory: [UUID: [UIImage?]] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    private func file(_ id: UUID, _ index: Int) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-\(index).jpg")
    }

    /// Keeps `images`, one per attachment of the message in order; nil where there is none.
    func store(_ images: [UIImage?], for id: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var kept: [UIImage?] = []
        for (index, image) in images.prefix(Self.maximumCount).enumerated() {
            guard let image, let data = Self.jpeg(image) else {
                kept.append(nil)
                continue
            }
            try? data.write(to: file(id, index), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            kept.append(UIImage(data: data))
        }
        memory[id] = kept
    }

    /// The pictures kept for a message's attachments, in order; empty when there are none.
    func images(for id: UUID) -> [UIImage?] {
        if let known = memory[id] { return known }
        var found: [UIImage?] = (0..<Self.maximumCount).map { UIImage(contentsOfFile: file(id, $0).path) }
        while found.last.map({ $0 == nil }) == true { found.removeLast() }
        memory[id] = found
        return found
    }

    /// Forgets the pictures of messages that are gone, such as a removed session's.
    func remove(_ ids: [UUID]) {
        for id in ids {
            memory[id] = nil
            for index in 0..<Self.maximumCount { try? FileManager.default.removeItem(at: file(id, index)) }
        }
    }

    /// JPEG at quality 0.7, scaled down to `maximumPixelSize` on its longest side. Transparent
    /// parts are white, as a photo app shows them, rather than the black an opaque JPEG leaves.
    private static func jpeg(_ image: UIImage) -> Data? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = min(1, maximumPixelSize / max(pixels.width, pixels.height, 1))
        let size = CGSize(width: max(1, (pixels.width * scale).rounded()), height: max(1, (pixels.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: 0.7)
    }
}
