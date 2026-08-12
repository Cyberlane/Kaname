import Foundation

/// Durable, provider-neutral metadata for an image that Kaname owns locally.
/// The bytes live beneath the private ConversationService root; workspace JSON
/// stores only this bounded descriptor.
public struct ConversationImageAttachment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let maximumCountPerMessage = 8
    public static let maximumSourceBytes = 50 * 1_024 * 1_024
    public static let maximumStoredBytes = 10 * 1_024 * 1_024
    public static let maximumPixelDimension = 2_048

    public let id: String
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let relativePath: String

    public init(
        id: String,
        filename: String,
        mimeType: String,
        byteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        relativePath: String
    ) {
        self.id = id
        self.filename = filename.isEmpty ? "image" : String(filename.prefix(160))
        self.mimeType = mimeType
        (self.byteCount, self.pixelWidth, self.pixelHeight) = (byteCount, pixelWidth, pixelHeight)
        self.relativePath = relativePath
    }
}
