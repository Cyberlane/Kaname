import CryptoKit
import Foundation

public struct DesktopWorkflowTemplateSignature: Codable, Equatable, Sendable {
    public var algorithm: String
    public var signerID: String
    public var publicKeyBase64: String
    public var publicKeyFingerprint: String
    public var manifestDigest: String
    public var signatureBase64: String

    public init(
        algorithm: String = "ed25519",
        signerID: String,
        publicKeyBase64: String,
        publicKeyFingerprint: String,
        manifestDigest: String,
        signatureBase64: String
    ) {
        self.algorithm = algorithm
        self.signerID = signerID
        self.publicKeyBase64 = publicKeyBase64
        self.publicKeyFingerprint = publicKeyFingerprint
        self.manifestDigest = manifestDigest
        self.signatureBase64 = signatureBase64
    }
}

public struct DesktopWorkflowSignedTemplateEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var manifest: DesktopWorkflowPackageManifest
    public var signature: DesktopWorkflowTemplateSignature

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        manifest: DesktopWorkflowPackageManifest,
        signature: DesktopWorkflowTemplateSignature
    ) {
        self.schemaVersion = schemaVersion
        self.manifest = manifest
        self.signature = signature
    }
}

public struct DesktopWorkflowTemplateVerificationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var workflowRevisionID: String
    public var envelopeDigest: String
    public var signerID: String
    public var publicKeyFingerprint: String
    public var verifiedAtUnixMillis: Int64
}

public enum DesktopWorkflowTemplateError: Error, Equatable, LocalizedError, Sendable {
    case oversized
    case unsupportedSchema
    case invalidKey
    case invalidSignature
    case digestMismatch
    case untrustedSigner
    case publisherMismatch

    public var errorDescription: String? {
        switch self {
        case .oversized: "The signed workflow template exceeds the 512 KiB limit."
        case .unsupportedSchema: "The signed workflow template schema is not supported."
        case .invalidKey: "The workflow template signing key is invalid."
        case .invalidSignature: "The workflow template signature is invalid."
        case .digestMismatch: "The signed workflow manifest digest does not match its contents."
        case .untrustedSigner: "The workflow template signer is not trusted for this import."
        case .publisherMismatch: "The workflow template signer does not match its publisher declaration."
        }
    }
}

public enum DesktopWorkflowTemplateCodec {
    public static let maximumEnvelopeBytes = 512 * 1_024

    public static func sign(
        manifest: DesktopWorkflowPackageManifest,
        signerID: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> DesktopWorkflowSignedTemplateEnvelope {
        let canonical = try DesktopWorkflowPackageCodec.canonicalData(manifest)
        let digest = DesktopWorkflowPackageCodec.digest(canonical)
        let publicKey = privateKey.publicKey.rawRepresentation
        let fingerprint = DesktopWorkflowPackageCodec.digest(publicKey)
        let signature = try privateKey.signature(for: canonical)
        return DesktopWorkflowSignedTemplateEnvelope(
            manifest: manifest,
            signature: .init(
                signerID: signerID,
                publicKeyBase64: publicKey.base64EncodedString(),
                publicKeyFingerprint: fingerprint,
                manifestDigest: digest,
                signatureBase64: signature.base64EncodedString()
            )
        )
    }

    public static func canonicalData(_ envelope: DesktopWorkflowSignedTemplateEnvelope) throws -> Data {
        try DesktopWorkflowCanonicalJSON.encode(envelope)
    }

    @discardableResult
    public static func verify(
        _ envelope: DesktopWorkflowSignedTemplateEnvelope,
        trustedSignerFingerprints: Set<String>? = nil
    ) throws -> Data {
        guard envelope.schemaVersion == DesktopWorkflowSignedTemplateEnvelope.currentSchemaVersion,
              envelope.signature.algorithm == "ed25519" else {
            throw DesktopWorkflowTemplateError.unsupportedSchema
        }
        guard let publicKeyData = Data(base64Encoded: envelope.signature.publicKeyBase64),
              let signatureData = Data(base64Encoded: envelope.signature.signatureBase64),
              publicKeyData.count == 32, signatureData.count == 64,
              envelope.signature.signerID.range(
                  of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression
              ) != nil,
              envelope.signature.publicKeyFingerprint.range(
                  of: #"^[0-9a-f]{64}$"#, options: .regularExpression
              ) != nil,
              envelope.signature.manifestDigest.range(
                  of: #"^[0-9a-f]{64}$"#, options: .regularExpression
              ) != nil,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw DesktopWorkflowTemplateError.invalidKey
        }
        let fingerprint = DesktopWorkflowPackageCodec.digest(publicKeyData)
        guard fingerprint == envelope.signature.publicKeyFingerprint else {
            throw DesktopWorkflowTemplateError.invalidKey
        }
        if let trustedSignerFingerprints, !trustedSignerFingerprints.contains(fingerprint) {
            throw DesktopWorkflowTemplateError.untrustedSigner
        }
        if let publisherFingerprint = envelope.manifest.publisher?.signingKeyFingerprint,
           publisherFingerprint != fingerprint {
            throw DesktopWorkflowTemplateError.publisherMismatch
        }
        if let publisherID = envelope.manifest.publisher?.identifier,
           publisherID != envelope.signature.signerID {
            throw DesktopWorkflowTemplateError.publisherMismatch
        }
        let canonical = try DesktopWorkflowPackageCodec.canonicalData(envelope.manifest)
        guard DesktopWorkflowPackageCodec.digest(canonical) == envelope.signature.manifestDigest else {
            throw DesktopWorkflowTemplateError.digestMismatch
        }
        guard publicKey.isValidSignature(signatureData, for: canonical) else {
            throw DesktopWorkflowTemplateError.invalidSignature
        }
        return canonical
    }
}

public struct DesktopWorkflowFakeMailItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var accountID: String
    public var conversationID: String
    public var sender: String
    public var subject: String
    public var headerValues: [String: String]
    public var bodyDigest: String?

    public init(
        id: String,
        accountID: String,
        conversationID: String,
        sender: String,
        subject: String,
        headerValues: [String: String] = [:],
        bodyDigest: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.conversationID = conversationID
        self.sender = sender
        self.subject = subject
        self.headerValues = headerValues
        self.bodyDigest = bodyDigest
    }
}

public struct DesktopWorkflowFakeMailPage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var items: [DesktopWorkflowFakeMailItem]
    public var nextCursor: String?

    public init(id: String, items: [DesktopWorkflowFakeMailItem], nextCursor: String? = nil) {
        self.id = id
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct DesktopWorkflowFakeModelOutput: Codable, Equatable, Identifiable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var canonicalJSON: String

    public init(stepID: String, canonicalJSON: String) {
        self.stepID = stepID
        self.canonicalJSON = canonicalJSON
    }
}

public struct DesktopWorkflowFakeConnectorEffect: Codable, Equatable, Identifiable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var targetDigest: String
    public var postconditionJSON: String

    public init(stepID: String, targetDigest: String, postconditionJSON: String) {
        self.stepID = stepID
        self.targetDigest = targetDigest
        self.postconditionJSON = postconditionJSON
    }
}

public enum DesktopWorkflowFailureInjectionKind: String, Codable, CaseIterable, Equatable, Sendable {
    case providerThrottle
    case modelMalformedOutput
    case connectorTimeoutBeforeEffect
    case connectorOutcomeUnknown
    case processInterrupted
}

public struct DesktopWorkflowFailureInjection: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(stepID):\(attempt):\(kind.rawValue)" }
    public var stepID: String
    public var attempt: Int
    public var kind: DesktopWorkflowFailureInjectionKind
    public var recoverOnReplay: Bool

    public init(stepID: String, attempt: Int, kind: DesktopWorkflowFailureInjectionKind, recoverOnReplay: Bool = true) {
        self.stepID = stepID
        self.attempt = attempt
        self.kind = kind
        self.recoverOnReplay = recoverOnReplay
    }
}

public struct DesktopWorkflowFixtureExpectation: Codable, Equatable, Sendable {
    public var outputDigest: String
    public var timelineKinds: [String]
    public var succeeds: Bool

    public init(outputDigest: String, timelineKinds: [String], succeeds: Bool = true) {
        self.outputDigest = outputDigest
        self.timelineKinds = timelineKinds
        self.succeeds = succeeds
    }
}

public struct DesktopWorkflowFixtureCase: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var inputJSON: String
    public var mailPages: [DesktopWorkflowFakeMailPage]
    public var modelOutputs: [DesktopWorkflowFakeModelOutput]
    public var connectorEffects: [DesktopWorkflowFakeConnectorEffect]
    public var failures: [DesktopWorkflowFailureInjection]
    public var expectation: DesktopWorkflowFixtureExpectation

    public init(
        id: String,
        name: String,
        inputJSON: String,
        mailPages: [DesktopWorkflowFakeMailPage] = [],
        modelOutputs: [DesktopWorkflowFakeModelOutput] = [],
        connectorEffects: [DesktopWorkflowFakeConnectorEffect] = [],
        failures: [DesktopWorkflowFailureInjection] = [],
        expectation: DesktopWorkflowFixtureExpectation
    ) {
        self.id = id
        self.name = name
        self.inputJSON = inputJSON
        self.mailPages = mailPages
        self.modelOutputs = modelOutputs
        self.connectorEffects = connectorEffects
        self.failures = failures
        self.expectation = expectation
    }
}

public struct DesktopWorkflowFixtureSuite: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let id: String
    public var schemaVersion: Int
    public var workflowID: String
    public var workflowVersion: String
    public var cases: [DesktopWorkflowFixtureCase]

    public init(
        id: String,
        schemaVersion: Int = Self.currentSchemaVersion,
        workflowID: String,
        workflowVersion: String,
        cases: [DesktopWorkflowFixtureCase]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.cases = cases
    }

    public var digest: String {
        guard let data = try? DesktopWorkflowCanonicalJSON.encode(self) else { return "" }
        return DesktopWorkflowPackageCodec.digest(data)
    }
}

public struct DesktopWorkflowSimulationTimelineEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var sequence: Int
    public var kind: String
    public var sourceID: String
    public var detailDigest: String
}

public struct DesktopWorkflowSimulationRunRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var workflowRevisionID: String
    public var manifestDigest: String
    public var installationID: String?
    public var dependencyLockRevisionID: String?
    public var dependencyLockDigest: String?
    public var fixtureSuiteID: String
    public var fixtureSuiteDigest: String
    public var scenarioID: String
    public var inputDigest: String
    public var outputJSON: String
    public var outputDigest: String
    public var timeline: [DesktopWorkflowSimulationTimelineEvent]
    public var timelineDigest: String
    public var assertions: [DesktopWorkflowQualificationAssertionRecord]
    public var outcome: DesktopWorkflowQualificationOutcome
    public var createdAtUnixMillis: Int64
}

public struct DesktopWorkflowMigrationComparisonRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var assessmentID: String
    public var workflowID: String
    public var workflowRevisionID: String
    public var manifestDigest: String
    public var installationID: String?
    public var dependencyLockRevisionID: String?
    public var dependencyLockDigest: String?
    public var fixtureSuiteID: String
    public var fixtureSuiteDigest: String
    public var scenarioID: String
    public var simulationRunID: String
    public var legacySourceRevision: String
    public var legacyOutputDigest: String
    public var kanameOutputDigest: String
    public var matched: Bool
    public var evidenceDigest: String
    public var createdAtUnixMillis: Int64
}

public enum DesktopWorkflowSimulationError: Error, Equatable, LocalizedError, Sendable {
    case invalidSuite(String)
    case revisionMismatch
    case dependencyLockMismatch
    case scenarioUnavailable
    case expectationFailed
    case staleEvidence
    case editedEvidence

    public var errorDescription: String? {
        switch self {
        case let .invalidSuite(detail): "The workflow fixture suite is invalid: \(detail)"
        case .revisionMismatch: "The fixture suite does not match the exact installed workflow revision."
        case .dependencyLockMismatch: "The workflow dependency lock changed before simulation completed."
        case .scenarioUnavailable: "The requested workflow fixture scenario is unavailable."
        case .expectationFailed: "The deterministic workflow simulation did not satisfy its fixture expectation."
        case .staleEvidence: "The migration evidence does not match the current workflow, dependency, or fixture revisions."
        case .editedEvidence: "The migration evidence failed its integrity check."
        }
    }
}

