import Foundation
import KanameConnectivity
import KanameDesktop

struct DesktopGmailWorkflowConnector: DesktopWorkflowConnector {
    let identifier = "kaname.gmail"
    let service: NativeGoogleIntegrationService

    func preview(_ request: DesktopWorkflowEffectRequest) async throws -> DesktopWorkflowEffectPreview {
        let target = try Target.decode(request.target, effectKind: request.effectKind, accountID: request.accountID)
        return DesktopWorkflowEffectPreview(
            title: target.title,
            summary: target.summary,
            exactTarget: "gmail:\(target.accountID):workflow-effect:sha256=\(DesktopWorkflowStructuredValue.digest(request.target))",
            structuredTarget: request.target,
            itemCount: target.threadIDs.count,
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
        var succeeded: [String] = []
        var failures: [String] = []
        for threadID in target.threadIDs {
            let mutation = target.mutation
            let exact = NativeGoogleIntegrationService.gmailMutationTarget(
                accountID: target.accountID, threadID: threadID, mutation: mutation
            )
            do {
                _ = try await service.mutateMailThread(
                    accountID: target.accountID, threadID: threadID, mutation: mutation,
                    grant: GmailMutationGrant(approvalID: idempotencyKey, exactTarget: exact)
                )
                succeeded.append(threadID)
            } catch {
                failures.append("\(threadID): \(error.localizedDescription)")
            }
        }
        let complete = failures.isEmpty
        return .result(
            remoteReceipt: "gmail:\(target.accountID):\(idempotencyKey)",
            // A transport failure after dispatch cannot prove whether Gmail
            // applied that individual mutation. Preserve the exact partial
            // result and force a separate postcondition re-read.
            outcomeKnown: complete, succeeded: complete,
            detail: complete
                ? "Gmail verified \(succeeded.count) of \(target.threadIDs.count) exact thread mutations."
                : "Gmail verified \(succeeded.count) mutations; \(failures.count) require reconciliation: \(failures.joined(separator: "; "))"
        )
    }

    func reconcile(
        _ request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview,
        idempotencyKey: String,
        priorReceipt: DesktopWorkflowConnectorExecutionReceipt?
    ) async throws -> DesktopWorkflowConnectorExecutionReceipt {
        let target = try Target.decode(request.target, effectKind: request.effectKind, accountID: request.accountID)
        var failures: [String] = []
        for threadID in target.threadIDs {
            let thread = try await service.readMailThread(accountID: target.accountID, threadID: threadID)
            if !GmailAPIParser.reconciled(mutation: target.mutation, labels: thread.labels) {
                failures.append(threadID)
            }
        }
        return .result(
            remoteReceipt: priorReceipt?.remoteReceipt,
            outcomeKnown: true, succeeded: failures.isEmpty,
            detail: failures.isEmpty
                ? "Gmail still satisfies the exact postcondition for \(target.threadIDs.count) threads."
                : "The Gmail postcondition no longer holds for \(failures.count) threads."
        )
    }

    private struct Target: Decodable {
        enum Operation: String, Decodable { case archive, trash, markRead, labels }
        let accountID: String
        let operation: Operation
        let threadIDs: [String]
        let addLabelIDs: [String]?
        let removeLabelIDs: [String]?

        private var addedLabels: [String] { addLabelIDs ?? [] }
        private var removedLabels: [String] { removeLabelIDs ?? [] }

        static func decode(_ data: Data, effectKind: String, accountID: String?) throws -> Self {
            guard let target = try? JSONDecoder().decode(Self.self, from: data),
                  accountID == target.accountID,
                  effectKind == "gmail.\(target.operation.rawValue)",
                  !target.accountID.isEmpty,
                  !target.threadIDs.isEmpty, target.threadIDs.count <= 10_000,
                  Set(target.threadIDs).count == target.threadIDs.count,
                  target.threadIDs.allSatisfy({ (try? GmailAPIParser.validatedID($0)) != nil }),
                  target.addedLabels.count <= 100, target.removedLabels.count <= 100,
                  target.addedLabels.allSatisfy({ (try? GmailAPIParser.validatedID($0)) != nil }),
                  target.removedLabels.allSatisfy({ (try? GmailAPIParser.validatedID($0)) != nil }) else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("invalid Gmail workflow effect target")
            }
            return target
        }

        var mutation: GmailThreadMutation {
            switch operation {
            case .archive: .archive
            case .trash: .trash
            case .markRead: .applyLabels(add: [], remove: ["UNREAD"])
            case .labels: .applyLabels(add: addedLabels, remove: removedLabels)
            }
        }

        var title: String {
            switch operation {
            case .archive: "Archive \(threadIDs.count) Gmail thread\(threadIDs.count == 1 ? "" : "s")"
            case .trash: "Move \(threadIDs.count) Gmail thread\(threadIDs.count == 1 ? "" : "s") to Trash"
            case .markRead: "Mark \(threadIDs.count) Gmail thread\(threadIDs.count == 1 ? "" : "s") read"
            case .labels: "Change labels on \(threadIDs.count) Gmail thread\(threadIDs.count == 1 ? "" : "s")"
            }
        }

        var summary: String {
            "Exact account \(accountID) · \(threadIDs.count) frozen thread ID\(threadIDs.count == 1 ? "" : "s")."
        }

        var postcondition: String {
            switch operation {
            case .archive: "Every selected thread is re-read and no longer has the INBOX label."
            case .trash: "Every selected thread is re-read and has the TRASH label."
            case .markRead: "Every selected thread is re-read and no longer has the UNREAD label."
            case .labels: "Every selected thread is re-read and matches the exact added and removed label sets."
            }
        }
    }
}
