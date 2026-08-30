import Foundation
import Testing
@testable import KanameDesktop
@testable import KanameDomain

@MainActor
struct DesktopSupportBundleTests {
    @Test
    func supportBundleIsPrettyRedactedAndStableAcrossRestart() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        let sentinel = "PRIVATE-PROMPT account_8675309 /Users/person/Secret Project"
        var snapshot = DesktopAppSnapshot.starter(now: 1_000)
        snapshot.projects[0].name = sentinel
        snapshot.threads[0].summary = sentinel
        snapshot.threads[0].messages = [DesktopMessage(
            id: "private-message",
            role: .user,
            body: sentinel,
            createdAtUnixMillis: 1_000
        )]
        snapshot.remote.relayStatus = sentinel
        snapshot.remote.queueStatus = sentinel
        try store.save(JSONEncoder().encode(snapshot))

        let migrationID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        try store.persistMigrationReceipt(DesktopMigrationReceipt(
            migrationID: migrationID,
            fromStateSchemaVersion: 12,
            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
            startedAtUnixMillis: 1_100,
            completedAtUnixMillis: 1_200,
            outcome: .applied,
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000902"),
            reasonCode: sentinel
        ))
        try store.persistRestoreReceipt(DesktopRestoreReceipt(
            restoreID: UUID(uuidString: "00000000-0000-0000-0000-000000000903")!,
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000904")!,
            stagedAtUnixMillis: 1_300,
            verifiedArtifactCount: 2,
            verifiedByteCount: 4_096
        ))
        try store.persistResetManifest(DesktopResetManifest(
            resetID: UUID(uuidString: "00000000-0000-0000-0000-000000000905")!,
            preparedAtUnixMillis: 1_400,
            verifiedBackupID: UUID(uuidString: "00000000-0000-0000-0000-000000000906")!,
            localArtifacts: [DesktopRecoveryArtifactManifest(
                kind: .workspaceState,
                relativePath: sentinel,
                byteCount: 8_192,
                sha256: sentinel
            )]
        ))
        let incident = store.quarantineDirectoryURL.appendingPathComponent("incident-test", isDirectory: true)
        try FileManager.default.createDirectory(at: incident, withIntermediateDirectories: true)
        try JSONEncoder().encode(DesktopRedactedDiagnosticEvent(
            category: "recovery",
            code: sentinel,
            occurredAtUnixMillis: 1_500,
            privateDetail: sentinel
        )).write(to: incident.appendingPathComponent("receipt.json"))

        let model = DesktopAppModel(store: store, now: { 2_000 })
        let json = model.redactedSupportBundle()
        let bundle = try decodeBundle(json)

        #expect(json.hasPrefix("{\n"))
        #expect(!json.contains("PRIVATE-PROMPT"))
        #expect(!json.contains("account_8675309"))
        #expect(!json.contains("/Users/person"))
        #expect(bundle.schemaVersion == DesktopRedactedDiagnosticsBundle.currentSchemaVersion)
        #expect(bundle.report.projectCount == snapshot.projects.count)
        #expect(bundle.report.relayState.hasPrefix("redacted-"))
        #expect(bundle.migrationReceipts.map(\.migrationID) == [migrationID])
        #expect(bundle.migrationReceipts[0].reasonCode?.hasPrefix("redacted-") == true)
        #expect(bundle.restoreReceipts.first?.verifiedArtifactCount == 2)
        #expect(bundle.resetReceipts.first?.localArtifactCount == 1)
        #expect(bundle.resetReceipts.first?.localArtifactByteCount == 8_192)
        #expect(bundle.events.first?.code.hasPrefix("redacted-") == true)

