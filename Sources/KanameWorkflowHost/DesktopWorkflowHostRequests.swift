import Foundation
import KanameConnectivity
import KanameDesktop

private func decodeWorkflowRequest<Wire: Decodable, Request>(
    _ wireType: Wire.Type,
    from data: Data,
    maximumBytes: Int,
    makeRequest: (Wire) throws -> Request
) throws -> Request {
    guard data.count <= maximumBytes,
          let wire = try? JSONDecoder().decode(wireType, from: data) else {
        throw DesktopWorkflowCapabilityError.outputInvalid
    }
    return try makeRequest(wire)
}

private struct WorkflowModelRequestWire: Decodable {
    let providerName: String
    let prompt: String
    let outputSchema: String
}

private func validateWorkflowModelRequest(
    providerName: String,
    prompt: String,
    outputSchema: String
) throws {
    guard !providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          prompt.utf8.count <= 100_000,
          DesktopWorkflowJSONSchemaValidator.validateSchema(Data(outputSchema.utf8)) else {
        throw DesktopWorkflowCapabilityError.outputInvalid
    }
}

struct WorkflowStructuredModelRequest {
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
        try decodeWorkflowRequest(
            WorkflowModelRequestWire.self, from: data, maximumBytes: 512 * 1_024
        ) { wire in
            try validateWorkflowModelRequest(
                providerName: wire.providerName, prompt: wire.prompt, outputSchema: wire.outputSchema
            )
            return Self(
                providerName: wire.providerName, prompt: wire.prompt, outputSchema: wire.outputSchema
            )
        }
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

struct WorkflowEmailEffectRequest {
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

    private struct Wire: Decodable {
        let accountID: String
        let recipients: String
        let subject: String
        let body: String
        let inReplyTo: String?
        let references: [String]?
        let threadID: String?
        let conversationID: String?
        let attachments: [Attachment]?
    }

    static func decode(_ data: Data) throws -> Self {
        try decodeWorkflowRequest(Wire.self, from: data, maximumBytes: 36 * 1_024 * 1_024) { wire in
            let request = Self(
                accountID: wire.accountID, recipients: wire.recipients, subject: wire.subject,
                body: wire.body, inReplyTo: wire.inReplyTo, references: wire.references ?? [],
                threadID: wire.conversationID ?? wire.threadID, attachments: wire.attachments ?? []
            )
            guard !request.accountID.isEmpty,
                  request.attachments.count <= GmailOutboundAttachment.maximumCount,
                  request.attachments.allSatisfy({ !$0.data.isEmpty }),
                  request.attachments.reduce(0, { $0 + $1.data.count }) <= GmailOutboundAttachment.maximumTotalBytes else {
                throw DesktopWorkflowCapabilityError.outputInvalid
            }
            _ = try request.message()
            return request
        }
    }

    func message() throws -> MailOutboundMessage {
        MailOutboundMessage(
            recipients: recipients,
            subject: subject,
            body: body,
            inReplyTo: inReplyTo,
            references: references,
            conversationID: threadID,
            attachments: attachments.map {
                MailOutboundAttachment(filename: $0.filename, mediaType: $0.mimeType, data: $0.data)
            }
        )
    }
}

struct WorkflowEmailReadRequest {
    enum Operation: String, Decodable { case search, thread, resources, labels }

    let operation: Operation
    let accountID: String
    let query: String?
    let threadID: String?
    let includeAttachmentBytes: Bool
    let maximumPages: Int
    let maximumThreads: Int
    let maximumAttachmentBytes: Int
    let headerProjection: [String]
    let queryExtensionID: String?
    let headerProjectionExtensionID: String?

    static let allowedHeaderProjection = Set([
        "List-Unsubscribe", "List-Unsubscribe-Post", "Auto-Submitted", "Precedence",
    ])

    private struct Wire: Decodable {
        let operation: Operation
        let accountID: String
        let query: String?
        let threadID: String?
        let includeAttachmentBytes: Bool?
        let maximumPages: Int?
        let maximumThreads: Int?
        let maximumAttachmentBytes: Int?
        let headerProjection: [String]?
        let queryExtensionID: String?
        let headerProjectionExtensionID: String?
    }

