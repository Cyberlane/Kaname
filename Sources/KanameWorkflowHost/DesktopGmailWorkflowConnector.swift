import Foundation
import KanameConnectivity
import KanameDesktop

struct DesktopMailWorkflowConnector: DesktopWorkflowConnector {
    let identifier = "kaname.mail"
    let adapter: any MailProviderAdapter

    func preview(_ request: DesktopWorkflowEffectRequest) async throws -> DesktopWorkflowEffectPreview {
        let target = try Target.decode(request.target, effectKind: request.effectKind, accountID: request.accountID)
        return DesktopWorkflowEffectPreview(
            title: target.title,
            summary: target.summary,
            exactTarget: "mail:\(adapter.identity.id):\(target.accountID):workflow-effect:sha256=\(DesktopWorkflowStructuredValue.digest(request.target))",
            structuredTarget: request.target,
            itemCount: target.conversationIDs.count,
            consequences: [target.postcondition],
            reversible: target.operation != .trash
        )
    }

    func execute(
        _ request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview,
        idempotencyKey: String
    ) async throws -> DesktopWorkflowConnectorExecutionReceipt {
        let target = try Target.decode(request.target, effectKind: request.effectKind, accountID: request.accountID)
        let result = await MailMutationBatchExecutor(adapter: adapter).execute(
            accountID: target.accountID, conversationIDs: target.conversationIDs,
            mutation: target.mutation, approvalID: idempotencyKey
        )
        let failures = result.failures.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
        let complete = result.outcomeKnown
        return .result(
            remoteReceipt: "mail:\(adapter.identity.id):\(target.accountID):\(idempotencyKey)",
            // A transport failure after dispatch cannot prove whether a provider
            // applied that individual mutation. Preserve the exact partial
            // result and force a separate postcondition re-read.
            outcomeKnown: complete, succeeded: complete,
            detail: complete
                ? "The mail provider verified \(result.succeededConversationIDs.count) of \(target.conversationIDs.count) exact conversation mutations."
                : "The mail provider verified \(result.succeededConversationIDs.count) mutations; \(failures.count) require reconciliation: \(failures.joined(separator: "; "))"
        )
    }

    func reconcile(
        _ request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview,
        idempotencyKey: String,
        priorReceipt: DesktopWorkflowConnectorExecutionReceipt?
    ) async throws -> DesktopWorkflowConnectorExecutionReceipt {
        let target = try Target.decode(request.target, effectKind: request.effectKind, accountID: request.accountID)
        let result = await MailMutationBatchExecutor(adapter: adapter).reconcile(
            accountID: target.accountID, conversationIDs: target.conversationIDs, mutation: target.mutation
        )
        return .result(
            remoteReceipt: priorReceipt?.remoteReceipt,
            outcomeKnown: true, succeeded: result.failures.isEmpty,
            detail: result.failures.isEmpty
                ? "The provider still satisfies the exact postcondition for \(target.conversationIDs.count) conversations."
                : "The provider postcondition no longer holds for \(result.failures.count) conversations."
        )
    }

    private struct Target: Decodable {
        enum Operation: String, Decodable { case archive, trash, markRead, resources, labels }
        let accountID: String
        let operation: Operation
        let conversationIDs: [String]
        let addResourceIDs: [String]?
        let removeResourceIDs: [String]?

        private var addedResources: [String] { addResourceIDs ?? [] }
        private var removedResources: [String] { removeResourceIDs ?? [] }

        private enum CodingKeys: String, CodingKey {
            case accountID, operation, conversationIDs, threadIDs
            case addResourceIDs, removeResourceIDs, addLabelIDs, removeLabelIDs
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            accountID = try values.decode(String.self, forKey: .accountID)
            operation = try values.decode(Operation.self, forKey: .operation)
            conversationIDs = try values.decodeIfPresent([String].self, forKey: .conversationIDs)
                ?? values.decodeIfPresent([String].self, forKey: .threadIDs) ?? []
            addResourceIDs = try values.decodeIfPresent([String].self, forKey: .addResourceIDs)
                ?? values.decodeIfPresent([String].self, forKey: .addLabelIDs)
            removeResourceIDs = try values.decodeIfPresent([String].self, forKey: .removeResourceIDs)
                ?? values.decodeIfPresent([String].self, forKey: .removeLabelIDs)
        }

        static func decode(_ data: Data, effectKind: String, accountID: String?) throws -> Self {
            guard let target = try? JSONDecoder().decode(Self.self, from: data),
                  accountID == target.accountID,
                  effectKind == "mail.\(target.operation.rawValue)",
                  !target.accountID.isEmpty,
                  !target.conversationIDs.isEmpty, target.conversationIDs.count <= 10_000,
                  Set(target.conversationIDs).count == target.conversationIDs.count,
                  target.conversationIDs.allSatisfy(Self.validIdentifier),
                  target.addedResources.count <= 100, target.removedResources.count <= 100,
                  target.addedResources.allSatisfy(Self.validIdentifier),
                  target.removedResources.allSatisfy(Self.validIdentifier) else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("invalid mail workflow effect target")
            }
            return target
        }

        private static func validIdentifier(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 2_048
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }

        var mutation: MailConversationMutation {
            switch operation {
            case .archive: .archive
            case .trash: .trash
            case .markRead: .markRead
            case .resources, .labels: .applyResources(add: addedResources, remove: removedResources)
            }
        }

        var title: String {
            switch operation {
            case .archive: "Archive \(conversationIDs.count) mail conversation\(conversationIDs.count == 1 ? "" : "s")"
            case .trash: "Move \(conversationIDs.count) mail conversation\(conversationIDs.count == 1 ? "" : "s") to Trash"
            case .markRead: "Mark \(conversationIDs.count) mail conversation\(conversationIDs.count == 1 ? "" : "s") read"
            case .resources, .labels: "Change resources on \(conversationIDs.count) mail conversation\(conversationIDs.count == 1 ? "" : "s")"
            }
        }

        var summary: String {
            "Exact account \(accountID) · \(conversationIDs.count) frozen conversation ID\(conversationIDs.count == 1 ? "" : "s")."
        }

        var postcondition: String {
            switch operation {
            case .archive: "Every selected conversation is re-read and no longer belongs to the provider inbox resource."
            case .trash: "Every selected conversation is re-read and belongs to the provider trash resource."
            case .markRead: "Every selected conversation is re-read and no longer has the provider unread state."
            case .resources, .labels: "Every selected conversation is re-read and matches the exact added and removed resource sets."
            }
        }
    }
}