        let restarted = DesktopAppModel(store: store, now: { 2_000 })
        #expect(try decodeBundle(restarted.redactedSupportBundle()) == bundle)
        #expect(try JSONDecoder().decode(
            DesktopDiagnosticsReport.self,
            from: Data(restarted.redactedDiagnostics().utf8)
        ).projectCount == snapshot.projects.count)
    }

    @Test
    func canariesAcrossPrivateDomainsPathsAndReceiptsNeverReachDigestBoundExport() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceURL = root.appendingPathComponent("Desktop/workspace.json")
        let store = FileDesktopStateStore(fileURL: workspaceURL)
        let canaryFields = [
            "project-id", "project-name", "project-path", "project-summary", "project-accent",
            "project-instruction", "project-knowledge-source", "project-skill", "project-provider", "project-model",
            "thread-id", "thread-project-id", "thread-title", "thread-summary", "thread-provider", "thread-model",
            "thread-reasoning-effort", "message-id", "message-turn-id", "message-body",
            "message-attachment-id", "message-attachment-filename", "message-attachment-path",
            "composer-thread-id", "composer-draft", "draft-thread-id",
            "draft-attachment-id", "draft-attachment-filename", "draft-attachment-path",
            "plan-id", "plan-title", "evidence-id", "evidence-label", "evidence-detail",
            "preference-timezone",
            "relay-status", "queue-status", "enrollment-status", "notification-status",
            "remote-event-id", "remote-event-title", "remote-event-detail",
            "research-id", "research-title", "research-question",
            "knowledge-id", "knowledge-name", "knowledge-scope",
            "skill-id", "skill-name", "skill-scope", "skill-source", "skill-revision",
            "account-id", "account-name", "account-identity", "account-scope",
            "calendar-source-id", "calendar-source-account", "calendar-source-external", "calendar-source-name",
            "calendar-source-owner", "calendar-source-access",
            "email-id", "email-account", "email-recipients", "email-subject", "email-body",
            "calendar-proposal-id", "calendar-account", "calendar-proposal-source-id", "calendar-title",
            "calendar-timezone", "calendar-recurrence",
            "calendar-event-external", "calendar-series-master", "calendar-event-revision",
            "calendar-original-title", "calendar-original-timezone", "calendar-original-recurrence",
            "calendar-series-revision", "calendar-series-recurrence", "calendar-recurrence-scope",
            "calendar-approval", "calendar-exact-target", "calendar-remote-receipt", "calendar-mutation-phase",
            "automation-id", "automation-name", "automation-schedule", "automation-timezone",
            "automation-action", "automation-result",
            "automation-project", "automation-skill", "automation-tool", "automation-approval",
            "git-workspace-id", "git-project", "git-name", "git-path", "git-branch", "git-remote",
            "approval-title", "approval-target", "approval-consequence", "approval-data",
            "artifact-name", "artifact-path", "artifact-digest", "artifact-provenance",
            "audit-id", "audit-domain", "audit-action", "audit-target", "audit-detail",
            "migration-reason", "reset-path", "reset-restore-path", "reset-digest",
            "event-category", "event-code", "event-private-detail", "event-private-digest",
        ]
        var canaries = Dictionary(uniqueKeysWithValues: canaryFields.map { field in
            let token = field.uppercased().replacingOccurrences(of: "-", with: "_")
            return (field, "PRIVATE_CANARY_9B6_\(token)")
        })
        canaries["migration-reason"] = "PRIVATE_CANARY_9B6_MIGRATION_REASON"
        canaries["event-category"] = "PRIVATE_CANARY_9B6_EVENT_CATEGORY"
        canaries["event-code"] = "PRIVATE_CANARY_9B6_EVENT_CODE"
        canaries["event-private-digest"] = String(repeating: "a", count: 64)
        canaries["preference-timezone"] = "Pacific/Marquesas"
        canaries["calendar-timezone"] = "America/St_Johns"
        canaries["calendar-original-timezone"] = "Australia/Eucla"
        canaries["automation-timezone"] = "Asia/Kathmandu"
        func privateValue(_ field: String) -> String { canaries[field]! }

        #expect(Set(canaries.values).count == canaryFields.count)

        var snapshot = DesktopAppSnapshot.starter(now: 1_000)
        snapshot.projects = [DesktopProject(
            id: privateValue("project-id"),
            name: privateValue("project-name"),
            path: privateValue("project-path"),
            summary: privateValue("project-summary"),
            accent: privateValue("project-accent"),
            context: DesktopProjectContext(
                instructionReferences: [privateValue("project-instruction")],
                knowledgeSourceIDs: [privateValue("project-knowledge-source")],
                skillIDs: [privateValue("project-skill")],
                defaultProvider: privateValue("project-provider"),
                defaultModel: privateValue("project-model")
            ),
            createdAtUnixMillis: snapshot.projects[0].createdAtUnixMillis
        )]
        snapshot.threads = [DesktopThread(
            id: privateValue("thread-id"),
            projectID: privateValue("thread-project-id"),
            title: privateValue("thread-title"),
            summary: privateValue("thread-summary"),
            kind: snapshot.threads[0].kind,
            attention: snapshot.threads[0].attention,
            provider: privateValue("thread-provider"),
            model: privateValue("thread-model"),
            reasoningEffort: privateValue("thread-reasoning-effort"),
            createdAtUnixMillis: snapshot.threads[0].createdAtUnixMillis,
            updatedAtUnixMillis: snapshot.threads[0].updatedAtUnixMillis,
            unread: snapshot.threads[0].unread,
            messages: [DesktopMessage(
                id: privateValue("message-id"),
                turnID: privateValue("message-turn-id"),
                role: .user,
                body: privateValue("message-body"),
                attachments: [ConversationImageAttachment(
                    id: privateValue("message-attachment-id"),
                    filename: privateValue("message-attachment-filename"),
                    mimeType: "image/png",
                    byteCount: 128,
                    pixelWidth: 16,
                    pixelHeight: 12,
                    relativePath: privateValue("message-attachment-path")
                )],
                createdAtUnixMillis: 1_000
            )],
            plan: [DesktopPlanItem(
                id: privateValue("plan-id"),
                title: privateValue("plan-title"),
                state: .inProgress
            )],
            evidence: [DesktopEvidence(
                id: privateValue("evidence-id"),
                label: privateValue("evidence-label"),
                detail: privateValue("evidence-detail"),
                state: .pending
            )]
        )]
        snapshot.operations = .empty
        snapshot.operations.composerDrafts[privateValue("composer-thread-id")] = privateValue("composer-draft")
        snapshot.operations.composerAttachmentDrafts[privateValue("draft-thread-id")] = [ConversationImageAttachment(
            id: privateValue("draft-attachment-id"),
            filename: privateValue("draft-attachment-filename"),
            mimeType: "image/jpeg",
            byteCount: 256,
            pixelWidth: 24,
            pixelHeight: 18,
            relativePath: privateValue("draft-attachment-path")
        )]
        snapshot.preferences.defaultScheduleTimeZoneIdentifier = privateValue("preference-timezone")
        snapshot.remote.relayStatus = privateValue("relay-status")
        snapshot.remote.queueStatus = privateValue("queue-status")
        snapshot.remote.enrollmentStatus = privateValue("enrollment-status")
        snapshot.remote.notificationStatus = privateValue("notification-status")
        snapshot.remote.events = [DesktopRemoteEvent(
            id: privateValue("remote-event-id"),
            title: privateValue("remote-event-title"),
            detail: privateValue("remote-event-detail"),
            state: .deferred
        )]

        snapshot.domains.research = [DesktopResearchRecord(
            id: privateValue("research-id"),
            title: privateValue("research-title"),
            question: privateValue("research-question"),
            status: .draft,
            sourceCount: 1,
            updatedAtUnixMillis: 1_001
        )]
        snapshot.domains.knowledgeSources = [DesktopKnowledgeSource(
            id: privateValue("knowledge-id"),
            name: privateValue("knowledge-name"),
            kind: .obsidian,
            scope: privateValue("knowledge-scope"),
            status: .needsReview,
            lastReadAtUnixMillis: nil
        )]
        snapshot.domains.skills = [DesktopSkillRecord(
            id: privateValue("skill-id"),
            name: privateValue("skill-name"),
            kind: .skill,
            scope: privateValue("skill-scope"),
            source: privateValue("skill-source"),
            revision: privateValue("skill-revision"),
            status: .needsReview,
            enabled: true
        )]
        snapshot.domains.accounts = [DesktopAccountRecord(
            id: privateValue("account-id"),
            service: .googleCalendar,
            displayName: privateValue("account-name"),
            identity: privateValue("account-identity"),
            status: .ready,
            scope: privateValue("account-scope")
        )]
        snapshot.domains.calendarSources = [.connected(
            id: privateValue("calendar-source-id"),
            accountID: privateValue("calendar-source-account"),
            externalIdentifier: privateValue("calendar-source-external"),
            provider: .google,
            displayName: privateValue("calendar-source-name"),
            ownerIdentity: privateValue("calendar-source-owner"),
            accessLevel: privateValue("calendar-source-access"),
            isPrimary: true,
            isEnabled: true
        )]
        snapshot.domains.emailDrafts = [DesktopEmailDraft(
            id: privateValue("email-id"),
            accountID: privateValue("email-account"),
            recipients: privateValue("email-recipients"),
            subject: privateValue("email-subject"),
            body: privateValue("email-body"),
            status: .draft,
            updatedAtUnixMillis: 1_002
        )]
        snapshot.domains.calendarProposals = [DesktopCalendarProposal(
            id: privateValue("calendar-proposal-id"),
            accountID: privateValue("calendar-account"),
            calendarSourceID: privateValue("calendar-proposal-source-id"),
            title: privateValue("calendar-title"),
            startAtUnixMillis: 2_000,
            durationMinutes: 30,
            timeZoneIdentifier: privateValue("calendar-timezone"),
            recurrence: privateValue("calendar-recurrence"),
            status: .proposed
        )]
        snapshot.domains.calendarProposals[0].mutationKind = .update
        snapshot.domains.calendarProposals[0].eventExternalID = privateValue("calendar-event-external")
        snapshot.domains.calendarProposals[0].seriesMasterExternalID = privateValue("calendar-series-master")
        snapshot.domains.calendarProposals[0].eventRevision = privateValue("calendar-event-revision")
        snapshot.domains.calendarProposals[0].originalTitle = privateValue("calendar-original-title")
        snapshot.domains.calendarProposals[0].originalStartAtUnixMillis = 1_900
        snapshot.domains.calendarProposals[0].originalEndAtUnixMillis = 2_100
        snapshot.domains.calendarProposals[0].originalTimeZoneIdentifier = privateValue("calendar-original-timezone")
        snapshot.domains.calendarProposals[0].originalRecurrence = [privateValue("calendar-original-recurrence")]
        snapshot.domains.calendarProposals[0].originalIsAllDay = false
        snapshot.domains.calendarProposals[0].seriesMasterRevision = privateValue("calendar-series-revision")
        snapshot.domains.calendarProposals[0].seriesMasterRecurrence = [privateValue("calendar-series-recurrence")]
        snapshot.domains.calendarProposals[0].seriesMasterStartAtUnixMillis = 1_800
        snapshot.domains.calendarProposals[0].recurrenceScope = privateValue("calendar-recurrence-scope")
        snapshot.domains.calendarProposals[0].approvalID = privateValue("calendar-approval")
        snapshot.domains.calendarProposals[0].exactTarget = privateValue("calendar-exact-target")
        snapshot.domains.calendarProposals[0].remoteReceipt = privateValue("calendar-remote-receipt")
        snapshot.domains.calendarProposals[0].reconciledAtUnixMillis = 2_200
        snapshot.domains.calendarProposals[0].mutationPhase = privateValue("calendar-mutation-phase")
        snapshot.domains.automations = [DesktopAutomationRule(
            id: privateValue("automation-id"),
            name: privateValue("automation-name"),
            schedule: privateValue("automation-schedule"),
            timeZoneIdentifier: privateValue("automation-timezone"),
            actionSummary: privateValue("automation-action"),
            missedRunPolicy: .ask,
            status: .draft,
            nextRunAtUnixMillis: nil,
            lastResult: privateValue("automation-result"),
            createdAtUnixMillis: 1_003
        )]
        snapshot.domains.automations[0].scheduleSpec = .anchored(frequency: .daily, hour: 9, minute: 30)
        snapshot.domains.automations[0].actionKind = .skill
        snapshot.domains.automations[0].authority = .standing
        snapshot.domains.automations[0].projectID = privateValue("automation-project")
        snapshot.domains.automations[0].skillIDs = [privateValue("automation-skill")]
        snapshot.domains.automations[0].toolNames = [privateValue("automation-tool")]
        snapshot.domains.automations[0].notificationEnabled = true
        snapshot.domains.automations[0].standingAuthorityApprovedAtUnixMillis = 1_004
        snapshot.domains.automations[0].standingAuthorityApprovalID = privateValue("automation-approval")
        snapshot.domains.gitWorkspaces = [DesktopGitWorkspace(
            id: privateValue("git-workspace-id"),
            projectID: privateValue("git-project"),
            name: privateValue("git-name"),
            localPath: privateValue("git-path"),
            branch: privateValue("git-branch"),
            remoteSummary: privateValue("git-remote"),
            status: .needsReview
        )]
        snapshot.operations.audit = [DesktopAuditRecord(
            id: privateValue("audit-id"),
            domain: privateValue("audit-domain"),
            action: privateValue("audit-action"),
            target: privateValue("audit-target"),
            state: .running,
            detail: privateValue("audit-detail"),
            recordedAtUnixMillis: 1_004
        )]
        try store.save(JSONEncoder().encode(snapshot))

        let model = DesktopAppModel(store: store, now: { 2_000 })
        _ = try #require(model.createApproval(
            threadID: snapshot.threads[0].id,
            title: privateValue("approval-title"),
            exactTarget: privateValue("approval-target"),
            consequence: privateValue("approval-consequence"),
            dataLeavingDevice: privateValue("approval-data"),
            reversible: false,
            expiresAtUnixMillis: nil
        ))
        _ = try #require(model.registerArtifact(
            threadID: snapshot.threads[0].id,
            name: privateValue("artifact-name"),
            kind: .report,
            localPath: privateValue("artifact-path"),
            digest: privateValue("artifact-digest"),
            provenance: privateValue("artifact-provenance")
        ))

        try FileManager.default.createDirectory(at: store.receiptDirectoryURL, withIntermediateDirectories: true)
        let migrationID = UUID(uuidString: "00000000-0000-0000-0000-000000000911")!
        let rawMigration: [String: Any] = [
            "schemaVersion": DesktopMigrationReceipt.currentSchemaVersion,
            "migrationID": migrationID.uuidString,
            "fromStateSchemaVersion": 12,
            "toStateSchemaVersion": DesktopAppSnapshot.currentVersion,
            "startedAtUnixMillis": 1_100,
            "completedAtUnixMillis": 1_200,
            "outcome": DesktopMigrationOutcome.applied.rawValue,
            "reasonCode": privateValue("migration-reason"),
        ]
        let migrationURL = store.receiptDirectoryURL.appendingPathComponent("migration-raw-canary.json")
        try JSONSerialization.data(withJSONObject: rawMigration).write(to: migrationURL)
        try store.persistRestoreReceipt(DesktopRestoreReceipt(
            restoreID: UUID(uuidString: "00000000-0000-0000-0000-000000000912")!,
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000913")!,
            stagedAtUnixMillis: 1_300,
            verifiedArtifactCount: 1,
            verifiedByteCount: 2_048
        ))
        let resetID = UUID(uuidString: "00000000-0000-0000-0000-000000000914")!
        try store.persistResetManifest(DesktopResetManifest(
            resetID: resetID,
            preparedAtUnixMillis: 1_400,
            verifiedBackupID: UUID(uuidString: "00000000-0000-0000-0000-000000000915")!,
            localArtifacts: [DesktopRecoveryArtifactManifest(
                kind: .workspaceState,
                relativePath: privateValue("reset-path"),
                byteCount: 4_096,
                sha256: privateValue("reset-digest"),
                restoreRelativePath: privateValue("reset-restore-path")
            )]
        ))
        let incident = store.quarantineDirectoryURL.appendingPathComponent("incident-canary", isDirectory: true)
        try FileManager.default.createDirectory(at: incident, withIntermediateDirectories: true)
        let eventDetail = privateValue("event-private-detail")
        let rawEvent: [String: Any] = [
            "category": privateValue("event-category"),
            "code": privateValue("event-code"),
            "occurredAtUnixMillis": 1_500,
            "privateDetailByteCount": eventDetail.utf8.count,
            "privateDetailSHA256": privateValue("event-private-digest"),
            "privateDetail": eventDetail,
        ]
        let eventURL = incident.appendingPathComponent("receipt.json")
        try JSONSerialization.data(withJSONObject: rawEvent).write(to: eventURL)

        let resetURL = store.receiptDirectoryURL.appendingPathComponent(
            "reset-\(resetID.uuidString.lowercased()).json"
        )
        let rawPrivateInput = try [workspaceURL, migrationURL, resetURL, eventURL]
            .reduce(into: Data()) { bytes, url in
                bytes.append(try Data(contentsOf: url))
            }
        let rawPrivateInputText = String(decoding: rawPrivateInput, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        for field in canaryFields {
            #expect(rawPrivateInputText.contains(privateValue(field)))
        }

        let inspectedReport = model.redactedSupportBundle()
        let inspection = DesktopSupportBundleInspection(report: inspectedReport)
        let inspectedData = try inspection.validatedData()
        let inspectedBundle = try decodeBundle(String(decoding: inspectedData, as: UTF8.self))
        let inspectedText = String(decoding: inspectedData, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        let counts = Dictionary(uniqueKeysWithValues: inspection.redactionCounts.map { ($0.category, $0.count) })

        #expect(inspection.isValid)
        #expect(inspection.sha256 == DesktopRecoveryService.sha256(inspectedData))
        #expect(inspection.redactionCounts.map(\.category) == DesktopSupportBundleRedactionCategory.allCases)
        #expect(counts[.projectRecords] == 1)
        #expect(counts[.conversationRecords] == snapshot.threads.count)
        #expect(counts[.pendingApprovalRecords] == 1)
        #expect(counts[.researchRecords] == 1)
        #expect(counts[.emailDraftRecords] == 1)
        #expect(counts[.calendarProposalRecords] == 1)
        #expect(counts[.automationRecords] == 1)
        #expect(counts[.artifactRecords] == 1)
        #expect(counts[.auditRecords] == 2)
        #expect(counts[.runtimeStatusFields] == 2)
        #expect(counts[.migrationReasonFields] == 1)
        #expect(counts[.recoveryEventFields] == 2)
        #expect(counts[.recoveryPrivateDetails] == 1)
        #expect(counts[.resetArtifactPaths] == 1)
        #expect(counts[.resetArtifactDigests] == 1)
        #expect(inspectedBundle.migrationReceipts.map(\.migrationID) == [migrationID])
        for canary in canaries.values {
            #expect(!inspectedText.contains(canary))
        }

        let laterProjectName = "PRIVATE-CANARY-9B6-[later-project-name]/owner-only"
        let laterProjectSummary = "PRIVATE-CANARY-9B6-[later-project-summary]/owner-only"
        _ = try #require(model.createProject(
            name: laterProjectName,
            path: nil,
            summary: laterProjectSummary
        ))
        let laterReport = model.redactedSupportBundle()
        #expect(Data(laterReport.utf8) != inspectedData)

        let exportURL = root.appendingPathComponent("exported-diagnostics.json")
        let exportedDigest = try inspection.writeValidated(to: exportURL)
        let exportedData = try Data(contentsOf: exportURL)
        let exportedText = String(decoding: exportedData, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(exportedData == inspectedData)
        #expect(exportedDigest == inspection.sha256)
        #expect(DesktopRecoveryService.sha256(exportedData) == inspection.sha256)
        #expect(!exportedText.contains(laterProjectName))
        #expect(!exportedText.contains(laterProjectSummary))
    }

    @Test
    func redactionSummaryCountsHashedPrivateEventDetailFromItsExactBytes() throws {
        let canary = "PRIVATE-CANARY-9B6-[event-detail-direct]/owner-only"
        let report = DesktopDiagnosticsReport(
            schemaVersion: DesktopAppSnapshot.currentVersion,
            generatedAtUnixMillis: 6_000,
            projectCount: 0,
            activeThreadCount: 0,
            archivedThreadCount: 0,
            unreadThreadCount: 0,
            pendingApprovalCount: 0,
            researchCount: 0,
            emailDraftCount: 0,
            calendarProposalCount: 0,
            automationCount: 0,
            artifactCount: 0,
            auditRecordCount: 0,
            safeMode: true,
            persistenceHealthy: true,
            relayState: "offline",
            queueState: "idle"
        )
        let bundle = DesktopRedactedDiagnosticsBundle(
            generatedAtUnixMillis: 6_000,
            report: report,
            migrationReceipts: [],
            events: [DesktopRedactedDiagnosticEvent(
                category: "recovery",
                code: "runtime-archive-rollback-unverified",
                occurredAtUnixMillis: 6_000,
                privateDetail: canary
            )]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(bundle)
        let inspection = DesktopSupportBundleInspection(report: String(decoding: encoded, as: UTF8.self))
        let counts = Dictionary(uniqueKeysWithValues: inspection.redactionCounts.map { ($0.category, $0.count) })

        #expect(inspection.isValid)
        #expect(counts[.recoveryPrivateDetails] == 1)
        #expect(!String(decoding: try inspection.validatedData(), as: UTF8.self).contains(canary))
    }

    @Test
    func malformedInspectionFailsClosedBeforeWriting() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("must-not-exist.json")
        let inspection = DesktopSupportBundleInspection(report: "{}")

        #expect(!inspection.isValid)
        #expect(throws: DesktopSupportBundleInspectionError.invalidBundle) {
            try inspection.validatedData()
        }
        #expect(throws: DesktopSupportBundleInspectionError.invalidBundle) {
            try inspection.writeValidated(to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))

        let validStore = FileDesktopStateStore(fileURL: root.appendingPathComponent("valid/workspace.json"))
        var unsafeObject = try #require(JSONSerialization.jsonObject(
            with: Data(DesktopAppModel(store: validStore, now: { 7_000 }).redactedSupportBundle().utf8)
        ) as? [String: Any])
        var unsafeReport = try #require(unsafeObject["report"] as? [String: Any])
        unsafeReport["relayState"] = "PRIVATE_CANARY_9B6_TAMPERED_RELAY"
        unsafeObject["report"] = unsafeReport
        let unsafeInspection = DesktopSupportBundleInspection(report: String(
            decoding: try JSONSerialization.data(withJSONObject: unsafeObject),
            as: UTF8.self
        ))

        #expect(!unsafeInspection.isValid)
        #expect(throws: DesktopSupportBundleInspectionError.invalidBundle) {
            try unsafeInspection.writeValidated(to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func codeShapedFileBackedRuntimeStatusCanariesAreRedactedBeforeExport() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("must-not-export.json")
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        var snapshot = DesktopAppSnapshot.starter(now: 8_000)
        let relayCanary = "PRIVATE_CANARY_9B6_RELAY_TOKEN"
        let queueCanary = "PRIVATE_CANARY_9B6_QUEUE_TOKEN"
        snapshot.remote.relayStatus = relayCanary
        snapshot.remote.queueStatus = queueCanary
        try store.save(JSONEncoder().encode(snapshot))

        let report = DesktopAppModel(store: store, now: { 8_001 }).redactedSupportBundle()
        let inspection = DesktopSupportBundleInspection(report: report)

        #expect(report.contains(relayCanary))
        #expect(report.contains(queueCanary))
        #expect(inspection.isValid)
        let inspected = try inspection.validatedData()
        #expect(!String(decoding: inspected, as: UTF8.self).contains(relayCanary))
        #expect(!String(decoding: inspected, as: UTF8.self).contains(queueCanary))
        #expect(try inspection.validatedData() == inspected)
        #expect(try inspection.writeValidated(to: target) == inspection.sha256)
        #expect(try Data(contentsOf: target) == inspected)
    }

    @Test
    func redactionShapedRawCodesAndFileDigestAreRedactedAgainBeforeExport() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("redaction-shaped-export.json")
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        let rawRelay = "redacted-0123456789abcdef"
        let rawQueue = "redacted-fedcba9876543210"
        let rawMigration = "redacted-1111111111111111"
        let rawCategory = "redacted-2222222222222222"
        let rawCode = "redacted-3333333333333333"
        let rawPrivateDigest = String(repeating: "4", count: 64)
        func redactedCode(_ value: String) -> String {
            "redacted-\(DesktopRecoveryService.sha256(Data(value.utf8)).prefix(16))"
        }
        var snapshot = DesktopAppSnapshot.starter(now: 8_100)
        snapshot.remote.relayStatus = rawRelay
        snapshot.remote.queueStatus = rawQueue
        try store.save(JSONEncoder().encode(snapshot))

        try FileManager.default.createDirectory(at: store.receiptDirectoryURL, withIntermediateDirectories: true)
        let migrationID = UUID(uuidString: "00000000-0000-0000-0000-000000000921")!
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": DesktopMigrationReceipt.currentSchemaVersion,
            "migrationID": migrationID.uuidString,
            "fromStateSchemaVersion": 12,
            "toStateSchemaVersion": DesktopAppSnapshot.currentVersion,
            "startedAtUnixMillis": 8_101,
            "completedAtUnixMillis": 8_102,
            "outcome": DesktopMigrationOutcome.applied.rawValue,
            "reasonCode": rawMigration,
        ]).write(to: store.receiptDirectoryURL.appendingPathComponent("migration-shaped.json"))
        let incident = store.quarantineDirectoryURL.appendingPathComponent("incident-shaped", isDirectory: true)
        try FileManager.default.createDirectory(at: incident, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "category": rawCategory,
            "code": rawCode,
            "occurredAtUnixMillis": 8_103,
            "privateDetailByteCount": 16,
            "privateDetailSHA256": rawPrivateDigest,
        ]).write(to: incident.appendingPathComponent("receipt.json"))

        let supplied = DesktopAppModel(store: store, now: { 8_104 }).redactedSupportBundle()
        let suppliedBundle = try decodeBundle(supplied)
        let inspection = DesktopSupportBundleInspection(report: supplied)
        let first = try inspection.validatedData()
        let second = try inspection.validatedData()
        let inspectedBundle = try decodeBundle(String(decoding: first, as: UTF8.self))
        let inspectedText = String(decoding: first, as: UTF8.self)

        #expect(supplied.contains(rawRelay))
        #expect(supplied.contains(rawQueue))
        #expect(suppliedBundle.malformedReceiptCount == 0)
        #expect(suppliedBundle.rejectedUnsafeReceiptCount == 0)
        let suppliedMigration = try #require(suppliedBundle.migrationReceipts.first)
        let suppliedEvent = try #require(suppliedBundle.events.first)
        #expect(suppliedBundle.migrationReceipts.map(\.migrationID) == [migrationID])
        #expect(suppliedBundle.events.count == 1)
        #expect(suppliedMigration.reasonCode == redactedCode(rawMigration))
        #expect(suppliedEvent.category == redactedCode(rawCategory))
        #expect(suppliedEvent.code == redactedCode(rawCode))
        #expect(suppliedEvent.privateDetailSHA256 == DesktopRecoveryService.sha256(
            Data(rawPrivateDigest.utf8)
        ))
        for rawValue in [rawMigration, rawCategory, rawCode, rawPrivateDigest] {
            #expect(!supplied.contains(rawValue))
        }
        #expect(inspection.isValid)
        #expect(first == second)
        #expect(DesktopRecoveryService.sha256(first) == inspection.sha256)
        #expect(inspectedBundle.migrationReceipts.map(\.migrationID) == [migrationID])
        #expect(inspectedBundle.events.count == 1)
        #expect(inspectedBundle.report.relayState == redactedCode(rawRelay))
        #expect(inspectedBundle.report.queueState == redactedCode(rawQueue))
        let inspectedMigration = try #require(inspectedBundle.migrationReceipts.first)
        let inspectedEvent = try #require(inspectedBundle.events.first)
        #expect(inspectedMigration.reasonCode == redactedCode(redactedCode(rawMigration)))
        #expect(inspectedEvent.category == redactedCode(redactedCode(rawCategory)))
        #expect(inspectedEvent.code == redactedCode(redactedCode(rawCode)))
        #expect(inspectedEvent.privateDetailSHA256 == DesktopRecoveryService.sha256(Data(
            DesktopRecoveryService.sha256(Data(rawPrivateDigest.utf8)).utf8
        )))
        for rawValue in [rawRelay, rawQueue, rawMigration, rawCategory, rawCode, rawPrivateDigest] {
            #expect(!inspectedText.contains(rawValue))
        }
        #expect(try inspection.writeValidated(to: target) == inspection.sha256)
        #expect(try Data(contentsOf: target) == first)
    }

    @Test
    func unknownAndDuplicateJSONFieldsFailClosedBeforeExport() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let validReport = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { 9_000 }
        ).redactedSupportBundle()
        let validBundle = try decodeBundle(validReport)

        let topLevelCanary = "PRIVATE_CANARY_9B6_UNKNOWN_TOP_LEVEL"
        let topLevelNeedle = "\n}"
        let topLevelReplacement = ",\n  \"zzPrivateDetail\" : \"\(topLevelCanary)\"\n}"
        let topLevelReport = replacing(
            topLevelNeedle,
            with: topLevelReplacement,
            in: validReport,
            options: .backwards
        )

        let nestedCanary = "PRIVATE_CANARY_9B6_UNKNOWN_NESTED"
        let nestedNeedle = "    \"unreadThreadCount\" : \(validBundle.report.unreadThreadCount)\n  }"
        let nestedReplacement = "    \"unreadThreadCount\" : \(validBundle.report.unreadThreadCount),\n"
            + "    \"zzPrivateDetail\" : \"\(nestedCanary)\"\n  }"
        let nestedReport = replacing(nestedNeedle, with: nestedReplacement, in: validReport)

        let duplicateCanary = "PRIVATE_CANARY_9B6_DUPLICATE_RELAY"
        let duplicateNeedle = "    \"relayState\" : \"\(validBundle.report.relayState)\""
        let duplicateReplacement = "    \"relayState\" : \"\(duplicateCanary)\",\n\(duplicateNeedle)"
        let duplicateReport = replacing(duplicateNeedle, with: duplicateReplacement, in: validReport)

        let cases = [
            ("top-level", topLevelCanary, topLevelReport),
            ("nested", nestedCanary, nestedReport),
            ("duplicate", duplicateCanary, duplicateReport),
        ]
        for (name, canary, report) in cases {
            let target = root.appendingPathComponent("must-not-export-\(name).json")
            let inspection = DesktopSupportBundleInspection(report: report)
            #expect(report != validReport)
            #expect(report.contains(canary))
            #expect(!inspection.isValid)
            #expect(throws: DesktopSupportBundleInspectionError.invalidBundle) {
                try inspection.writeValidated(to: target)
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test
    func nonCurrentDiagnosticsReportSchemaFailsClosedBeforeExport() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let validReport = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { 9_100 }
        ).redactedSupportBundle()
        let schemaNeedle = "    \"schemaVersion\" : \(DesktopAppSnapshot.currentVersion)"

        for schemaVersion in [DesktopAppSnapshot.currentVersion - 1, DesktopAppSnapshot.currentVersion + 1] {
            let report = replacing(
                schemaNeedle,
                with: "    \"schemaVersion\" : \(schemaVersion)",
                in: validReport
            )
            let target = root.appendingPathComponent("must-not-export-schema-\(schemaVersion).json")
            let inspection = DesktopSupportBundleInspection(report: report)
            #expect(report != validReport)
            #expect(!inspection.isValid)
            #expect(throws: DesktopSupportBundleInspectionError.invalidBundle) {
                try inspection.writeValidated(to: target)
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test
    func malformedOversizedAndSymbolicLinkReceiptsAreExcluded() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        _ = DesktopAppModel(store: store, now: { 3_000 })
        try FileManager.default.createDirectory(at: store.receiptDirectoryURL, withIntermediateDirectories: true)
        try Data("not-json PRIVATE-MALFORMED".utf8).write(
            to: store.receiptDirectoryURL.appendingPathComponent("migration-malformed.json")
        )
        try Data(repeating: 65, count: FileDesktopStateStore.supportBundleMaximumReceiptBytes + 1).write(
            to: store.receiptDirectoryURL.appendingPathComponent("reset-oversized.json")
        )
        let outside = root.appendingPathComponent("PRIVATE-SYMLINK-TARGET.json")
        try JSONEncoder().encode(DesktopRestoreReceipt(
            restoreID: UUID(),
            backupID: UUID(),
            stagedAtUnixMillis: 1,
            verifiedArtifactCount: 1,
            verifiedByteCount: 1
        )).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: store.receiptDirectoryURL.appendingPathComponent("restore-linked.json"),
            withDestinationURL: outside
        )
        let invalidIncident = store.quarantineDirectoryURL.appendingPathComponent(
            "incident-invalid-private-detail",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: invalidIncident, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "category": "recovery",
            "code": "failure",
            "occurredAtUnixMillis": 1,
            "privateDetailByteCount": 20,
            "privateDetailSHA256": "not-a-canonical-digest",
            "privateDetail": "PRIVATE-INVALID-EVENT-DETAIL",
        ]).write(to: invalidIncident.appendingPathComponent("receipt.json"))
        let good = DesktopMigrationReceipt(
            migrationID: UUID(),
            fromStateSchemaVersion: 12,
            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
            startedAtUnixMillis: 1,
            completedAtUnixMillis: 2,
            outcome: .applied,
            backupID: nil
        )
        try store.persistMigrationReceipt(good)

        let bundle = try decodeBundle(DesktopAppModel(store: store, now: { 3_001 }).redactedSupportBundle())

        #expect(bundle.migrationReceipts.map(\.migrationID) == [good.migrationID])
        #expect(bundle.restoreReceipts.isEmpty)
        #expect(bundle.resetReceipts.isEmpty)
        #expect(bundle.malformedReceiptCount == 3)
        #expect(bundle.rejectedUnsafeReceiptCount == 1)
        #expect(!String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self).contains("PRIVATE-"))
    }

    @Test(arguments: SymlinkedRecoveryPath.allCases)
    private func symlinkedRecoveryPathIsRejectedWithoutReadingItsReceipts(
        _ symlinkedPath: SymlinkedRecoveryPath
    ) throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture: (receipts: URL, link: URL, destination: URL, workspace: URL)
        switch symlinkedPath {
        case .managedRecoveryDirectory:
            let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
            let outsideRecovery = root.appendingPathComponent("PRIVATE-RECOVERY", isDirectory: true)
            fixture = (
                receipts: outsideRecovery.appendingPathComponent("Receipts", isDirectory: true),
                link: desktop.appendingPathComponent("Recovery", isDirectory: true),
                destination: outsideRecovery,
                workspace: desktop.appendingPathComponent("workspace.json")
            )
        case .ancestorAboveManagedRecoveryDirectory:
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            let linkedAncestor = root.appendingPathComponent("linked-ancestor", isDirectory: true)
            fixture = (
                receipts: outside.appendingPathComponent("Desktop/Recovery/Receipts", isDirectory: true),
                link: linkedAncestor,
                destination: outside,
                workspace: linkedAncestor.appendingPathComponent("Desktop/workspace.json")
            )
        }

        try FileManager.default.createDirectory(
            at: fixture.link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: fixture.receipts, withIntermediateDirectories: true)
        let receipt = DesktopMigrationReceipt(
            migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000932")!,
            fromStateSchemaVersion: 12,
            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
            startedAtUnixMillis: 4_201,
            completedAtUnixMillis: 4_202,
            outcome: .applied,
            backupID: nil
        )
        try JSONEncoder().encode(receipt).write(
            to: fixture.receipts.appendingPathComponent("migration-private.json")
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.link,
            withDestinationURL: fixture.destination
        )

        let loaded = FileDesktopStateStore(
            fileURL: fixture.workspace
        ).loadRedactedRecoveryReceiptDiagnostics()

        #expect(loaded.migrationReceipts.isEmpty)
        #expect(loaded.rejectedUnsafeReceiptCount == 1)
        #expect(loaded.malformedReceiptCount == 0)
    }

    @Test
    func hardLinkedReceiptAndOversizedRecoveryLockAreRejectedByBoundedDescriptorReads() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        _ = DesktopAppModel(store: store, now: { 4_100 })
        try FileManager.default.createDirectory(at: store.receiptDirectoryURL, withIntermediateDirectories: true)

        let linkedSource = root.appendingPathComponent("linked-migration-source.json")
        let migration = DesktopMigrationReceipt(
            migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000931")!,
            fromStateSchemaVersion: 12,
            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
            startedAtUnixMillis: 4_101,
            completedAtUnixMillis: 4_102,
            outcome: .applied,
            backupID: nil
        )
        try JSONEncoder().encode(migration).write(to: linkedSource)
        try FileManager.default.linkItem(
            at: linkedSource,
            to: store.receiptDirectoryURL.appendingPathComponent("migration-hard-linked.json")
        )
        try Data(
            repeating: 65,
            count: FileDesktopStateStore.supportBundleMaximumReceiptBytes + 1
        ).write(to: store.recoveryLockMarkerURL)

        let loaded = store.loadRedactedRecoveryReceiptDiagnostics()

        #expect(loaded.migrationReceipts.isEmpty)
        #expect(loaded.events.isEmpty)
        #expect(loaded.rejectedUnsafeReceiptCount == 1)
        #expect(loaded.malformedReceiptCount == 1)
    }

    @Test
    func validRecoveryLockUsesBoundedDescriptorReadAndRedactsUntrustedCode() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        try FileManager.default.createDirectory(
            at: store.managedRecoveryDirectoryURL,
            withIntermediateDirectories: true
        )
        let rawCode = "redacted-4444444444444444"
        try JSONSerialization.data(withJSONObject: [
            "category": "recovery",
            "code": rawCode,
            "occurredAtUnixMillis": 4_150,
            "privateDetailByteCount": 0,
        ]).write(to: store.recoveryLockMarkerURL)

        let loaded = store.loadRedactedRecoveryReceiptDiagnostics()

        let expectedCode = "redacted-\(DesktopRecoveryService.sha256(Data(rawCode.utf8)).prefix(16))"
        #expect(loaded.events.count == 1)
        #expect(loaded.events[0].category == "recovery")
        #expect(loaded.events[0].code == expectedCode)
        #expect(loaded.events[0].privateDetailSHA256 == nil)
        #expect(loaded.malformedReceiptCount == 0)
        #expect(loaded.rejectedUnsafeReceiptCount == 0)
    }

    @Test
    func receiptItemsAndDirectoryScanningAreBounded() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        _ = DesktopAppModel(store: store, now: { 4_000 })
        for index in 0..<20 {
            try store.persistMigrationReceipt(DesktopMigrationReceipt(
                migrationID: UUID(),
                fromStateSchemaVersion: 12,
                toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
                startedAtUnixMillis: Int64(index),
                completedAtUnixMillis: Int64(index),
                outcome: .applied,
                backupID: nil
            ))
        }

        let bounded = store.loadRedactedRecoveryReceiptDiagnostics()
        #expect(bounded.migrationReceipts.count == FileDesktopStateStore.supportBundleMaximumItemsPerKind)
        #expect(bounded.migrationReceipts.first?.completedAtUnixMillis == 4)
        #expect(bounded.migrationReceipts.last?.completedAtUnixMillis == 19)

        for index in 0...FileDesktopStateStore.supportBundleMaximumScannedItems {
            try Data("{".utf8).write(
                to: store.receiptDirectoryURL.appendingPathComponent("restore-malformed-\(index).json")
            )
        }
        let truncated = store.loadRedactedRecoveryReceiptDiagnostics()
        #expect(truncated.receiptScanTruncated)
        #expect(truncated.migrationReceipts.count <= FileDesktopStateStore.supportBundleMaximumItemsPerKind)
        #expect(truncated.restoreReceipts.isEmpty)
    }

    @Test
    func schemaOneDiagnosticsBundlesStillDecodeWithEmptyNewReceiptFields() throws {
        let original = DesktopRedactedDiagnosticsBundle(
            generatedAtUnixMillis: 5_000,
            report: DesktopDiagnosticsReport(
                schemaVersion: DesktopAppSnapshot.currentVersion,
                generatedAtUnixMillis: 5_000,
                projectCount: 1,
                activeThreadCount: 1,
                archivedThreadCount: 0,
                unreadThreadCount: 0,
                pendingApprovalCount: 0,
                researchCount: 0,
                emailDraftCount: 0,
                calendarProposalCount: 0,
                automationCount: 0,
                artifactCount: 0,
                auditRecordCount: 0,
                safeMode: true,
                persistenceHealthy: true,
                relayState: "offline",
                queueState: "idle"
            ),
            migrationReceipts: [],
            events: []
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)
        ) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "restoreReceipts")
        object.removeValue(forKey: "resetReceipts")
        object.removeValue(forKey: "malformedReceiptCount")
        object.removeValue(forKey: "rejectedUnsafeReceiptCount")
        object.removeValue(forKey: "receiptScanTruncated")

        let decoded = try JSONDecoder().decode(
            DesktopRedactedDiagnosticsBundle.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.restoreReceipts.isEmpty)
        #expect(decoded.resetReceipts.isEmpty)
        #expect(decoded.malformedReceiptCount == 0)
        #expect(decoded.rejectedUnsafeReceiptCount == 0)
        #expect(!decoded.receiptScanTruncated)
    }

    private enum SymlinkedRecoveryPath: CaseIterable, Sendable {
        case managedRecoveryDirectory
        case ancestorAboveManagedRecoveryDirectory
    }

    private func decodeBundle(_ json: String) throws -> DesktopRedactedDiagnosticsBundle {
        try JSONDecoder().decode(DesktopRedactedDiagnosticsBundle.self, from: Data(json.utf8))
    }

    private func replacing(
        _ needle: String,
        with replacement: String,
        in value: String,
        options: String.CompareOptions = []
    ) -> String {
        guard let range = value.range(of: needle, options: options) else { return value }
        return value.replacingCharacters(in: range, with: replacement)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kaname-support-bundle-\(UUID().uuidString)")
    }
}
