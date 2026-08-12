import Foundation
@testable import KanameDesktop
import Testing

@MainActor
struct DesktopWorkflowPlatformTests {
    private let capabilities: Set<String> = [
        "kaname.context.compile", "kaname.model.structured", "kaname.validation.run",
        "kaname.email.draft", "kaname.email.send"
    ]

    @Test
    func packageInstallIsVersionedDisabledByDefaultAndRejectsAuthorityBroadening() throws {
        let model = DesktopAppModel(store: WorkflowMemoryDesktopStateStore(), now: { 1_000 })
        let first = manifest(version: "1.0.0", permissions: [.emailRead, .emailDraft, .emailSend])
        let firstID = try model.installWorkflowPackage(
            manifestData: encoded(first), registeredCapabilityIDs: capabilities
        )

        #expect(model.workflowDefinitions.count == 1)
        #expect(model.workflowDefinitions[0].enabled == false)
        #expect(model.workflowDefinitions[0].currentRevisionID == firstID)
        #expect(model.setWorkflowEnabled(id: first.id, enabled: true))

        let broadened = manifest(version: "1.1.0", permissions: [.emailRead, .emailDraft, .emailSend, .fileWrite])
        #expect(throws: DesktopWorkflowPackageError.permissionBroadening) {
            try model.installWorkflowPackage(
                manifestData: encoded(broadened), registeredCapabilityIDs: capabilities, enable: true
            )
        }

