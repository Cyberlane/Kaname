import KanameDesktop
import KanameDesktopUI
import KanameLinkHost
import Testing

@Suite("Kaname Desktop semantic status presentation")
struct KanameDesktopStatusPresentationTests {
    @Test("every Desktop record state has explicit status semantics")
    func recordsAreExhaustive() {
        let presentations = DesktopRecordState.allCases.map(KanameDesktopStatusPresentation.record)
        #expect(presentations.count == 9)
        #expect(presentations.allSatisfy { $0.accessibilityLabel.hasPrefix("Status: ") })
        #expect(KanameDesktopStatusPresentation.record(.failed).tone == .danger)
        #expect(KanameDesktopStatusPresentation.record(.needsReview).tone == .attention)
    }

    @Test("every action and attention state has explicit semantics")
    func workflowStatesAreExhaustive() {
        let actions = DesktopActionState.allCases.map(KanameDesktopStatusPresentation.action)
        let attention = DesktopAttention.allCases.map(KanameDesktopStatusPresentation.attention)
        let workflow = DesktopWorkflowWorkState.allCases.map(KanameDesktopStatusPresentation.workflow)
        #expect(actions.count == 10)
        #expect(attention.count == 8)
        #expect(workflow.count == 11)
        #expect(actions.allSatisfy { $0.accessibilityLabel.hasPrefix("Action status: ") })
        #expect(attention.allSatisfy { $0.accessibilityLabel.hasPrefix("Attention: ") })
        #expect(workflow.allSatisfy { $0.accessibilityLabel.hasPrefix("Workflow status: ") })
        #expect(KanameDesktopStatusPresentation.action(.interrupted).tone == .blocked)
        #expect(KanameDesktopStatusPresentation.workflow(.waitingExternal).tone == .external)
        #expect(KanameDesktopStatusPresentation.workflow(.failed).tone == .danger)
    }

    @Test("Link lifecycle and publication states preserve distinct meanings")
    func linkStatesAreExhaustive() {
        let gateway = KanameLinkGatewayLifecycle.allCases.map(KanameDesktopLinkStatusPresentation.gateway)
        let publicationStates: [KanameLinkPublicationState] = [.preview, .gatewayAccepted, .withdrawn]
        let receiptStages: [KanameLinkReceiptStage] = [
            .savedLocally, .gatewayAccepted, .relayAccepted, .delivered, .opened, .failed,
        ]
        let publications = publicationStates.map(KanameDesktopLinkStatusPresentation.publication)
        let receipts = receiptStages.map(KanameDesktopLinkStatusPresentation.receipt)
        #expect(gateway.count == 4)
        #expect(publications.count == 3)
        #expect(receipts.count == 6)
        #expect(gateway.allSatisfy { $0.accessibilityLabel.hasPrefix("Gateway status: ") })
        #expect(publications.allSatisfy { $0.accessibilityLabel.hasPrefix("Publication status: ") })
        #expect(receipts.allSatisfy { $0.accessibilityLabel.hasPrefix("Receipt status: ") })
        #expect(KanameDesktopLinkStatusPresentation.gateway(.ready).tone == .success)
        #expect(KanameDesktopLinkStatusPresentation.gateway(.offline).tone == .warning)
        #expect(KanameDesktopLinkStatusPresentation.publication(.withdrawn).tone == .neutral)
        #expect(KanameDesktopLinkStatusPresentation.receipt(.failed).tone == .danger)
        #expect(KanameDesktopLinkStatusPresentation.receipt(.opened).tone == .success)
    }

    @Test("external collaboration badges name authority boundaries")
    func externalAuthorityIsExplicit() {
        #expect(KanameDesktopLinkStatusPresentation.linkOnly.accessibilityLabel == "Scope: Link only")
        #expect(KanameDesktopLinkStatusPresentation.externalDevice.tone == .attention)
        #expect(KanameDesktopLinkStatusPresentation.externalUntrusted.tone == .external)
        #expect(KanameDesktopLinkStatusPresentation.externalMessages(1).accessibilityLabel == "1 external message needs attention")
        #expect(KanameDesktopLinkStatusPresentation.externalMessages(2).accessibilityLabel == "2 external messages need attention")
    }
}
