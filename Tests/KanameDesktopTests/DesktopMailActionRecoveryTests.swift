import Foundation
@testable import KanameConnectivity
@testable import KanameDesktop
@testable import KanameWorkflowHost
import Testing

@MainActor
struct DesktopMailActionRecoveryTests {
    @Test
    func selectingMailLabelScopesSearchAndChangingAccountClearsIt() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-mail-label-selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = DesktopMailViewModel(environment: KanameDesktopEnvironment(
            channel: .development,
            applicationSupportDirectory: root
        ))
        let label = GmailLabelSnapshot(id: "Label_42", name: "Kaname", type: "user")

        viewModel.selectLabel(accountID: "account-1", label: label)
        #expect(viewModel.query.isEmpty)
        #expect(viewModel.selectedLabel == DesktopMailLabelSelection(accountID: "account-1", label: label))

        viewModel.setAccountScope("account-2")
        #expect(viewModel.selectedLabel == nil)
        #expect(!viewModel.hasNextPage)
    }

    @Test
    func selectingThreadAfterApprovalRestoresExactTrashActionWithoutCreatingAnotherProposal() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-mail-action-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { 14_000 }
        )
        let thread = GmailThreadDetailSnapshot(
            id: "thread-1",
            accountID: "account-1",
            accountIdentity: "one@example.test",
            snippet: "Publication notice",
            historyID: "history-1",
            messages: []
        )
        let target = NativeGoogleIntegrationService.gmailMutationTarget(
            accountID: thread.accountID,
            threadID: thread.id,
            mutation: .trash
        )
        let approvedActionID = try #require(model.recordMailAction(
            accountID: thread.accountID,
            accountIdentity: thread.accountIdentity,
            threadID: thread.id,
            kind: .trash,
            preview: "Move this exact thread to Trash.",
            exactTarget: target
        ))
        let approvalID = try #require(model.createApproval(
            threadID: nil,
            title: "Move to Trash",
            exactTarget: target,
            consequence: "Move this exact thread to Trash.",
            dataLeavingDevice: "Account and thread identifiers",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.attachMailApproval(actionID: approvedActionID, approvalID: approvalID)
        model.resolveApproval(id: approvalID, approved: true)
        _ = model.recordMailAction(
            accountID: thread.accountID,
            accountIdentity: thread.accountIdentity,
            threadID: thread.id,
            kind: .trash,
            preview: "Move this exact thread to Trash.",
            exactTarget: target
        )

        let viewModel = DesktopMailViewModel(environment: KanameDesktopEnvironment(
            channel: .candidate,
            applicationSupportDirectory: root
        ))
        let restoredMutation = viewModel.select(thread, model: model)

        #expect(restoredMutation == .trash)
        #expect(viewModel.activeActionID == approvedActionID)
        #expect(viewModel.message == "Restored the exact approved Gmail action. Apply it here when ready.")

        let actionCount = model.snapshot.operations.mailActions.count
        viewModel.proposeThreadMutation(
            model: model,
            thread: thread,
            mutation: .trash,
            preview: "Move this exact thread to Trash.",
            kind: .trash
        )
        #expect(viewModel.activeActionID == approvedActionID)
        #expect(model.snapshot.operations.mailActions.count == actionCount)
    }
}
