import Foundation
import KanameDesktop
import Testing

@MainActor
@Suite(.serialized)
struct DesktopWorkflowManifestV3Tests {
    private let capabilities = DesktopWorkflowBuiltinCapabilities.identifiers

    @Test
    func onePublicPackageCreatesIndependentReadyInstallationsWithoutPrivateManifestValues() throws {
        let data = try fixtureData()
        let model = DesktopAppModel(store: ManifestV3MemoryStore(), now: { 100_000 })
        _ = try model.installWorkflowPackage(manifestData: data, registeredCapabilityIDs: capabilities)
        let first = try #require(model.workflowInstallations(workflowID: "org.example.mailbox-review-v3").first)
        #expect(first.enabled == false)
        #expect(first.readinessIssues.count == 2)

        try model.reviseWorkflowInstallation(
            id: first.id,
            configuration: Data(#"{"includeRead":false,"query":"in:inbox from:alpha.example","reviewLabel":"Alpha review"}"#.utf8),
            bindings: bindings(account: "synthetic-account-alpha", label: "synthetic-label-alpha"),
            dependencyLock: [],
            capturePolicy: .init(mailLevel: .allowlistedHeaders),
            retentionPolicy: .init()
        )
        let revisedFirst = try #require(model.workflowInstallations(workflowID: "org.example.mailbox-review-v3").first)
        #expect(revisedFirst.readinessIssues.isEmpty)
        #expect(model.setWorkflowInstallationEnabled(id: revisedFirst.id, enabled: true))
        #expect(model.setWorkflowEnabled(id: "org.example.mailbox-review-v3", enabled: true))

        let secondID = try model.createWorkflowInstallation(
            workflowID: "org.example.mailbox-review-v3",
            name: "Beta mailbox review",
            configuration: Data(#"{"includeRead":true,"query":"label:beta","reviewLabel":"Beta review"}"#.utf8),
            bindings: bindings(account: "synthetic-account-beta", label: "synthetic-label-beta")
        )
        let second = try #require(model.workflowInstallations(workflowID: "org.example.mailbox-review-v3").first { $0.id == secondID })
        #expect(second.readinessIssues.isEmpty)
        #expect(model.setWorkflowInstallationEnabled(id: second.id, enabled: true))

        let firstConfiguration = try #require(model.currentWorkflowConfiguration(installationID: revisedFirst.id))
        let secondConfiguration = try #require(model.currentWorkflowConfiguration(installationID: second.id))
        #expect(firstConfiguration.digest != secondConfiguration.digest)
        #expect(firstConfiguration.canonicalJSON.contains("alpha.example"))
        #expect(secondConfiguration.canonicalJSON.contains("label:beta"))
        #expect(model.currentWorkflowBindings(installationID: revisedFirst.id)?.resolutions.first?.resourceIDs == ["synthetic-account-alpha"])
        #expect(model.currentWorkflowBindings(installationID: second.id)?.resolutions.first?.resourceIDs == ["synthetic-account-beta"])

        let reusable = try model.exportWorkflowPackage(workflowID: "org.example.mailbox-review-v3")
        let reusableText = try #require(String(data: reusable, encoding: .utf8))
        #expect(!reusableText.contains("synthetic-account-alpha"))
        #expect(!reusableText.contains("synthetic-account-beta"))
        #expect(!reusableText.contains("Alpha review"))
        #expect(!reusableText.contains("Beta review"))
    }

    @Test
    func draft202012DiagnosticsRejectUnsupportedKeywordsAtExactPathAndValidateFormats() throws {
        let unsupported = Data(#"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"query":{"type":"string","unevaluatedProperties":false}}}"#.utf8)
        #expect(DesktopWorkflowJSONSchemaValidator.schemaDiagnostics(unsupported) == [
            .init(path: "/properties/query/unevaluatedProperties", message: "Unsupported schema keyword unevaluatedProperties.")
        ])

        let schema = ##"{"$schema":"https://json-schema.org/draft/2020-12/schema","$defs":{"positive":{"type":"integer","minimum":1}},"type":"object","required":["email","count"],"properties":{"email":{"type":"string","format":"email"},"count":{"$ref":"#/$defs/positive","maximum":5}},"additionalProperties":false}"##
        #expect(DesktopWorkflowJSONSchemaValidator.validationDiagnostics(
            instance: Data(#"{"email":"reviewer@example.com","count":3}"#.utf8), against: schema
        ).isEmpty)
        let issues = DesktopWorkflowJSONSchemaValidator.validationDiagnostics(
            instance: Data(#"{"email":"not-an-email","count":9}"#.utf8), against: schema
        )
        #expect(issues.contains { $0.path == "/email" && $0.message.contains("email") })
        #expect(issues.contains { $0.path == "/count" && $0.message.contains("above") })
    }

    @Test
    func schemaDrivenFormsExposeConfigurationAndManualRunFields() throws {
        let manifest = try DesktopWorkflowPackageCodec.decode(try fixtureData(), registeredCapabilityIDs: capabilities)
        let setup = DesktopWorkflowSchemaForm.fields(
            schemaText: try #require(manifest.configurationSchema), hints: manifest.uiHints ?? []
        )
        #expect(setup.map(\.pointer) == ["/includeRead", "/query", "/reviewLabel"])
        #expect(setup.first(where: { $0.pointer == "/includeRead" })?.control == .toggle)
        #expect(setup.first(where: { $0.pointer == "/query" })?.control == .multilineText)
        let run = DesktopWorkflowSchemaForm.fields(schemaText: try #require(manifest.manualRunInputSchema))
        #expect(run.map(\.pointer) == ["/limit", "/reason"])
        #expect(run.first(where: { $0.pointer == "/limit" })?.control == .number)
    }

    @Test
    func secretConfigurationAndUnsupportedManifestSchemaFailWithActionablePaths() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        object["configurationSchema"] = #"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"api_token":{"type":"string"}},"additionalProperties":false}"#
        let secretManifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        do {
            _ = try DesktopWorkflowPackageCodec.decode(secretManifest, registeredCapabilityIDs: capabilities)
            Issue.record("Secret-shaped configuration field should fail package validation.")
        } catch let error as DesktopWorkflowPackageError {
            #expect(error == .invalidContract(
                path: "/configurationSchema/properties/api_token",
                message: "Secret values must use a secret-reference binding slot, not configuration."
            ))
        }