        let installedDisabled = try model.installWorkflowPackage(
            manifestData: encoded(broadened), registeredCapabilityIDs: capabilities, enable: false
        )
        #expect(installedDisabled != firstID)
        #expect(model.workflowDefinitions[0].enabled == false)
        #expect(model.snapshot.operations.workflows.revisions.count == 2)
    }

    @Test
    func packageCodecRejectsUnknownCapabilityAndUnsafeRetry() throws {
        var unknown = manifest(version: "1.0.0", permissions: [.emailRead, .emailDraft])
        unknown = replacingSteps(unknown, with: [
            DesktopWorkflowStepDefinition(
                id: "unsafe", name: "Unsafe", kind: .invokeTool,
                capabilityID: "private.absolute.executable"
            )
        ])
        #expect(throws: DesktopWorkflowPackageError.unsafeCapability) {
            try DesktopWorkflowPackageCodec.decode(encoded(unknown), registeredCapabilityIDs: capabilities)
        }

        var retry = manifest(version: "1.0.0", permissions: [.emailRead, .emailDraft])
        retry = replacingSteps(retry, with: [
            DesktopWorkflowStepDefinition(
                id: "send", name: "Send", kind: .sendEmail,
                capabilityID: "kaname.email.send", retryLimit: 1, isIdempotent: false
            )
        ], permissions: [.emailSend])
        #expect(throws: DesktopWorkflowPackageError.invalidSteps) {
            try DesktopWorkflowPackageCodec.decode(encoded(retry), registeredCapabilityIDs: capabilities)
        }

        var duplicateInputs = manifest(version: "1.0.0", permissions: [.emailRead, .emailDraft])
        duplicateInputs = replacingSteps(duplicateInputs, with: [
            DesktopWorkflowStepDefinition(
                id: "validate", name: "Validate", kind: .validate,
                capabilityID: "kaname.validation.run",
                artifactInputs: [.init(role: "current-report"), .init(role: "current-report")]
            )
        ])
        #expect(throws: DesktopWorkflowPackageError.invalidSteps) {
            try DesktopWorkflowPackageCodec.decode(encoded(duplicateInputs), registeredCapabilityIDs: capabilities)
        }
    }

    @Test
    func shippedSyntheticPackageDecodesAgainstRegisteredCapabilities() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Examples/Workflows/document-revision.workflow.json")
        let package = try DesktopWorkflowPackageCodec.decode(
            Data(contentsOf: url), registeredCapabilityIDs: capabilities
        )
        #expect(package.id == "org.example.document-revision")
        #expect(package.steps.count == 5)
        #expect(!package.permissions.permissions.contains(.emailSend))
    }

    @Test
    func triggerBindingRequiresExplicitAccountScopeAndFollowsDefinitionDisable() throws {
        let model = DesktopAppModel(store: WorkflowMemoryDesktopStateStore(), now: { 5_000 })
        try installAndEnable(model)
        #expect(model.bindWorkflowTrigger(
            workflowID: "org.example.document-revision", trigger: .email, source: "gmail",
            accountIDs: [], sourceFilter: "from:fictional@example.test"
        ) == nil)
        let bindingID = try #require(model.bindWorkflowTrigger(
            workflowID: "org.example.document-revision", trigger: .email, source: "gmail",
            accountIDs: ["account-a"], sourceFilter: "from:fictional@example.test", enabled: true
        ))
        #expect(model.workflowTriggerBindings().first?.enabled == true)
        #expect(model.advanceWorkflowTriggerCursor(id: bindingID, cursor: "history-42"))
        #expect(model.workflowTriggerBindings().first?.lastCursor == "history-42")
        #expect(model.setWorkflowEnabled(id: "org.example.document-revision", enabled: false))
        #expect(model.workflowTriggerBindings().first?.enabled == false)
        #expect(model.setWorkflowTriggerBindingEnabled(id: bindingID, enabled: true) == false)
    }

    @Test
    func duplicateEmailObservationCreatesOneEventAndOneEpisode() throws {
        let store = WorkflowMemoryDesktopStateStore()
        var clock: Int64 = 10_000
        let model = DesktopAppModel(store: store, now: { clock })
        try installAndEnable(model)
        let workID = try #require(model.createWorkflowWorkItem(
            workflowID: "org.example.document-revision", title: "Northstar revision", goal: "Review a fictional document"
        ))
        let eventID = try #require(model.observeWorkflowExternalEvent(
            source: "gmail", accountID: "account-a", conversationID: "thread-1", messageID: "message-1",
            cursor: "history-10", payloadDigest: "digest-a", deduplicationKey: "gmail:account-a:message-1"
        ))
        clock += 1
        #expect(model.observeWorkflowExternalEvent(
            source: "gmail", accountID: "account-a", conversationID: "thread-1", messageID: "message-1",
            cursor: "history-11", payloadDigest: "digest-a", deduplicationKey: "gmail:account-a:message-1"
        ) == eventID)
        #expect(model.snapshot.operations.workflows.externalEvents.count == 1)

        _ = try #require(model.bindWorkflowConversation(
            workItemID: workID, source: "gmail", accountID: "account-a", conversationID: "thread-1",
            relationship: .primary, reason: "Exact fictional request identifier", confidence: 1, requiresReview: false
        ))
        let episodeID = try #require(model.createWorkflowEpisode(
            workItemID: workID, sourceEventID: eventID, sourceMessageID: "message-1", intent: .request,
            summary: "Revise the attached fictional document.", deltaSummary: "Initial request"
        ))
        #expect(model.createWorkflowEpisode(
            workItemID: workID, sourceEventID: eventID, sourceMessageID: "message-1", intent: .request,
            summary: "Duplicate replay", deltaSummary: "Duplicate"
        ) == episodeID)
        #expect(model.workflowEpisodes(workItemID: workID).count == 1)

        let restored = DesktopAppModel(store: store, now: { 20_000 })
        #expect(restored.workflowWorkItems(accountID: "account-a", conversationID: "thread-1").map(\.id) == [workID])
        #expect(restored.workflowEpisodes(workItemID: workID).map(\.id) == [episodeID])
    }

    @Test
    func correctionSupersedesPriorEpisodeAndContextExcludesSupersededFact() throws {
        let model = DesktopAppModel(store: WorkflowMemoryDesktopStateStore(), now: { 30_000 })
        try installAndEnable(model)
        let workID = try #require(model.createWorkflowWorkItem(
            workflowID: "org.example.document-revision", title: "Northstar revision", goal: "Produce a correct fictional revision"
        ))
        let firstEvent = try #require(event(model, message: "message-1", digest: "digest-1"))
        let firstEpisode = try #require(model.createWorkflowEpisode(
            workItemID: workID, sourceEventID: firstEvent, sourceMessageID: "message-1", intent: .request,
            summary: "Initial document request", deltaSummary: "Initial request"
        ))
        let oldFact = try #require(model.recordWorkflowFact(
            workItemID: workID, episodeID: firstEpisode, key: "required-format", value: "PDF",
            state: .verified, sourceReferenceIDs: ["message-1"], verifiedBy: "fixture"
        ))
        let secondEvent = try #require(event(model, message: "message-2", digest: "digest-2"))
        let correction = try #require(model.createWorkflowEpisode(
            workItemID: workID, sourceEventID: secondEvent, sourceMessageID: "message-2", intent: .correction,
            summary: "Use DOCX instead", deltaSummary: "Output format changed from PDF to DOCX"
        ))
        let newFact = try #require(model.recordWorkflowFact(
            workItemID: workID, episodeID: correction, key: "required-format", value: "DOCX",
            state: .verified, sourceReferenceIDs: ["message-2"], verifiedBy: "fixture", supersedesFactID: oldFact
        ))
        #expect(model.workflowEpisodes(workItemID: workID).first?.state == .superseded)
        #expect(model.workflowFacts(workItemID: workID).map(\.id) == [newFact])
        #expect(model.workflowFacts(workItemID: workID, includeInactive: true).first(where: { $0.id == oldFact })?.state == .superseded)

        let contextID = try #require(model.compileWorkflowContext(
            workItemID: workID, episodeID: correction, request: "Create the corrected fictional document.",
            references: [
                reference(id: "current", included: true, tokens: 300),
                reference(id: "obsolete", included: false, tokens: 200, reason: "Superseded by message-2")
            ], negativeConstraints: ["Do not use the superseded PDF requirement"]
        ))
        let context = try #require(model.snapshot.operations.workflows.contextSnapshots.first { $0.id == contextID })
        #expect(context.references.first(where: { $0.id == "current" })?.included == true)
        #expect(context.references.first(where: { $0.id == "obsolete" })?.included == false)
        #expect(context.negativeConstraints == [
            "Do not use inactive knowledge required-format=PDF.",
            "Do not use the superseded PDF requirement",
        ])
        #expect(context.knowledge?.map(\.id) == [newFact])
        let modelPrompt = try #require(DesktopWorkflowModelContextCompiler.augment(
            prompt: "Produce structured output.", context: context
        ))
        #expect(modelPrompt.contains("required-format: DOCX"))
        #expect(modelPrompt.contains("Do not use inactive knowledge required-format=PDF."))
        #expect(modelPrompt.contains("Context digest: \(context.digest)"))
        #expect(DesktopWorkflowModelContextCompiler.augment(
            prompt: "Produce structured output.", context: context, maximumBytes: 16
        ) == nil)
        #expect(!context.digest.isEmpty)

        let proposal = try #require(model.recordWorkflowFact(
            workItemID: workID, episodeID: correction, key: "required-format", value: "ODT",
            state: .proposed, sourceReferenceIDs: ["message-2"], supersedesFactID: newFact
        ))
        #expect(model.workflowFacts(workItemID: workID).first(where: { $0.id == newFact })?.state == .verified)
        #expect(model.reviewWorkflowKnowledge(id: proposal, accepted: true, reviewer: "fixture reviewer"))
        #expect(model.workflowFacts(workItemID: workID, includeInactive: true).first(where: { $0.id == newFact })?.state == .superseded)
        #expect(model.workflowFacts(workItemID: workID).first(where: { $0.id == proposal })?.state == .verified)
        #expect(model.snapshot.operations.audit.contains {
            $0.domain == "workflow-knowledge" && $0.action == "verified" && $0.target == proposal
        })
    }

    @Test
    func blockingValidationPreventsEffectAndUnknownSendOutcomeCannotRetry() throws {
        let model = DesktopAppModel(store: WorkflowMemoryDesktopStateStore(), now: { 40_000 })
        try installAndEnable(model)
        let setup = try workflowRun(model)
        let attemptID = try #require(model.beginWorkflowStep(
            runID: setup.runID, stepID: "compile-context", inputDigest: "input-digest"
        ))
        #expect(model.completeWorkflowStep(attemptID: attemptID, outputDigest: "output-digest"))

        _ = try #require(model.recordWorkflowValidation(
            workItemID: setup.workID, episodeID: setup.episodeID, runID: setup.runID,
            validatorID: "example.schema", validatorRevision: "1", targetID: "artifact-1",
            severity: .blocking, outcome: .failed, summary: "Required fictional heading is missing."
        ))
        #expect(model.proposeWorkflowEffect(
            workItemID: setup.workID, episodeID: setup.episodeID, runID: setup.runID, stepID: "send-email",
            kind: "email-send", accountID: "account-a", exactTarget: "gmail:send:exact",
            contentDigest: "body-v1", attachmentDigests: ["file-v1"]
        ) == nil)

        let clean = try workflowRun(model, suffix: "-clean")
        _ = try #require(model.recordWorkflowValidation(
            workItemID: clean.workID, episodeID: clean.episodeID, runID: clean.runID,
            validatorID: "example.schema", validatorRevision: "1", targetID: "artifact-2",
            severity: .blocking, outcome: .passed, summary: "All fictional checks passed."
        ))
        let effectID = try #require(model.proposeWorkflowEffect(
            workItemID: clean.workID, episodeID: clean.episodeID, runID: clean.runID, stepID: "send-email",
            kind: "email-send", accountID: "account-a", exactTarget: "gmail:send:exact-clean",
            contentDigest: "body-v2", attachmentDigests: ["file-v2"]
        ))
        let approvalID = try #require(model.createApproval(
            threadID: nil, title: "Send fictional email", exactTarget: "gmail:send:exact-clean",
            consequence: "Send one fictional reply.", dataLeavingDevice: "Fictional body and attachment", reversible: false,
            expiresAtUnixMillis: nil
        ))
        #expect(model.attachWorkflowEffectApproval(effectID: effectID, approvalID: approvalID))
        model.resolveApproval(id: approvalID, approved: true)
        #expect(model.beginWorkflowEffect(effectID: effectID))
        #expect(model.reconcileWorkflowEffect(effectID: effectID, receipt: nil, outcomeKnown: false, succeeded: false))
        #expect(model.snapshot.operations.workflows.effects.first(where: { $0.id == effectID })?.state == .outcomeUnknown)
        #expect(model.beginWorkflowEffect(effectID: effectID) == false)
        #expect(model.snapshot.operations.workflows.workItems.first(where: { $0.id == clean.workID })?.nextAction.contains("Reconcile") == true)
    }

    @Test
    func ambiguousCorrelationRequiresReviewAndOneWorkItemMaySpanThreads() throws {
        let model = DesktopAppModel(store: WorkflowMemoryDesktopStateStore(), now: { 50_000 })
        try installAndEnable(model)
        let workID = try #require(model.createWorkflowWorkItem(
            workflowID: "org.example.document-revision", title: "Northstar revision", goal: "Span two fictional threads"
        ))
        let ambiguous = try #require(model.bindWorkflowConversation(
            workItemID: workID, source: "gmail", accountID: "account-a", conversationID: "thread-a",
            relationship: .primary, reason: "Similar subject only", confidence: 0.62, requiresReview: true
        ))
        #expect(model.snapshot.operations.workflows.workItems.first(where: { $0.id == workID })?.state == .needsAttention)
        #expect(model.reviewWorkflowConversationBinding(id: ambiguous, accepted: true))
        _ = try #require(model.bindWorkflowConversation(
            workItemID: workID, source: "gmail", accountID: "account-a", conversationID: "thread-b",
            relationship: .continuation, reason: "Exact fictional document identifier", confidence: 1, requiresReview: false
        ))
        #expect(model.workflowWorkItems(accountID: "account-a", conversationID: "thread-a").map(\.id) == [workID])
        #expect(model.workflowWorkItems(accountID: "account-a", conversationID: "thread-b").map(\.id) == [workID])
    }

    @Test
    func orderedRuntimeCursorCompletesOnlyAfterEveryFrozenStage() throws {
        let model = DesktopAppModel(store: WorkflowMemoryDesktopStateStore(), now: { 60_000 })
        try installAndEnable(model)
        let setup = try workflowRun(model)
        #expect(model.completeWorkflowRun(id: setup.runID) == false)
        #expect(model.nextWorkflowStep(runID: setup.runID)?.id == "compile-context")
        for stepID in ["compile-context", "validate", "send-email"] {
            let attemptID = try #require(model.beginWorkflowStep(
                runID: setup.runID, stepID: stepID, inputDigest: "input-\(stepID)"
            ))
            #expect(model.nextWorkflowStep(runID: setup.runID) == nil)
            #expect(model.completeWorkflowStep(attemptID: attemptID, outputDigest: "output-\(stepID)"))
        }
        #expect(model.nextWorkflowStep(runID: setup.runID) == nil)
        #expect(model.completeWorkflowRun(id: setup.runID))
        #expect(model.workflowRuns(episodeID: setup.episodeID).first?.state == .completed)
    }

    private func installAndEnable(_ model: DesktopAppModel) throws {
        _ = try model.installWorkflowPackage(
            manifestData: encoded(manifest(version: "1.0.0", permissions: [.emailRead, .emailDraft, .emailSend])),
            registeredCapabilityIDs: capabilities
        )
        #expect(model.setWorkflowEnabled(id: "org.example.document-revision", enabled: true))
    }

    private func event(_ model: DesktopAppModel, message: String, digest: String) -> String? {
        model.observeWorkflowExternalEvent(
            source: "gmail", accountID: "account-a", conversationID: "thread-1", messageID: message,
            cursor: nil, payloadDigest: digest, deduplicationKey: "gmail:account-a:\(message)"
        )
    }

    private func workflowRun(_ model: DesktopAppModel, suffix: String = "") throws -> (workID: String, episodeID: String, runID: String) {
        let workID = try #require(model.createWorkflowWorkItem(
            workflowID: "org.example.document-revision", title: "Northstar\(suffix)", goal: "Run a fictional workflow"
        ))
        let eventID = try #require(model.observeWorkflowExternalEvent(
            source: "gmail", accountID: "account-a", conversationID: "thread\(suffix)", messageID: "message\(suffix)",
            cursor: nil, payloadDigest: "payload\(suffix)", deduplicationKey: "event\(suffix)"
        ))
        let episodeID = try #require(model.createWorkflowEpisode(
            workItemID: workID, sourceEventID: eventID, sourceMessageID: "message\(suffix)", intent: .request,
            summary: "Fictional request", deltaSummary: "Initial"
        ))
        let contextID = try #require(model.compileWorkflowContext(
            workItemID: workID, episodeID: episodeID, request: "Process the fictional request.", references: []
        ))
        let runID = try #require(model.queueWorkflowRun(
            workItemID: workID, episodeID: episodeID, contextSnapshotID: contextID
        ))
        return (workID, episodeID, runID)
    }

    private func reference(id: String, included: Bool, tokens: Int, reason: String = "Selected by workflow contract") -> DesktopWorkflowContextReference {
        DesktopWorkflowContextReference.reference(
            id: id, kind: "email-message", label: id, sourceID: id, digest: "digest-\(id)",
            included: included, reason: reason, estimatedTokens: tokens
        )
    }

    private func encoded(_ manifest: DesktopWorkflowPackageManifest) throws -> Data {
        try DesktopWorkflowPackageCodec.canonicalData(manifest)
    }

    private func manifest(version: String, permissions: [DesktopWorkflowPermission]) -> DesktopWorkflowPackageManifest {
        DesktopWorkflowPackageManifest(
            schemaVersion: 1,
            id: "org.example.document-revision",
            name: "Document revision",
            summary: "A fictional multi-turn document revision example.",
            icon: "doc.text.magnifyingglass",
            version: version,
            source: "Synthetic Kaname fixture",
            license: "MIT",
            triggers: [.email, .manual],
            steps: [
                DesktopWorkflowStepDefinition(
                    id: "compile-context", name: "Compile current context", kind: .compileContext,
                    capabilityID: "kaname.context.compile"
                ),
                DesktopWorkflowStepDefinition(
                    id: "validate", name: "Validate output", kind: .validate,
                    capabilityID: "kaname.validation.run"
                ),
                DesktopWorkflowStepDefinition(
                    id: "send-email", name: "Send approved reply", kind: .sendEmail,
                    capabilityID: "kaname.email.send", retryLimit: 0, isIdempotent: false
                )
            ],
            permissions: DesktopWorkflowPermissionEnvelope(
                permissions: permissions,
                accountIDs: ["account-a"],
                capabilityIDs: ["kaname.context.compile", "kaname.validation.run", "kaname.email.send"],
                dataClassesLeavingDevice: permissions.contains(.emailSend) ? ["fictional reply"] : []
            ),
            correlationSummary: "Use an exact fictional document identifier; ask when ambiguous.",
            contextSummary: "Latest instruction, active facts, current artifacts, and superseded exclusions.",
            completionSummary: "All blocking checks pass and an exact effect is reconciled."
        )
    }

    private func replacingSteps(
        _ manifest: DesktopWorkflowPackageManifest,
        with steps: [DesktopWorkflowStepDefinition],
        permissions: [DesktopWorkflowPermission]? = nil
    ) -> DesktopWorkflowPackageManifest {
        DesktopWorkflowPackageManifest(
            schemaVersion: manifest.schemaVersion, id: manifest.id, name: manifest.name,
            summary: manifest.summary, icon: manifest.icon, version: manifest.version,
            source: manifest.source, license: manifest.license, triggers: manifest.triggers,
            steps: steps,
            permissions: DesktopWorkflowPermissionEnvelope(
                permissions: permissions ?? manifest.permissions.permissions,
                accountIDs: manifest.permissions.accountIDs,
                capabilityIDs: steps.compactMap(\.capabilityID),
                dataClassesLeavingDevice: manifest.permissions.dataClassesLeavingDevice
            ),
            correlationSummary: manifest.correlationSummary, contextSummary: manifest.contextSummary,
            completionSummary: manifest.completionSummary
        )
    }
}

private final class WorkflowMemoryDesktopStateStore: DesktopStateStoring {
    var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func load() throws -> Data? { data }

    func save(_ data: Data) throws {
        self.data = data
    }
}
