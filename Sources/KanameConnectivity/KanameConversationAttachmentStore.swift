import Foundation
import ImageIO
import KanameDomain
import UniformTypeIdentifiers

public enum KanameConversationAttachmentError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier
    case invalidImage
    case sourceTooLarge
    case processedImageTooLarge
    case unsafePath
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "Kaname rejected an invalid attachment identifier."
        case .invalidImage: "That file is not a readable image."
        case .sourceTooLarge: "Images must be no larger than 50 MB before processing."
        case .processedImageTooLarge: "Kaname could not reduce that image below 10 MB."
        case .unsafePath: "Kaname rejected an unsafe attachment path."
        case .unavailable: "The local image attachment is no longer available."
        }
    }
}

/// Owns normalized conversation-image bytes beneath the private conversation
/// service root. Callers persist only the returned relative descriptor.
public struct KanameConversationAttachmentStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public func importImage(
        data: Data,
        suggestedFilename: String,
        threadID: String
    ) throws -> ConversationImageAttachment {
        try validateIdentifier(threadID)
        guard !data.isEmpty, data.count <= ConversationImageAttachment.maximumSourceBytes else {
            throw data.isEmpty
                ? KanameConversationAttachmentError.invalidImage
                : KanameConversationAttachmentError.sourceTooLarge
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw KanameConversationAttachmentError.invalidImage
        }

        let dimensions = try imageDimensions(source)
        let maxDimension = max(dimensions.width, dimensions.height)
        guard maxDimension > 0 else { throw KanameConversationAttachmentError.invalidImage }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxDimension, ConversationImageAttachment.maximumPixelDimension),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw KanameConversationAttachmentError.invalidImage
        }

        let encoded = try Self.encode(image)
        guard encoded.data.count <= ConversationImageAttachment.maximumStoredBytes else {
            throw KanameConversationAttachmentError.processedImageTooLarge
        }

        let id = UUID().uuidString.lowercased()
        let extensionName = encoded.mimeType == "image/png" ? "png" : "jpg"
        let filename = Self.safeFilename(suggestedFilename, fallbackID: id, extensionName: extensionName)
        let relativePath = "Threads/\(threadID)/Attachments/\(id).\(extensionName)"
        let destination = try resolvedURL(relativePath: relativePath)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try encoded.data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        return ConversationImageAttachment(
            id: id,
            filename: filename,
            mimeType: encoded.mimeType,
            byteCount: encoded.data.count,
            pixelWidth: image.width,
            pixelHeight: image.height,
            relativePath: relativePath
        )
    }

    public func attachmentURL(
        threadID: String,
        attachment: ConversationImageAttachment
    ) throws -> URL {
        try validateIdentifier(threadID)
        try validateIdentifier(attachment.id)
        guard attachment.byteCount > 0,
              attachment.byteCount <= ConversationImageAttachment.maximumStoredBytes,
              attachment.pixelWidth > 0,
              attachment.pixelHeight > 0,
              attachment.pixelWidth <= ConversationImageAttachment.maximumPixelDimension,
              attachment.pixelHeight <= ConversationImageAttachment.maximumPixelDimension,
              ["image/png", "image/jpeg"].contains(attachment.mimeType) else {
            throw KanameConversationAttachmentError.invalidImage
        }
        let expectedExtension = attachment.mimeType == "image/png" ? "png" : "jpg"
        let expectedPath = "Threads/\(threadID)/Attachments/\(attachment.id).\(expectedExtension)"
        guard attachment.relativePath == expectedPath else {
            throw KanameConversationAttachmentError.unsafePath
        }
        let url = try resolvedURL(relativePath: attachment.relativePath)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              values?.fileSize == attachment.byteCount else {
            throw KanameConversationAttachmentError.unavailable
        }
        return url
    }

    public func remove(
        threadID: String,
        attachment: ConversationImageAttachment
    ) throws {
        let url = try attachmentURL(threadID: threadID, attachment: attachment)
        try FileManager.default.removeItem(at: url)
    }

    private func resolvedURL(relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            throw KanameConversationAttachmentError.unsafePath
        }
        let root = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = rootDirectory.appending(path: relativePath).standardizedFileURL
        let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard parent.path.hasPrefix(rootPrefix) else { throw KanameConversationAttachmentError.unsafePath }
        return candidate
    }

    private func validateIdentifier(_ value: String) throws {
        guard value.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            throw KanameConversationAttachmentError.invalidIdentifier
        }
    }

    private func imageDimensions(_ source: CGImageSource) throws -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw KanameConversationAttachmentError.invalidImage
        }
        return (width.intValue, height.intValue)
    }

    private static func encode(_ image: CGImage) throws -> (data: Data, mimeType: String) {
        let hasAlpha = switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: true
        default: false
        }
        if hasAlpha, let png = encoded(image, type: .png, properties: [:]),
           png.count <= ConversationImageAttachment.maximumStoredBytes {
            return (png, "image/png")
        }
        for quality in [0.88, 0.76, 0.64, 0.52] {
            if let jpeg = encoded(
                image,
                type: .jpeg,
                properties: [kCGImageDestinationLossyCompressionQuality: quality]
            ), jpeg.count <= ConversationImageAttachment.maximumStoredBytes {
                return (jpeg, "image/jpeg")
            }
        }
        throw KanameConversationAttachmentError.processedImageTooLarge
    }

    private static func encoded(
        _ image: CGImage,
        type: UTType,
        properties: [CFString: Any]
    ) -> Data? {
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }

    private static func safeFilename(
        _ proposed: String,
        fallbackID: String,
        extensionName: String
    ) -> String {
        let base = URL(fileURLWithPath: proposed).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = base.isEmpty ? "image-\(fallbackID.prefix(8))" : String(base.prefix(120))
        return "\(safeBase).\(extensionName)"
    }
}