        object = try #require(try JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        object["manualRunInputSchema"] = #"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","dependentSchemas":{}}"#
        let unsupported = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        do {
            _ = try DesktopWorkflowPackageCodec.decode(unsupported, registeredCapabilityIDs: capabilities)
            Issue.record("Unsupported schema keyword should fail package validation.")
        } catch let error as DesktopWorkflowPackageError {
            #expect(error == .invalidContract(
                path: "/manualRunInputSchema/dependentSchemas",
                message: "Unsupported schema keyword dependentSchemas."
            ))
        }
    }

    @Test
    func configurationUpgradeMigratesImmutableRevisionAndRevokesAuthorityCarryForward() throws {
        let model = DesktopAppModel(store: ManifestV3MemoryStore(), now: { 200_000 })
        let originalData = try fixtureData()
        _ = try model.installWorkflowPackage(manifestData: originalData, registeredCapabilityIDs: capabilities)
        let originalInstallation = try #require(model.workflowInstallations(workflowID: "org.example.mailbox-review-v3").first)
        try model.reviseWorkflowInstallation(
            id: originalInstallation.id,
            configuration: Data(#"{"includeRead":false,"query":"in:inbox","reviewLabel":"Review"}"#.utf8),
            bindings: bindings(account: "synthetic-account", label: "synthetic-label"),
            dependencyLock: [], capturePolicy: .init(), retentionPolicy: .init()
        )
        let priorConfigurationID = try #require(model.currentWorkflowConfiguration(installationID: originalInstallation.id)?.id)

        var updated = try #require(try JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        updated["version"] = "2.0.0"
        updated["configurationSchemaVersion"] = 2
        updated["configurationSchema"] = #"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","required":["query","queueLabel"],"properties":{"query":{"type":"string","minLength":1},"queueLabel":{"type":"string","minLength":1},"includeRead":{"type":"boolean","default":false}},"additionalProperties":false}"#
        updated["configurationMigrations"] = [[
            "fromVersion": 1,
            "toVersion": 2,
            "operations": [[
                "kind": "rename",
                "pointer": "/reviewLabel",
                "destinationPointer": "/queueLabel",
            ]],
        ]]
        let updatedData = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
        let newRevisionID = try model.installWorkflowPackage(manifestData: updatedData, registeredCapabilityIDs: capabilities)
        let diff = try #require(model.previewWorkflowUpgrade(
            installationID: originalInstallation.id, toRevisionID: newRevisionID
        ))
        #expect(diff.configurationSchemaChanged)
        #expect(diff.authorityCarriedForward == false)
        #expect(try model.upgradeWorkflowInstallation(installationID: originalInstallation.id, toRevisionID: newRevisionID))
        let upgraded = try #require(model.workflowInstallations(workflowID: "org.example.mailbox-review-v3").first {
            $0.id == originalInstallation.id
        })
        #expect(upgraded.enabled == false)
        let current = try #require(model.currentWorkflowConfiguration(installationID: upgraded.id))
        #expect(current.id != priorConfigurationID)
        #expect(current.migratedFromRevisionID == priorConfigurationID)
        #expect(current.canonicalJSON.contains("queueLabel"))
        #expect(!current.canonicalJSON.contains("reviewLabel"))
        #expect(model.snapshot.operations.workflows.configurationRevisions.contains { $0.id == priorConfigurationID })
    }

    @Test
    func capturePolicyIsAccountScopedAndProviderReadinessDisablesMissingResources() throws {
        let model = DesktopAppModel(store: ManifestV3MemoryStore(), now: { 300_000 })
        _ = try model.installWorkflowPackage(manifestData: fixtureData(), registeredCapabilityIDs: capabilities)
        let installation = try #require(model.workflowInstallations(workflowID: "org.example.mailbox-review-v3").first)
        let policy = DesktopWorkflowCapturePolicy(
            mailLevel: .allowlistedHeaders,
            headerAllowlist: ["List-Unsubscribe"],
            includeAttachments: true,
            attachmentMIMETypes: ["application/pdf"],
            maximumAttachmentBytes: 2_000_000,
            maximumTotalBytes: 4_000_000,
            maximumAttachmentCount: 2
        )
        #expect(!policy.capturesMailBody)
        #expect(policy.capturedHeaders(from: ["list-unsubscribe", "Precedence"]) == ["list-unsubscribe"])
        #expect(policy.maximumBytesForNextAttachment(
            mediaType: "application/pdf", declaredSize: 1_000_000,
            capturedCount: 1, capturedBytes: 2_000_000
        ) == 2_000_000)
        #expect(policy.maximumBytesForNextAttachment(
            mediaType: "image/png", declaredSize: 100,
            capturedCount: 0, capturedBytes: 0
        ) == nil)
        try model.reviseWorkflowInstallation(
            id: installation.id,
            configuration: Data(#"{"includeRead":false,"query":"in:inbox","reviewLabel":"Review"}"#.utf8),
            bindings: bindings(account: "account-1", label: "resource-1"),
            dependencyLock: [], capturePolicy: policy, retentionPolicy: .init()
        )
        #expect(model.workflowMailCapturePolicy(
            workflowID: "org.example.mailbox-review-v3", accountID: "account-1"
        ) == .init())
        #expect(model.setWorkflowInstallationEnabled(id: installation.id, enabled: true))
        #expect(model.workflowMailCapturePolicy(
            workflowID: "org.example.mailbox-review-v3", accountID: "account-1"
        ) == policy)
        #expect(model.workflowMailCapturePolicy(
            workflowID: "org.example.mailbox-review-v3", accountID: "different-account"
        ) == .init())

        #expect(model.recordWorkflowProviderReadiness(
            installationID: installation.id, issues: ["account-1 is missing bound resource ID resource-1."]
        ))
        let blocked = try #require(model.workflowInstallations.first { $0.id == installation.id })
        #expect(!blocked.enabled)
        #expect(blocked.readinessIssues.contains { $0.hasPrefix("Provider: ") })
        #expect(model.recordWorkflowProviderReadiness(installationID: installation.id, issues: []))
        let recovered = try #require(model.workflowInstallations.first { $0.id == installation.id })
        #expect(recovered.readinessIssues.isEmpty)
        #expect(!recovered.enabled)
    }

    @Test
    func reusableMailGraphsContainNoProviderIdentifier() throws {
        for filename in ["mailbox-review-v3.workflow.json", "generic-case-review.workflow.json"] {
            let data = try Data(contentsOf: packageRoot().appendingPathComponent("Examples/Workflows/\(filename)"))
            let text = try #require(String(data: data, encoding: .utf8)).lowercased()
            #expect(!text.contains("gmail"), "\(filename) contains a provider-specific identifier")
            #expect(!text.contains("kaname.gmail"), "\(filename) contains a provider-specific connector")
        }
    }

    private func fixtureData() throws -> Data {
        try Data(contentsOf: packageRoot().appendingPathComponent("Examples/Workflows/mailbox-review-v3.workflow.json"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func bindings(account: String, label: String) -> [DesktopWorkflowBindingResolution] {
        [
            .init(slotID: "mail-account", kind: .account, resourceIDs: [account], displayLabels: ["Synthetic account"]),
            .init(slotID: "review-label", kind: .providerResource, resourceIDs: [label], displayLabels: ["Synthetic label"]),
        ]
    }
}

private final class ManifestV3MemoryStore: DesktopStateStoring {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