public enum DesktopWorkflowSimulationEngine {
    public static func run(
        workflowID: String,
        workflowRevisionID: String,
        manifestDigest: String,
        installationID: String?,
        dependencyLockRevisionID: String?,
        dependencyLockDigest: String?,
        suite: DesktopWorkflowFixtureSuite,
        scenarioID: String,
        timestamp: Int64
    ) throws -> DesktopWorkflowSimulationRunRecord {
        guard suite.schemaVersion == DesktopWorkflowFixtureSuite.currentSchemaVersion,
              suite.workflowID == workflowID,
              !suite.cases.isEmpty, suite.cases.count <= 256,
              Set(suite.cases.map(\.id)).count == suite.cases.count else {
            throw DesktopWorkflowSimulationError.invalidSuite("identity, schema, or case list is invalid")
        }
        guard let scenario = suite.cases.first(where: { $0.id == scenarioID }) else {
            throw DesktopWorkflowSimulationError.scenarioUnavailable
        }
        guard scenario.inputJSON.utf8.count <= 1 * 1_024 * 1_024,
              scenario.mailPages.count <= 1_000,
              scenario.mailPages.reduce(0, { $0 + $1.items.count }) <= 100_000,
              scenario.modelOutputs.count <= 64,
              scenario.connectorEffects.count <= 64,
              scenario.failures.count <= 128,
              scenario.expectation.timelineKinds.count <= 4_096 else {
            throw DesktopWorkflowSimulationError.invalidSuite("fixture limits were exceeded")
        }
        let input = try canonicalJSON(scenario.inputJSON)
        var events: [DesktopWorkflowSimulationTimelineEvent] = []
        func append(_ kind: String, sourceID: String, detail: Data) {
            let sequence = events.count
            events.append(.init(
                id: "event-\(sequence)", sequence: sequence, kind: kind, sourceID: sourceID,
                detailDigest: DesktopWorkflowPackageCodec.digest(detail)
            ))
        }
        append("simulation.started", sourceID: scenario.id, detail: input.data)

        var seenCursors = Set<String>()
        var items: [String: DesktopWorkflowFakeMailItem] = [:]
        for page in scenario.mailPages {
            guard !seenCursors.contains(page.id) else {
                throw DesktopWorkflowSimulationError.invalidSuite("mail cursor loop at \(page.id)")
            }
            seenCursors.insert(page.id)
            let pageData = try DesktopWorkflowCanonicalJSON.encode(page)
            append("mail.page", sourceID: page.id, detail: pageData)
            for item in page.items { items[item.id] = item }
        }

        let failures = scenario.failures.sorted { $0.id < $1.id }
        for failure in failures {
            append(
                "failure.\(failure.kind.rawValue)", sourceID: failure.stepID,
                detail: try DesktopWorkflowCanonicalJSON.encode(failure)
            )
            if failure.recoverOnReplay {
                append("failure.recovered", sourceID: failure.stepID, detail: Data(failure.id.utf8))
            }
        }
        for output in scenario.modelOutputs.sorted(by: { $0.stepID < $1.stepID }) {
            let canonical = try canonicalJSON(output.canonicalJSON)
            append("model.output", sourceID: output.stepID, detail: canonical.data)
        }
        for effect in scenario.connectorEffects.sorted(by: { $0.stepID < $1.stepID }) {
            let canonical = try canonicalJSON(effect.postconditionJSON)
            append("connector.effect", sourceID: effect.stepID, detail: canonical.data)
        }

        let outputObject: [String: Any] = [
            "inputDigest": input.digest,
            "mailItemIDs": items.keys.sorted(),
            "modelOutputs": Dictionary(uniqueKeysWithValues: try scenario.modelOutputs.map {
                ($0.stepID, try canonicalJSON($0.canonicalJSON).digest)
            }),
            "connectorEffects": Dictionary(uniqueKeysWithValues: try scenario.connectorEffects.map {
                ($0.stepID, try canonicalJSON($0.postconditionJSON).digest)
            }),
            "failures": failures.map { $0.id },
        ]
        let outputData = try JSONSerialization.data(withJSONObject: outputObject, options: [.sortedKeys])
        let output = try canonicalJSON(String(decoding: outputData, as: UTF8.self))
        append("simulation.completed", sourceID: scenario.id, detail: output.data)
        let timelineData = try DesktopWorkflowCanonicalJSON.encode(events)
        let timelineKinds = events.map(\.kind)
        let outputMatches = output.digest == scenario.expectation.outputDigest
        let timelineMatches = timelineKinds == scenario.expectation.timelineKinds
        let succeeded = failures.allSatisfy(\.recoverOnReplay)
        let successMatches = succeeded == scenario.expectation.succeeds
        let assertions = [
            DesktopWorkflowQualificationAssertionRecord(
                id: "output", label: "Expected structured output", passed: outputMatches,
                detail: outputMatches ? "Output digest matched." : "Output digest differed."
            ),
            DesktopWorkflowQualificationAssertionRecord(
                id: "timeline", label: "Expected replay timeline", passed: timelineMatches,
                detail: timelineMatches ? "Timeline kinds matched." : "Timeline kinds differed."
            ),
            DesktopWorkflowQualificationAssertionRecord(
                id: "outcome", label: "Expected outcome", passed: successMatches,
                detail: successMatches ? "Outcome matched." : "Outcome differed."
            ),
        ]
        return .init(
            id: UUID().uuidString.lowercased(), workflowID: workflowID,
            workflowRevisionID: workflowRevisionID, manifestDigest: manifestDigest,
            installationID: installationID, dependencyLockRevisionID: dependencyLockRevisionID,
            dependencyLockDigest: dependencyLockDigest, fixtureSuiteID: suite.id,
            fixtureSuiteDigest: suite.digest, scenarioID: scenario.id, inputDigest: input.digest,
            outputJSON: output.json, outputDigest: output.digest, timeline: events,
            timelineDigest: DesktopWorkflowPackageCodec.digest(timelineData), assertions: assertions,
            outcome: assertions.allSatisfy(\.passed) ? .passed : .failed,
            createdAtUnixMillis: timestamp
        )
    }

    public static func replay(_ run: DesktopWorkflowSimulationRunRecord) -> Bool {
        guard let timeline = try? DesktopWorkflowCanonicalJSON.encode(run.timeline) else { return false }
        return DesktopWorkflowPackageCodec.digest(timeline) == run.timelineDigest
            && run.timeline.enumerated().allSatisfy { $0.offset == $0.element.sequence }
    }

    public static func comparisonEvidenceDigest(_ record: DesktopWorkflowMigrationComparisonRecord) -> String {
        let projection = DesktopWorkflowMigrationComparisonEvidence(
            assessmentID: record.assessmentID, workflowID: record.workflowID,
            workflowRevisionID: record.workflowRevisionID, manifestDigest: record.manifestDigest,
            installationID: record.installationID, dependencyLockRevisionID: record.dependencyLockRevisionID,
            dependencyLockDigest: record.dependencyLockDigest, fixtureSuiteID: record.fixtureSuiteID,
            fixtureSuiteDigest: record.fixtureSuiteDigest, scenarioID: record.scenarioID,
            simulationRunID: record.simulationRunID, legacySourceRevision: record.legacySourceRevision,
            legacyOutputDigest: record.legacyOutputDigest, kanameOutputDigest: record.kanameOutputDigest,
            matched: record.matched, createdAtUnixMillis: record.createdAtUnixMillis
        )
        guard let data = try? DesktopWorkflowCanonicalJSON.encode(projection) else { return "" }
        return DesktopWorkflowPackageCodec.digest(data)
    }