    static func decode(_ data: Data) throws -> Self {
        try decodeWorkflowRequest(Wire.self, from: data, maximumBytes: 64 * 1_024) { wire in
            let request = Self(
                operation: wire.operation, accountID: wire.accountID, query: wire.query,
                threadID: wire.threadID, includeAttachmentBytes: wire.includeAttachmentBytes ?? false,
                maximumPages: wire.maximumPages ?? 20, maximumThreads: wire.maximumThreads ?? 2_000,
                maximumAttachmentBytes: wire.maximumAttachmentBytes ?? GmailOutboundAttachment.maximumTotalBytes,
                headerProjection: Array(Set(wire.headerProjection ?? [])).sorted(),
                queryExtensionID: wire.queryExtensionID,
                headerProjectionExtensionID: wire.headerProjectionExtensionID
            )
            guard !request.accountID.isEmpty,
                  (1...100).contains(request.maximumPages),
                  (1...10_000).contains(request.maximumThreads),
                  (0...GmailOutboundAttachment.maximumTotalBytes).contains(request.maximumAttachmentBytes),
                  Set(request.headerProjection).isSubset(of: Self.allowedHeaderProjection),
                  request.query.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 2_048 })
                    ?? (request.operation != .search),
                  request.queryExtensionID.map(Self.validExtensionID) ?? true,
                  request.headerProjectionExtensionID.map(Self.validExtensionID) ?? request.headerProjection.isEmpty,
                  request.threadID.map({ !$0.isEmpty && $0.utf8.count <= 2_048 })
                    ?? (request.operation != .thread) else {
                throw DesktopWorkflowCapabilityError.outputInvalid
            }
            return request
        }
    }

    private static func validExtensionID(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9][a-z0-9._-]{2,127}$"#, options: .regularExpression) != nil
    }
}

