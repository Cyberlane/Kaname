import Foundation
import Testing
@testable import KanameConnectivity
@testable import KanameDomain

struct ConversationAttachmentStoreTests {
    @Test
    func imagesAreNormalizedStoredPrivatelyResolvedAndRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-conversation-images-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KanameConversationAttachmentStore(rootDirectory: root)
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))

        let attachment = try store.importImage(
            data: png,
            suggestedFilename: "Screenshot: private.png",
            threadID: "thread-images"
        )
        let url = try store.attachmentURL(threadID: "thread-images", attachment: attachment)
        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        )
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )

        #expect(attachment.filename == "Screenshot- private.png")
        #expect(attachment.pixelWidth == 1)
        #expect(attachment.pixelHeight == 1)
        #expect(attachment.byteCount == (try Data(contentsOf: url)).count)
        #expect(directoryMode.intValue & 0o777 == 0o700)
        #expect(fileMode.intValue & 0o777 == 0o600)
        try store.remove(threadID: "thread-images", attachment: attachment)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func malformedBytesAndEscapingDescriptorsFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-conversation-images-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KanameConversationAttachmentStore(rootDirectory: root)

        #expect(throws: KanameConversationAttachmentError.invalidImage) {
            try store.importImage(data: Data("not-image".utf8), suggestedFilename: "bad.png", threadID: "thread")
        }
        let escaping = ConversationImageAttachment(
            id: "image",
            filename: "image.png",
            mimeType: "image/png",
            byteCount: 1,
            pixelWidth: 1,
            pixelHeight: 1,
            relativePath: "../image.png"
        )
        #expect(throws: KanameConversationAttachmentError.unsafePath) {
            try store.attachmentURL(threadID: "thread", attachment: escaping)
        }
        let mismatchedExtension = ConversationImageAttachment(
            id: "image",
            filename: "image.png",
            mimeType: "image/png",
            byteCount: 1,
            pixelWidth: 1,
            pixelHeight: 1,
            relativePath: "Threads/thread/Attachments/image.jpg"
        )
        #expect(throws: KanameConversationAttachmentError.unsafePath) {
            try store.attachmentURL(threadID: "thread", attachment: mismatchedExtension)
        }
    }
}