    private static func canonicalJSON(_ text: String) throws -> (data: Data, json: String, digest: String) {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(value) else {
            throw DesktopWorkflowSimulationError.invalidSuite("fixture JSON is invalid")
        }
        let canonical = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return (canonical, String(decoding: canonical, as: UTF8.self), DesktopWorkflowPackageCodec.digest(canonical))
    }
}

private struct DesktopWorkflowMigrationComparisonEvidence: Codable {
    var assessmentID: String
    var workflowID: String
    var workflowRevisionID: String
    var manifestDigest: String
    var installationID: String?
    var dependencyLockRevisionID: String?
    var dependencyLockDigest: String?
    var fixtureSuiteID: String
    var fixtureSuiteDigest: String
    var scenarioID: String
    var simulationRunID: String
    var legacySourceRevision: String
    var legacyOutputDigest: String
    var kanameOutputDigest: String
    var matched: Bool
    var createdAtUnixMillis: Int64
}

public enum DesktopWorkflowStarterCatalog {
    public static let publisher = DesktopWorkflowPublisher(
        name: "Kaname synthetic starter catalog", identifier: "dev.kaname.starters"
    )

    public static var manifests: [DesktopWorkflowPackageManifest] {
        subflowManifests + flowManifests
    }

    public static var fixtureSuites: [DesktopWorkflowFixtureSuite] {
        manifests.compactMap(makeFixtureSuite)
    }

    public static var subflowManifests: [DesktopWorkflowPackageManifest] {
        [
            starter("s1-readiness", "Validate installation readiness", permissions: []),
            starter("s2-search-freeze", "Complete bounded search and freeze", permissions: [.emailRead]),
            starter("s3-protect-claim", "Protect and claim", permissions: [.emailRead]),
            starter("s4-classify", "Deterministic-first classification", permissions: [.emailRead, .modelEgress]),
            starter("s5-batch-review", "Human batch review", permissions: []),
            starter("s6-effect-reconcile", "Exact effect and reconciliation", permissions: [.externalEffects]),
            starter("s7-completion", "Sanitized completion report", permissions: []),
        ]
    }

    public static var flowManifests: [DesktopWorkflowPackageManifest] {
        [
            starter("f1-mailbox-review", "Mailbox review", permissions: [.emailRead, .modelEgress], dependencies: [1, 2, 3, 4, 5, 7]),
            starter("f2-approved-cleanup", "Approved mailbox cleanup", permissions: [.emailRead, .emailLabels, .externalEffects], dependencies: [5, 6, 7]),
            starter("f3-sender-cleanup", "Exact-scope sender cleanup", permissions: [.emailRead, .emailLabels, .externalEffects], dependencies: [2, 6, 7]),
            starter("f4-financial-filing", "Financial-document filing", permissions: [.emailRead, .emailLabels, .externalEffects], dependencies: [1, 4, 6, 7]),
            starter("f5-structured-ingestion", "Structured-message ingestion", permissions: [.emailRead, .fileWrite], dependencies: [1, 2, 7]),
            starter("f6-newsletter", "Newsletter management", permissions: [.emailRead, .network, .externalEffects], dependencies: [5, 6, 7]),
            starter("f7-outbound-mail", "Draft, reply, and forward", permissions: [.emailRead, .emailDraft, .emailSend], dependencies: [5, 6, 7]),
            starter("f8-filter-rules", "Filter and rule management", permissions: [.emailRead, .externalEffects], dependencies: [5, 6, 7]),
        ]
    }

    public static func dependencyLocks(for manifest: DesktopWorkflowPackageManifest) -> [DesktopWorkflowDependencyLockEntry] {
        let byID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        return (manifest.dependencies ?? []).compactMap { dependency in
            guard let resolved = byID[dependency.id],
                  let data = try? DesktopWorkflowPackageCodec.canonicalData(resolved) else { return nil }
            return .init(
                componentID: resolved.id, kind: dependency.kind, version: resolved.version,
                digest: DesktopWorkflowPackageCodec.digest(data)
            )
        }
    }