enum WorkflowEmailReadResponse {
    static func encode(
        request: WorkflowEmailReadRequest,
        conversations: [MailConversationSnapshot] = [],
        resources: [MailResourceSnapshot] = [],
        pages: Int = 0,
        attachmentPayloads: [String: Data] = [:],
        capturePolicy: DesktopWorkflowCapturePolicy = .init()
    ) throws -> Data {
        let headers = capturePolicy.capturedHeaders(from: request.headerProjection)
        let includeBody = capturePolicy.capturesMailBody
        let object: [String: Any] = [
            "operation": request.operation.rawValue,
            "accountID": request.accountID,
            "query": request.query ?? "",
            "complete": true,
            "pages": pages,
            "conversationCount": conversations.count,
            "conversations": conversations.map {
                conversationObject(
                    $0, attachmentPayloads: attachmentPayloads,
                    headerProjection: headers, includeBody: includeBody
                )
            },
            "resources": resources.map {
                ["id": $0.id, "providerID": $0.providerID, "name": $0.name, "kind": $0.kind.rawValue]
            },
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func attachmentKey(_ attachment: MailAttachmentSnapshot) -> String {
        "\(attachment.messageID):\(attachment.attachmentID)"
    }

    private static func conversationObject(
        _ conversation: MailConversationSnapshot,
        attachmentPayloads: [String: Data],
        headerProjection: [String],
        includeBody: Bool
    ) -> [String: Any] {
        [
            "id": conversation.id,
            "accountID": conversation.account.localID,
            "providerID": conversation.account.providerID,
            "accountIdentity": conversation.accountAddress,
            "snippet": conversation.snippet,
            "cursor": conversation.cursor ?? "",
            "messages": conversation.messages.map {
                WorkflowMailPayloadEncoder.messageObject(
                    $0, attachmentPayloads: attachmentPayloads,
                    headerProjection: headerProjection, includeBody: includeBody
                )
            },
        ]
    }
}

enum WorkflowMailPayloadEncoder {
    static func messageObject(
        _ message: MailMessageSnapshot,
        attachmentPayloads: [String: Data],
        headerProjection: [String] = [],
        includeBody: Bool = true
    ) -> [String: Any] {
        let requestedHeaders = Set(headerProjection.map { $0.lowercased() })
        return [
            "id": message.id,
            "conversationID": message.conversationID,
            "sender": message.sender,
            "recipients": message.recipients,
            "subject": message.subject,
            "date": message.dateDescription,
            "body": includeBody ? message.body : "",
            "resourceIDs": message.resourceIDs,
            "headers": message.projectedHeaders.filter { requestedHeaders.contains($0.key.lowercased()) },
            "attachments": message.attachments.map { attachment in
                let key = WorkflowEmailReadResponse.attachmentKey(attachment)
                let data = attachmentPayloads[key]
                return [
                    "id": attachment.attachmentID,
                    "messageID": attachment.messageID,
                    "filename": attachment.filename,
                    "mediaType": attachment.mediaType,
                    "size": attachment.size,
                    "sha256": data.map(DesktopWorkflowPackageCodec.digest) ?? "",
                    "dataBase64": data?.base64EncodedString() ?? "",
                ] as [String: Any]
            },
        ]
    }
}

struct WorkflowConnectorEffectInput {
    let connectorID: String
    let effectKind: String
    let accountID: String?
    let target: Data
    let payload: Data
    let artifactDigests: [String]
    let itemCount: Int
    let manuallyInitiated: Bool

    private struct Wire: Decodable {
        let connectorID: String
        let effectKind: String
        let accountID: String?
        let target: DesktopWorkflowJSONValue
        let payload: DesktopWorkflowJSONValue?
        let artifactDigests: [String]?
        let itemCount: Int
        let manuallyInitiated: Bool?
    }

    static func decode(_ data: Data) throws -> Self {
        try decodeWorkflowRequest(Wire.self, from: data, maximumBytes: 2 * 1_024 * 1_024) { wire in
            let request = Self(
                connectorID: wire.connectorID, effectKind: wire.effectKind, accountID: wire.accountID,
                target: try wire.target.canonicalData(),
                payload: try wire.payload?.canonicalData() ?? Data("{}".utf8),
                artifactDigests: wire.artifactDigests ?? [], itemCount: wire.itemCount,
                manuallyInitiated: wire.manuallyInitiated ?? false
            )
            guard request.connectorID.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil,
                  request.effectKind.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil,
                  (1...10_000).contains(request.itemCount),
                  request.artifactDigests.allSatisfy({
                      $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
                  }) else { throw DesktopWorkflowCapabilityError.outputInvalid }
            return request
        }
    }

    func request(for invocation: DesktopWorkflowCapabilityInvocation) -> DesktopWorkflowEffectRequest {
        DesktopWorkflowEffectRequest(
            workflowID: invocation.workflowID, workItemID: invocation.workItemID,
            episodeID: invocation.episodeID, runID: invocation.runID, stepID: invocation.step.id,
            connectorID: connectorID, effectKind: effectKind, accountID: accountID,
            target: target, payload: payload, artifactDigests: artifactDigests,
            itemCount: itemCount, manuallyInitiated: manuallyInitiated
        )
    }
}

struct WorkflowBoundedAgentRequest {
    let providerName: String
    let prompt: String
    let outputSchema: String

    var provider: WorkflowStructuredModelRequest.Provider {
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
        try decodeWorkflowRequest(
            WorkflowModelRequestWire.self, from: data, maximumBytes: 512 * 1_024
        ) { wire in
            try validateWorkflowModelRequest(
                providerName: wire.providerName, prompt: wire.prompt, outputSchema: wire.outputSchema
            )
            let request = Self(
                providerName: wire.providerName, prompt: wire.prompt, outputSchema: wire.outputSchema
            )
            _ = try request.provider
            return request
        }
    }
}

struct WorkflowAgentAction {
    enum Kind: String { case tool, finish }
    let kind: Kind
    let capabilityID: String?
    let input: Data?
    let output: Data?

    static let schema = #"{"type":"object","required":["kind"],"properties":{"kind":{"type":"string","enum":["tool","finish"]},"capabilityID":{"type":"string"},"input":{},"output":{}},"additionalProperties":false}"#

    static func decode(_ data: Data) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawKind = object["kind"] as? String, let kind = Kind(rawValue: rawKind) else {
            throw DesktopWorkflowCapabilityError.outputInvalid
        }
        let capabilityID = object["capabilityID"] as? String
        let input = try object["input"].map {
            try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        }
        let output = try object["output"].map {
            try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        }
        guard (kind == .tool && capabilityID != nil && input != nil && output == nil)
                || (kind == .finish && output != nil && capabilityID == nil && input == nil) else {
            throw DesktopWorkflowCapabilityError.outputInvalid
        }
        return Self(kind: kind, capabilityID: capabilityID, input: input, output: output)
    }
}
