import Foundation
import ImageIO
import LatchSessionKit
import UIKit
import UniformTypeIdentifiers

/// A photo waiting in the composer: what the session will send, and a thumbnail to show.
struct ComposerImage: Identifiable, Sendable {
    /// Four is what fits in the composer's strip and in an agent's context without surprise.
    static let maximumCount = 4
    /// The longest side an image keeps. Enough for a screenshot to stay legible, small
    /// enough that a photo from the camera does not fill a prompt.
    static let maximumPixelSize = 2048

    let prompt: PromptAttachment
    let thumbnail: UIImage?

    var id: UUID { prompt.id }
    var name: String { prompt.name }

    /// JPEG at no more than `maximumPixelSize` on its longest side, upright, from image data in
    /// any format ImageIO reads (HEIC, PNG, JPEG…). Nil when the data is not an image.
    nonisolated static func make(from data: Data, name: String) -> ComposerImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? maximumPixelSize
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? maximumPixelSize
        guard let image = thumbnail(source, maximum: min(maximumPixelSize, max(width, height, 1))),
              let jpeg = encodeJPEG(image) else { return nil }
        let preview = thumbnail(source, maximum: Int(SentImageCache.maximumPixelSize)).map { UIImage(cgImage: $0) }
        let base = (name as NSString).deletingPathExtension
        let prompt = PromptAttachment(name: (base.isEmpty ? "Photo" : base) + ".jpg",
                                      content: .image(data: jpeg, mimeType: "image/jpeg", source: nil))
        return ComposerImage(prompt: prompt, thumbnail: preview)
    }

    private nonisolated static func thumbnail(_ source: CGImageSource, maximum: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Reads one picked photo, and converts it off the main thread.
    @MainActor
    static func load(from provider: NSItemProvider) async -> ComposerImage? {
        let name = provider.suggestedName ?? "Photo"
        // The provider calls back on a queue of its own.
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in continuation.resume(returning: data) }
        }
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) { make(from: data, name: name) }.value
    }
}