    private static func makeFixtureSuite(_ manifest: DesktopWorkflowPackageManifest) -> DesktopWorkflowFixtureSuite? {
        let mailItem = DesktopWorkflowFakeMailItem(
            id: "synthetic-message-001", accountID: "synthetic-account",
            conversationID: "synthetic-conversation-001", sender: "sender@example.invalid",
            subject: "Synthetic \(manifest.name)", headerValues: ["x-kaname-fixture": manifest.id]
        )
        let modelOutputs = manifest.permissions.permissions.contains(.modelEgress)
            ? [DesktopWorkflowFakeModelOutput(stepID: "execute", canonicalJSON: #"{"classification":"synthetic"}"#)] : []
        let effects = manifest.permissions.permissions.contains(.externalEffects)
            ? [DesktopWorkflowFakeConnectorEffect(
                stepID: "execute", targetDigest: String(repeating: "a", count: 64),
                postconditionJSON: #"{"verified":true}"#
            )] : []
        var scenario = DesktopWorkflowFixtureCase(
            id: "synthetic-happy-path", name: "Synthetic happy path",
            inputJSON: #"{"reason":"offline qualification"}"#,
            mailPages: [.init(id: "cursor-001", items: [mailItem])],
            modelOutputs: modelOutputs, connectorEffects: effects,
            failures: [.init(stepID: "execute", attempt: 1, kind: .providerThrottle)],
            expectation: .init(outputDigest: "", timelineKinds: [])
        )
        var suite = DesktopWorkflowFixtureSuite(
            id: "\(manifest.id).fixtures", workflowID: manifest.id,
            workflowVersion: manifest.version, cases: [scenario]
        )
        guard let prototype = try? DesktopWorkflowSimulationEngine.run(
            workflowID: manifest.id, workflowRevisionID: "fixture-revision",
            manifestDigest: String(repeating: "b", count: 64), installationID: nil,
            dependencyLockRevisionID: nil, dependencyLockDigest: nil,
            suite: suite, scenarioID: scenario.id, timestamp: 0
        ) else { return nil }
        scenario.expectation = .init(
            outputDigest: prototype.outputDigest,
            timelineKinds: prototype.timeline.map(\.kind),
            succeeds: true
        )
        suite.cases = [scenario]
        return suite
    }

    private static func starter(
        _ suffix: String,
        _ name: String,
        permissions: [DesktopWorkflowPermission],
        dependencies: [Int] = []
    ) -> DesktopWorkflowPackageManifest {
        let workflowID = "dev.kaname.synthetic.\(suffix)"
        let dependencyConstraints = dependencies.map { number in
            DesktopWorkflowDependencyConstraint(
                id: "dev.kaname.synthetic.s\(number)-\(subflowSuffix(number))",
                kind: .subflow, versionRequirement: "=1.0.0"
            )
        }
        let firstKind: DesktopWorkflowStepKind = permissions.contains(.emailSend) ? .sendEmail
            : permissions.contains(.emailDraft) ? .createEmailDraft
            : permissions.contains(.externalEffects) ? .effect
            : permissions.contains(.modelEgress) ? .structuredModel : .validate
        return DesktopWorkflowPackageManifest(
            schemaVersion: 3, id: workflowID, name: name,
            summary: "Provider-neutral synthetic starter package for \(name.lowercased()).",
            icon: "shippingbox", version: "1.0.0", source: "Kaname synthetic fixtures", license: "MIT",
            triggers: [.manual], steps: [
                .init(
                    id: "execute", name: name, kind: firstKind,
                    transitions: [.init(outcome: .succeeded, targetStepID: "complete")]
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(
                permissions: permissions,
                dataClassesLeavingDevice: permissions.contains(.modelEgress) ? ["Synthetic mail projection"] : []
            ),
            correlationSummary: "Use synthetic stable message and conversation identities.",
            contextSummary: "Use fixture-only mail, model, connector, and policy inputs.",
            completionSummary: "Record exact package, dependency, fixture, and output revisions.",
            bindingSlots: [], providerFeatures: [],
            hostCompatibility: .init(minimumWorkspaceSchema: 26),
            dependencies: dependencyConstraints,
            publisher: publisher,
            provenance: .init(sourceURL: "https://github.com/Cyberlane/Kaname", sourceRevision: "synthetic-catalog-v1")
        )
    }

    private static func subflowSuffix(_ number: Int) -> String {
        switch number {
        case 1: "readiness"
        case 2: "search-freeze"
        case 3: "protect-claim"
        case 4: "classify"
        case 5: "batch-review"
        case 6: "effect-reconcile"
        default: "completion"
        }
    }
}

public extension DesktopAppModel {
    @discardableResult
    func installSignedWorkflowTemplate(
        envelopeData: Data,
        registeredCapabilityIDs: Set<String>,
        trustedSignerFingerprints: Set<String>? = nil
    ) throws -> String {
        guard envelopeData.count <= DesktopWorkflowTemplateCodec.maximumEnvelopeBytes else {
            throw DesktopWorkflowTemplateError.oversized
        }
        let envelope = try JSONDecoder().decode(DesktopWorkflowSignedTemplateEnvelope.self, from: envelopeData)
        let manifestData = try DesktopWorkflowTemplateCodec.verify(
            envelope, trustedSignerFingerprints: trustedSignerFingerprints
        )
        let revisionID = try installWorkflowPackage(
            manifestData: manifestData, registeredCapabilityIDs: registeredCapabilityIDs
        )
        let envelopeDigest = DesktopWorkflowPackageCodec.digest(
            try DesktopWorkflowTemplateCodec.canonicalData(envelope)
        )
        let timestamp = now()
        let record = DesktopWorkflowTemplateVerificationRecord(
            id: "\(revisionID):\(envelopeDigest.prefix(16))", workflowID: envelope.manifest.id,
            workflowRevisionID: revisionID, envelopeDigest: envelopeDigest,
            signerID: envelope.signature.signerID,
            publicKeyFingerprint: envelope.signature.publicKeyFingerprint,
            verifiedAtUnixMillis: timestamp
        )
        guard mutate({ state in
            if let index = state.operations.workflows.templateVerifications.firstIndex(where: { $0.id == record.id }) {
                state.operations.workflows.templateVerifications[index] = record
            } else {
                state.operations.workflows.templateVerifications.append(record)
            }
            state.appendAudit(
                domain: "workflow-template", action: "signature-verified",
                target: revisionID, state: .completed,
                detail: "Verified the exact signed template envelope before disabled installation.",
                recordedAtUnixMillis: timestamp
            )
        }) else { throw DesktopWorkflowTemplateError.invalidSignature }
        return revisionID
    }

    @discardableResult
    func installSignedWorkflowSubflow(
        envelopeData: Data,
        inputSchema: String,
        outputSchema: String,
        trustedSignerFingerprints: Set<String>? = nil
    ) throws -> String {
        guard envelopeData.count <= DesktopWorkflowTemplateCodec.maximumEnvelopeBytes else {
            throw DesktopWorkflowTemplateError.oversized
        }
        let envelope = try JSONDecoder().decode(DesktopWorkflowSignedTemplateEnvelope.self, from: envelopeData)
        _ = try DesktopWorkflowTemplateCodec.verify(
            envelope, trustedSignerFingerprints: trustedSignerFingerprints
        )
        guard installWorkflowSubflow(
            manifest: envelope.manifest, inputSchema: inputSchema, outputSchema: outputSchema
        ) else { throw DesktopWorkflowTemplateError.invalidSignature }
        let revisionID = "\(envelope.manifest.id)@\(envelope.manifest.version)"
        let envelopeDigest = DesktopWorkflowPackageCodec.digest(
            try DesktopWorkflowTemplateCodec.canonicalData(envelope)
        )
        let timestamp = now()
        let record = DesktopWorkflowTemplateVerificationRecord(
            id: "\(revisionID):\(envelopeDigest.prefix(16))", workflowID: envelope.manifest.id,
            workflowRevisionID: revisionID, envelopeDigest: envelopeDigest,
            signerID: envelope.signature.signerID,
            publicKeyFingerprint: envelope.signature.publicKeyFingerprint,
            verifiedAtUnixMillis: timestamp
        )
        guard mutate({ state in
            if !state.operations.workflows.templateVerifications.contains(where: { $0.id == record.id }) {
                state.operations.workflows.templateVerifications.append(record)
            }
            state.appendAudit(
                domain: "workflow-template", action: "signed-subflow-installed",
                target: revisionID, state: .completed,
                detail: "Verified and installed one exact pinned reusable subflow package.",
                recordedAtUnixMillis: timestamp
            )
        }) else { throw DesktopWorkflowTemplateError.invalidSignature }
        return revisionID
    }

    @discardableResult
    func simulateWorkflowFixture(
        workflowID: String,
        installationID: String? = nil,
        suite: DesktopWorkflowFixtureSuite,
        scenarioID: String
    ) throws -> String {
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == definition.currentRevisionID }),
              suite.workflowVersion == revision.version else {
            throw DesktopWorkflowSimulationError.revisionMismatch
        }
        let matching = snapshot.operations.workflows.installations.filter {
            $0.workflowID == workflowID && $0.workflowRevisionID == revision.id
        }
        let selected: DesktopWorkflowInstallationRecord?
        if let installationID {
            selected = matching.first(where: { $0.id == installationID })
            guard selected != nil else { throw DesktopWorkflowSimulationError.revisionMismatch }
        } else {
            let enabled = matching.filter(\.enabled)
            selected = enabled.count == 1 ? enabled[0] : matching.count == 1 ? matching[0] : nil
        }
        if revision.schemaVersion >= 3, selected == nil {
            throw DesktopWorkflowSimulationError.dependencyLockMismatch
        }
        let dependencyLock = selected.flatMap { installation in
            snapshot.operations.workflows.dependencyLockRevisions.first {
                $0.id == installation.currentDependencyLockRevisionID && $0.installationID == installation.id
            }
        }
        if selected != nil, dependencyLock == nil {
            throw DesktopWorkflowSimulationError.dependencyLockMismatch
        }
        let run = try DesktopWorkflowSimulationEngine.run(
            workflowID: workflowID, workflowRevisionID: revision.id, manifestDigest: revision.manifestDigest,
            installationID: selected?.id, dependencyLockRevisionID: dependencyLock?.id,
            dependencyLockDigest: dependencyLock?.digest, suite: suite, scenarioID: scenarioID,
            timestamp: now()
        )
        guard mutate({ state in
            state.operations.workflows.simulationRuns.append(run)
            state.appendAudit(
                domain: "workflow-simulation", action: run.outcome == .passed ? "passed" : "failed",
                target: "\(workflowID):\(scenarioID)",
                state: run.outcome == .passed ? .completed : .failed,
                detail: "Recorded deterministic fixture and timeline evidence for exact package and dependency revisions.",
                recordedAtUnixMillis: run.createdAtUnixMillis
            )
        }) else { throw DesktopWorkflowSimulationError.expectationFailed }
        return run.id
    }

    func replayWorkflowSimulation(id: String) -> Bool {
        guard let run = snapshot.operations.workflows.simulationRuns.first(where: { $0.id == id }) else { return false }
        return DesktopWorkflowSimulationEngine.replay(run)
    }

    @discardableResult
    func recordWorkflowMigrationComparison(
        assessmentID: String,
        simulationRunID: String,
        legacySourceRevision: String,
        legacyOutputJSON: String
    ) throws -> String {
        guard !legacySourceRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              legacySourceRevision.utf8.count <= 512,
              let assessment = snapshot.operations.workflows.migrationAssessments.first(where: { $0.id == assessmentID }),
              let run = snapshot.operations.workflows.simulationRuns.first(where: { $0.id == simulationRunID }),
              run.workflowID == assessment.workflowID,
              assessment.requiredScenarioIDs.contains(run.scenarioID) else {
            throw DesktopWorkflowSimulationError.staleEvidence
        }
        guard run.outcome == .passed, DesktopWorkflowSimulationEngine.replay(run) else {
            throw DesktopWorkflowSimulationError.editedEvidence
        }
        let legacyDigest = try Self.workflowCanonicalJSONDigest(legacyOutputJSON)
        let timestamp = now()
        var record = DesktopWorkflowMigrationComparisonRecord(
            id: UUID().uuidString.lowercased(), assessmentID: assessmentID,
            workflowID: run.workflowID, workflowRevisionID: run.workflowRevisionID,
            manifestDigest: run.manifestDigest, installationID: run.installationID,
            dependencyLockRevisionID: run.dependencyLockRevisionID,
            dependencyLockDigest: run.dependencyLockDigest, fixtureSuiteID: run.fixtureSuiteID,
            fixtureSuiteDigest: run.fixtureSuiteDigest, scenarioID: run.scenarioID,
            simulationRunID: run.id, legacySourceRevision: legacySourceRevision,
            legacyOutputDigest: legacyDigest, kanameOutputDigest: run.outputDigest,
            matched: legacyDigest == run.outputDigest, evidenceDigest: "",
            createdAtUnixMillis: timestamp
        )
        record.evidenceDigest = DesktopWorkflowSimulationEngine.comparisonEvidenceDigest(record)
        guard !record.evidenceDigest.isEmpty else { throw DesktopWorkflowSimulationError.editedEvidence }
        guard mutate({ state in
            state.operations.workflows.migrationComparisons.append(record)
            guard let index = state.operations.workflows.migrationAssessments.firstIndex(where: { $0.id == assessmentID }) else {
                return
            }
            var stored = state.operations.workflows.migrationAssessments[index]
            stored.workflowRevisionID = record.workflowRevisionID
            stored.manifestDigest = record.manifestDigest
            stored.installationID = record.installationID
            stored.dependencyLockRevisionID = record.dependencyLockRevisionID
            stored.dependencyLockDigest = record.dependencyLockDigest
            stored.fixtureSuiteID = record.fixtureSuiteID
            stored.fixtureSuiteDigest = record.fixtureSuiteDigest
            stored.comparisonEvidenceIDs = Array(Set((stored.comparisonEvidenceIDs ?? []) + [record.id])).sorted()
            if record.matched {
                stored.passedScenarioIDs = Array(Set(stored.passedScenarioIDs + [record.scenarioID])).sorted()
            } else {
                stored.passedScenarioIDs.removeAll(where: { $0 == record.scenarioID })
            }
            stored.legacyOutputDigest = record.legacyOutputDigest
            stored.kanameOutputDigest = record.kanameOutputDigest
            stored.updatedAtUnixMillis = timestamp
            state.operations.workflows.migrationAssessments[index] = stored
            state.appendAudit(
                domain: "workflow-migration", action: record.matched ? "comparison-matched" : "comparison-mismatched",
                target: "assessment:\(assessmentID):\(run.scenarioID)",
                state: record.matched ? .completed : .failed,
                detail: "Bound structured legacy and Kaname output evidence to exact source, package, dependency, and fixture revisions.",
                recordedAtUnixMillis: timestamp
            )
        }) else { throw DesktopWorkflowSimulationError.staleEvidence }
        return record.id
    }

    private static func workflowCanonicalJSONDigest(_ text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(value) else {
            throw DesktopWorkflowSimulationError.invalidSuite("legacy structured output is invalid JSON")
        }
        let canonical = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return DesktopWorkflowPackageCodec.digest(canonical)
    }
}
