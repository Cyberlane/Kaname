import Foundation
import KanameConnectivity
import KanameDesktop

struct WorkflowStructuredModelRequest: Decodable {
    enum Provider {
        case codex
        case native(NativeProviderDiscussionDriver)
    }

    let providerName: String
    let prompt: String
    let outputSchema: String

    var provider: Provider {
        get throws {
            switch providerName.lowercased() {
            case "codex", "openai": .codex
            case "claude": .native(.claude)
            case "opencode", "open code": .native(.openCode)
            default: throw DesktopWorkflowCapabilityError.outputInvalid
            }
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 512 * 1_024,
              let request = try? JSONDecoder().decode(Self.self, from: data),
              !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.prompt.utf8.count <= 100_000,
              DesktopWorkflowJSONSchemaValidator.validateSchema(Data(request.outputSchema.utf8)) else {
            throw DesktopWorkflowCapabilityError.outputInvalid
        }
        return request
    }

    func validatedOutput(_ text: String) throws -> Data {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [clean, Self.fencedJSON(clean)].compactMap { $0 }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if DesktopWorkflowJSONSchemaValidator.validates(instance: data, against: outputSchema) { return data }
        }
        throw DesktopWorkflowCapabilityError.outputInvalid
    }

    func prompt(including context: DesktopWorkflowContextSnapshotRecord?) throws -> String {
        guard let compiled = DesktopWorkflowModelContextCompiler.augment(prompt: prompt, context: context) else {
            throw DesktopWorkflowCapabilityError.inputTooLarge
        }
        return compiled
    }

    private static func fencedJSON(_ text: String) -> String? {
        guard let opening = text.range(of: "```"),
              let closing = text.range(of: "```", range: opening.upperBound..<text.endIndex) else { return nil }
        var body = String(text[opening.upperBound..<closing.lowerBound])
        if body.lowercased().hasPrefix("json") { body.removeFirst(4) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct WorkflowEmailEffectRequest: Decodable {
    struct Attachment: Decodable {
        let filename: String
        let mimeType: String
        let dataBase64: String

        var data: Data { Data(base64Encoded: dataBase64) ?? Data() }
    }

    let accountID: String
    let recipients: String
    let subject: String
    let body: String
    let inReplyTo: String?
    let references: [String]
    let threadID: String?
    let attachments: [Attachment]

    private enum CodingKeys: String, CodingKey {
        case accountID, recipients, subject, body, inReplyTo, references, threadID, attachments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let required = try (
            container.decode(String.self, forKey: .accountID),
            container.decode(String.self, forKey: .recipients),
            container.decode(String.self, forKey: .subject),
            container.decode(String.self, forKey: .body)
        )
        (accountID, recipients, subject, body) = required
        inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        let optional = try (
            container.decodeIfPresent([String].self, forKey: .references) ?? [],
            container.decodeIfPresent(String.self, forKey: .threadID),
            container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        )
        (references, threadID, attachments) = optional
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 36 * 1_024 * 1_024,
              let request = try? JSONDecoder().decode(Self.self, from: data),
              !request.accountID.isEmpty,
              request.attachments.count <= GmailOutboundAttachment.maximumCount,
              request.attachments.allSatisfy({ !$0.data.isEmpty }),
              request.attachments.reduce(0, { $0 + $1.data.count }) <= GmailOutboundAttachment.maximumTotalBytes else {
            throw DesktopWorkflowCapabilityError.outputInvalid
        }
        _ = try request.message()
        return request
    }

    func message() throws -> GmailOutboundMessage {
        GmailOutboundMessage(
            recipients: recipients,
            subject: subject,
            body: body,
            inReplyTo: inReplyTo,
            references: references,
            threadID: threadID,
            attachments: attachments.map {
                GmailOutboundAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            }
        )
    }
}
