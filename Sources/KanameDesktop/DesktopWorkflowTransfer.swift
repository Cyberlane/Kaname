import CryptoKit
import Foundation
import Security

public enum DesktopWorkflowTransferError: Error, Equatable, LocalizedError {
    case workflowNotFound
    case revisionNotFound
    case archiveOversized
    case invalidArchive
    case invalidPassphrase
    case installationConflict
    case unsafeArtifact
    case unsupportedSchema

    public var errorDescription: String? {
        switch self {
        case .workflowNotFound: "The workflow definition no longer exists."
        case .revisionNotFound: "The workflow revision no longer exists."
        case .archiveOversized: "The workflow installation archive exceeds Kaname's 256 MiB limit."
        case .invalidArchive: "The workflow installation archive is incomplete or has been changed."
        case .invalidPassphrase: "The passphrase is incorrect or the encrypted archive has been changed."
        case .installationConflict: "This workflow installation already exists with different local state."
        case .unsafeArtifact: "A referenced artifact could not be safely packaged or restored."
        case .unsupportedSchema: "This workflow transfer schema is not supported by this Kaname build."
        }
    }
}

public struct DesktopWorkflowInstallationArtifact: Codable, Equatable, Sendable {
    public var record: DesktopArtifactRecord
    public var data: Data?
    public var omissionReason: String?
}

public struct DesktopWorkflowInstallationPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = Self.currentSchemaVersion
    public let exportedAtUnixMillis: Int64
    public let manifest: DesktopWorkflowPackageManifest
    public let state: DesktopWorkflowPlatformState
    public let artifacts: [DesktopWorkflowInstallationArtifact]

}

public struct DesktopEncryptedTransferEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let keyDerivationRounds = 210_000

    public let schemaVersion: Int
    public let kind: String
    public let keyDerivation: String
    public let rounds: Int
    public let salt: Data
    public let sealedData: Data

    public init(kind: String, salt: Data, sealedData: Data) {
        schemaVersion = Self.currentSchemaVersion
        self.kind = kind
        keyDerivation = "PBKDF2-HMAC-SHA256"
        rounds = Self.keyDerivationRounds
        self.salt = salt
        self.sealedData = sealedData
    }
}

public enum DesktopEncryptedTransferCodec {
    public static let maximumPlaintextBytes = 256 * 1_024 * 1_024

    public static func seal<Value: Encodable>(_ value: Value, kind: String, passphrase: String) throws -> Data {
        let normalized = passphrase.precomposedStringWithCompatibilityMapping
        guard normalized.utf8.count >= 12, normalized.utf8.count <= 1_024 else {
            throw DesktopWorkflowTransferError.invalidPassphrase
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(value)
        guard plaintext.count <= maximumPlaintextBytes else { throw DesktopWorkflowTransferError.archiveOversized }
        let salt = try secureRandomData(count: 16)
        let key = try PBKDF2SHA256.deriveKey(
            password: Data(normalized.utf8),
            salt: salt,
            rounds: DesktopEncryptedTransferEnvelope.keyDerivationRounds,
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        guard let combined = sealed.combined else { throw DesktopWorkflowTransferError.invalidArchive }
        return try encoder.encode(DesktopEncryptedTransferEnvelope(kind: kind, salt: salt, sealedData: combined))
    }

    public static func open<Value: Decodable>(_ data: Data, kind: String, passphrase: String, as type: Value.Type) throws -> Value {
        guard data.count <= maximumPlaintextBytes + 64 * 1_024 else { throw DesktopWorkflowTransferError.archiveOversized }
        let envelope: DesktopEncryptedTransferEnvelope
        do {
            envelope = try JSONDecoder().decode(DesktopEncryptedTransferEnvelope.self, from: data)
        } catch {
            throw DesktopWorkflowTransferError.invalidArchive
        }
        guard envelope.schemaVersion == DesktopEncryptedTransferEnvelope.currentSchemaVersion,
              envelope.kind == kind,
              envelope.keyDerivation == "PBKDF2-HMAC-SHA256",
              envelope.rounds == DesktopEncryptedTransferEnvelope.keyDerivationRounds,
              envelope.salt.count == 16 else {
            throw DesktopWorkflowTransferError.unsupportedSchema
        }
        do {
            let key = try PBKDF2SHA256.deriveKey(
                password: Data(passphrase.precomposedStringWithCompatibilityMapping.utf8),
                salt: envelope.salt,
                rounds: envelope.rounds,
                outputByteCount: 32
            )
            let box = try AES.GCM.SealedBox(combined: envelope.sealedData)
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
            guard plaintext.count <= maximumPlaintextBytes else { throw DesktopWorkflowTransferError.archiveOversized }
            return try JSONDecoder().decode(type, from: plaintext)
        } catch let error as DesktopWorkflowTransferError {
            throw error
        } catch {
            throw DesktopWorkflowTransferError.invalidPassphrase
        }
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DesktopWorkflowTransferError.invalidArchive
        }
        return Data(bytes)
    }
}

enum PBKDF2SHA256 {
    static func deriveKey(password: Data, salt: Data, rounds: Int, outputByteCount: Int) throws -> Data {
        guard !password.isEmpty, !salt.isEmpty, rounds > 0, outputByteCount > 0 else {
            throw DesktopWorkflowTransferError.invalidPassphrase
        }
        let blockByteCount = SHA256.Digest.byteCount
        let blockCount = Int(ceil(Double(outputByteCount) / Double(blockByteCount)))
        let key = SymmetricKey(data: password)
        var output = Data()
        output.reserveCapacity(blockCount * blockByteCount)
        for blockIndex in 1...blockCount {
            var input = salt
            var bigEndian = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: &bigEndian) { input.append(contentsOf: $0) }
            var previous = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
            var accumulated = previous
            if rounds > 1 {
                for _ in 2...rounds {
                    previous = Data(HMAC<SHA256>.authenticationCode(for: previous, using: key))
                    for index in accumulated.indices { accumulated[index] ^= previous[index] }
                }
            }
            output.append(accumulated)
        }
        return output.prefix(outputByteCount)
    }
}

public extension DesktopAppModel {
    func exportWorkflowPackage(workflowID: String) throws -> Data {
        let manifest = try workflowPackageManifest(workflowID: workflowID)
        return try DesktopWorkflowPackageCodec.canonicalData(manifest)
    }

    func exportWorkflowInstallation(workflowID: String, passphrase: String) throws -> Data {
        let manifest = try workflowPackageManifest(workflowID: workflowID)
        let state = try scopedWorkflowState(workflowID: workflowID)
        let artifacts = scopedWorkflowArtifacts(state: state)
        let payload = DesktopWorkflowInstallationPayload(
            exportedAtUnixMillis: now(),
            manifest: manifest,
            state: state,
            artifacts: artifacts
        )
        return try DesktopEncryptedTransferCodec.seal(
            payload,
            kind: "kaname-workflow-installation",
            passphrase: passphrase
        )
    }

    func previewWorkflowInstallation(_ data: Data, passphrase: String) throws -> DesktopWorkflowInstallationPayload {
        let payload = try DesktopEncryptedTransferCodec.open(
            data,
            kind: "kaname-workflow-installation",
            passphrase: passphrase,
            as: DesktopWorkflowInstallationPayload.self
        )
        guard payload.schemaVersion == DesktopWorkflowInstallationPayload.currentSchemaVersion else {
            throw DesktopWorkflowTransferError.unsupportedSchema
        }
        try validateInstallationPayload(payload)
        return payload
    }

    @discardableResult
    func importWorkflowInstallation(
        _ payload: DesktopWorkflowInstallationPayload,
        registeredCapabilityIDs: Set<String>
    ) throws -> String {
        try validateInstallationPayload(payload)
        try DesktopWorkflowPackageCodec.validate(payload.manifest, registeredCapabilityIDs: registeredCapabilityIDs)
        let workflowID = payload.manifest.id
        guard !snapshot.operations.workflows.definitions.contains(where: { $0.id == workflowID }),
              !installationRecordConflicts(payload) else {
            throw DesktopWorkflowTransferError.installationConflict
        }

        var imported = payload.state
        let timestamp = now()
        removeImportedAuthority(from: &imported, timestamp: timestamp)

        let restoredArtifacts = try restoreInstallationArtifacts(
            payload.artifacts, workflowID: workflowID, artifactRoles: imported.artifactRoles
        )
        guard mutate({ state in
            state.operations.workflows.definitions.append(contentsOf: imported.definitions)
            state.operations.workflows.revisions.append(contentsOf: imported.revisions)
            state.operations.workflows.triggerBindings.append(contentsOf: imported.triggerBindings)
            state.operations.workflows.workItems.append(contentsOf: imported.workItems)
            state.operations.workflows.conversationBindings.append(contentsOf: imported.conversationBindings)
            state.operations.workflows.episodes.append(contentsOf: imported.episodes)
            state.operations.workflows.runs.append(contentsOf: imported.runs)
            state.operations.workflows.stepAttempts.append(contentsOf: imported.stepAttempts)
            state.operations.workflows.facts.append(contentsOf: imported.facts)
            state.operations.workflows.contextSnapshots.append(contentsOf: imported.contextSnapshots)
            state.operations.workflows.validations.append(contentsOf: imported.validations)
            state.operations.workflows.effects.append(contentsOf: imported.effects)
            state.operations.workflows.externalEvents.append(contentsOf: imported.externalEvents)
            state.operations.workflows.artifactEdges.append(contentsOf: imported.artifactEdges)
            state.operations.workflows.stateRecords.append(contentsOf: imported.stateRecords)
            state.operations.workflows.artifactRoles.append(contentsOf: imported.artifactRoles)
            state.operations.artifacts.append(contentsOf: restoredArtifacts)
            state.appendAudit(
                domain: "workflow-package",
                action: "installation-imported",
                target: workflowID,
                state: .proposed,
                detail: "Imported private workflow state disabled. Account, trigger, capability, and effect authority must be reviewed again.",
                recordedAtUnixMillis: timestamp
            )
        }) else {
            if let installationRoot = workflowInstallationStorageURL(workflowID: workflowID) {
                try? FileManager.default.removeItem(at: installationRoot)
            }
            throw DesktopWorkflowTransferError.invalidArchive
        }
        return workflowID
    }

    private func workflowPackageManifest(workflowID: String) throws -> DesktopWorkflowPackageManifest {
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID }) else {
            throw DesktopWorkflowTransferError.workflowNotFound
        }
        guard let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == definition.currentRevisionID }) else {
            throw DesktopWorkflowTransferError.revisionNotFound
        }
        for triggers in permutations(definition.triggerKinds) {
            let manifest = DesktopWorkflowPackageManifest(
                schemaVersion: revision.schemaVersion,
                id: definition.id,
                name: definition.name,
                summary: definition.summary,
                icon: definition.icon,
                version: revision.version,
                source: definition.source,
                license: definition.license,
                triggers: triggers,
                steps: revision.steps,
                permissions: revision.permissions,
                correlationSummary: revision.correlationSummary,
                contextSummary: revision.contextSummary,
                completionSummary: revision.completionSummary
            )
            let canonical = try DesktopWorkflowPackageCodec.canonicalData(manifest)
            if DesktopWorkflowPackageCodec.digest(canonical) == revision.manifestDigest {
                return manifest
            }
        }
        throw DesktopWorkflowTransferError.invalidArchive
    }

    private func removeImportedAuthority(from state: inout DesktopWorkflowPlatformState, timestamp: Int64) {
        for index in state.definitions.indices {
            state.definitions[index].enabled = false
            state.definitions[index].updatedAtUnixMillis = timestamp
        }
        for index in state.triggerBindings.indices {
            state.triggerBindings[index].enabled = false
            state.triggerBindings[index].lastCursor = nil
            state.triggerBindings[index].updatedAtUnixMillis = timestamp
        }
        for index in state.workItems.indices where !state.workItems[index].state.isHistorical {
            state.workItems[index].state = .needsAttention
            state.workItems[index].nextAction = "Review imported accounts, capabilities, and context before resuming."
            state.workItems[index].explicitAcceptance = false
            state.workItems[index].updatedAtUnixMillis = timestamp
        }
        let activeRuns: Set<DesktopWorkflowRunState> = [.queued, .running, .waiting]
        for index in state.runs.indices where activeRuns.contains(state.runs[index].state) {
            state.runs[index].state = .cancelled
            state.runs[index].completedAtUnixMillis = timestamp
        }
        for index in state.stepAttempts.indices where activeRuns.contains(state.stepAttempts[index].state) {
            state.stepAttempts[index].state = .cancelled
            state.stepAttempts[index].errorSummary = "Cancelled during private installation transfer."
            state.stepAttempts[index].completedAtUnixMillis = timestamp
        }
        let pendingEffects: Set<DesktopWorkflowEffectState> = [.proposed, .awaitingApproval, .approved, .executing]
        for index in state.effects.indices where pendingEffects.contains(state.effects[index].state) {
            state.effects[index].state = .cancelled
            state.effects[index].approvalID = nil
        }
    }

    private func permutations<Element>(_ values: [Element]) -> [[Element]] {
        guard values.count > 1 else { return [values] }
        return values.indices.flatMap { index in
            var remaining = values
            let value = remaining.remove(at: index)
            return permutations(remaining).map { [value] + $0 }
        }
    }

    private func scopedWorkflowState(workflowID: String) throws -> DesktopWorkflowPlatformState {
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID }) else {
            throw DesktopWorkflowTransferError.workflowNotFound
        }
        let workItems = snapshot.operations.workflows.workItems.filter { $0.workflowID == workflowID }
        let workItemIDs = Set(workItems.map(\.id))
        let episodes = snapshot.operations.workflows.episodes.filter { workItemIDs.contains($0.workItemID) }
        let episodeIDs = Set(episodes.map(\.id))
        let runs = snapshot.operations.workflows.runs.filter { workItemIDs.contains($0.workItemID) && episodeIDs.contains($0.episodeID) }
        let runIDs = Set(runs.map(\.id))
        return DesktopWorkflowPlatformState(
            definitions: [definition],
            revisions: snapshot.operations.workflows.revisions.filter { $0.workflowID == workflowID },
            triggerBindings: snapshot.operations.workflows.triggerBindings.filter { $0.workflowID == workflowID },
            workItems: workItems,
            conversationBindings: snapshot.operations.workflows.conversationBindings.filter { workItemIDs.contains($0.workItemID) },
            episodes: episodes,
            runs: runs,
            stepAttempts: snapshot.operations.workflows.stepAttempts.filter { runIDs.contains($0.runID) },
            facts: snapshot.operations.workflows.facts.filter { workItemIDs.contains($0.workItemID) },
            contextSnapshots: snapshot.operations.workflows.contextSnapshots.filter { workItemIDs.contains($0.workItemID) },
            validations: snapshot.operations.workflows.validations.filter { runIDs.contains($0.runID) },
            effects: snapshot.operations.workflows.effects.filter { runIDs.contains($0.runID) },
            externalEvents: snapshot.operations.workflows.externalEvents.filter { event in
                snapshot.operations.workflows.episodes.contains { episodeIDs.contains($0.id) && $0.sourceEventID == event.id }
            },
            artifactEdges: snapshot.operations.workflows.artifactEdges.filter { edge in
                let referenced = referencedArtifactIDs(workItems: workItems, runs: runs)
                return referenced.contains(edge.fromArtifactID) || referenced.contains(edge.toID)
            },
            stateRecords: snapshot.operations.workflows.stateRecords.filter { $0.workflowID == workflowID },
            artifactRoles: snapshot.operations.workflows.artifactRoles.filter { workItemIDs.contains($0.workItemID) },
            capabilityInstallations: [],
            runtimeClaims: []
        )
    }

    private func referencedArtifactIDs(
        workItems: [DesktopWorkflowWorkItemRecord],
        runs: [DesktopWorkflowRunRecord]
    ) -> Set<String> {
        let runIDs = Set(runs.map(\.id))
        var ids = Set(snapshot.operations.workflows.stepAttempts.filter { runIDs.contains($0.runID) }.flatMap(\.artifactIDs))
        ids.formUnion(snapshot.operations.workflows.validations.filter { runIDs.contains($0.runID) }.flatMap(\.evidenceArtifactIDs))
        let workItemIDs = Set(workItems.map(\.id))
        for edge in snapshot.operations.workflows.artifactEdges where workItemIDs.contains(where: { id in
            snapshot.operations.workflows.effects.contains { $0.workItemID == id && ($0.id == edge.toID || $0.id == edge.fromArtifactID) }
        }) {
            ids.insert(edge.fromArtifactID)
            ids.insert(edge.toID)
        }
        return ids
    }

    private func scopedWorkflowArtifacts(state: DesktopWorkflowPlatformState) -> [DesktopWorkflowInstallationArtifact] {
        let runIDs = Set(state.runs.map(\.id))
        var ids = Set(state.stepAttempts.filter { runIDs.contains($0.runID) }.flatMap(\.artifactIDs))
        ids.formUnion(state.validations.flatMap(\.evidenceArtifactIDs))
        ids.formUnion(state.artifactEdges.map(\.fromArtifactID))
        ids.formUnion(state.artifactEdges.map(\.toID))
        ids.formUnion(state.artifactRoles.map(\.artifactDigest))
        var records = snapshot.operations.artifacts.filter { ids.contains($0.id) }
        if let workflowID = state.definitions.first?.id,
           let storage = workflowStorage(workflowID: workflowID),
           let stored = try? storage.artifactRecords() {
            for artifact in stored where ids.contains(artifact.sha256) && !records.contains(where: { $0.digest == artifact.sha256 }) {
                records.append(DesktopArtifactRecord(
                    id: artifact.sha256, threadID: nil, name: artifact.filename, kind: .file,
                    localPath: (try? storage.artifactURL(sha256: artifact.sha256))?.path ?? "",
                    digest: artifact.sha256, provenance: "Private workflow artifact",
                    createdAtUnixMillis: artifact.createdAtUnixMillis
                ))
            }
        }
        var remainingBytes = 128 * 1_024 * 1_024
        return records.sorted { $0.id < $1.id }.map { artifact in
            let url = URL(fileURLWithPath: artifact.localPath)
            guard !artifact.localPath.isEmpty,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize <= 32 * 1_024 * 1_024,
                  fileSize <= remainingBytes,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  DesktopRecoveryService.sha256(data) == artifact.digest else {
                return DesktopWorkflowInstallationArtifact(
                    record: artifact,
                    data: nil,
                    omissionReason: "The original file was unavailable, unsafe, oversized, or no longer matched its recorded digest."
                )
            }
            remainingBytes -= data.count
            return DesktopWorkflowInstallationArtifact(record: artifact, data: data, omissionReason: nil)
        }
    }

    private func validateInstallationPayload(_ payload: DesktopWorkflowInstallationPayload) throws {
        let state = payload.state
        let revisionIDs = Set(state.revisions.map(\.id))
        let workItemIDs = Set(state.workItems.map(\.id))
        let episodeIDs = Set(state.episodes.map(\.id))
        let runIDs = Set(state.runs.map(\.id))
        let contextIDs = Set(state.contextSnapshots.map(\.id))
        let externalEventIDs = Set(state.externalEvents.map(\.id))
        let artifactIDs = Set(payload.artifacts.map(\.record.id))
        let activeArtifactRoles = state.artifactRoles.filter(\.active).map { "\($0.workItemID):\($0.role)" }
        guard payload.schemaVersion == DesktopWorkflowInstallationPayload.currentSchemaVersion,
              state.definitions.count == 1,
              state.definitions[0].id == payload.manifest.id,
              state.definitions[0].name == payload.manifest.name,
              state.definitions[0].summary == payload.manifest.summary,
              state.definitions[0].source == payload.manifest.source,
              state.definitions[0].license == payload.manifest.license,
              revisionIDs.contains(state.definitions[0].currentRevisionID),
              uniqueIDs(state.revisions), uniqueIDs(state.triggerBindings), uniqueIDs(state.workItems),
              uniqueIDs(state.conversationBindings), uniqueIDs(state.episodes), uniqueIDs(state.runs),
              uniqueIDs(state.stepAttempts), uniqueIDs(state.facts), uniqueIDs(state.contextSnapshots),
              uniqueIDs(state.validations), uniqueIDs(state.effects), uniqueIDs(state.externalEvents),
              uniqueIDs(state.artifactEdges), uniqueIDs(state.stateRecords), uniqueIDs(state.artifactRoles),
              artifactIDs.count == payload.artifacts.count,
              state.capabilityInstallations.isEmpty, state.runtimeClaims.isEmpty,
              state.revisions.allSatisfy({ $0.workflowID == payload.manifest.id }),
              state.triggerBindings.allSatisfy({ $0.workflowID == payload.manifest.id }),
              state.workItems.allSatisfy({ $0.workflowID == payload.manifest.id }),
              state.stateRecords.allSatisfy({ $0.workflowID == payload.manifest.id }),
              state.stateRecords.allSatisfy({ record in
                  record.revision > 0 && record.schemaVersion > 0 && record.scopeID?.isEmpty == false
                      && DesktopWorkflowJSONSchemaValidator.validateSchema(Data(record.schema.utf8))
                      && DesktopWorkflowJSONSchemaValidator.validates(instance: record.value, against: record.schema)
              }),
              Set(activeArtifactRoles).count == activeArtifactRoles.count,
              state.artifactRoles.allSatisfy({
                  $0.workflowID == payload.manifest.id && workItemIDs.contains($0.workItemID)
                      && episodeIDs.contains($0.episodeID) && artifactIDs.contains($0.artifactDigest)
              }),
              state.conversationBindings.allSatisfy({ workItemIDs.contains($0.workItemID) }),
              state.episodes.allSatisfy({
                  workItemIDs.contains($0.workItemID) && revisionIDs.contains($0.workflowRevisionID)
                      && externalEventIDs.contains($0.sourceEventID)
              }),
              state.runs.allSatisfy({
                  workItemIDs.contains($0.workItemID) && episodeIDs.contains($0.episodeID)
                      && revisionIDs.contains($0.workflowRevisionID)
                      && ($0.contextSnapshotID == nil || contextIDs.contains($0.contextSnapshotID!))
              }),
              state.stepAttempts.allSatisfy({ runIDs.contains($0.runID) }),
              state.facts.allSatisfy({ workItemIDs.contains($0.workItemID) && episodeIDs.contains($0.episodeID) }),
              state.contextSnapshots.allSatisfy({ workItemIDs.contains($0.workItemID) && episodeIDs.contains($0.episodeID) }),
              state.validations.allSatisfy({
                  workItemIDs.contains($0.workItemID) && episodeIDs.contains($0.episodeID) && runIDs.contains($0.runID)
              }),
              state.effects.allSatisfy({
                  workItemIDs.contains($0.workItemID) && episodeIDs.contains($0.episodeID) && runIDs.contains($0.runID)
              }),
              state.artifactEdges.allSatisfy({ artifactIDs.contains($0.fromArtifactID) }) else {
            throw DesktopWorkflowTransferError.invalidArchive
        }
        let canonical = try DesktopWorkflowPackageCodec.canonicalData(payload.manifest)
        guard let current = payload.state.revisions.first(where: { $0.id == payload.state.definitions[0].currentRevisionID }),
              current.manifestDigest == DesktopWorkflowPackageCodec.digest(canonical) else {
            throw DesktopWorkflowTransferError.invalidArchive
        }
        var total = 0
        for artifact in payload.artifacts {
            guard artifact.record.digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
                throw DesktopWorkflowTransferError.unsafeArtifact
            }
            guard let data = artifact.data else { continue }
            total += data.count
            guard data.count <= 32 * 1_024 * 1_024,
                  total <= 128 * 1_024 * 1_024,
                  DesktopRecoveryService.sha256(data) == artifact.record.digest else {
                throw DesktopWorkflowTransferError.unsafeArtifact
            }
        }
    }

    private func uniqueIDs<Value: Identifiable>(_ values: [Value]) -> Bool where Value.ID == String {
        Set(values.map(\.id)).count == values.count
    }

    private func installationRecordConflicts(_ payload: DesktopWorkflowInstallationPayload) -> Bool {
        let current = snapshot.operations.workflows
        return intersects(payload.state.revisions, current.revisions)
            || intersects(payload.state.triggerBindings, current.triggerBindings)
            || intersects(payload.state.workItems, current.workItems)
            || intersects(payload.state.conversationBindings, current.conversationBindings)
            || intersects(payload.state.episodes, current.episodes)
            || intersects(payload.state.runs, current.runs)
            || intersects(payload.state.stepAttempts, current.stepAttempts)
            || intersects(payload.state.facts, current.facts)
            || intersects(payload.state.contextSnapshots, current.contextSnapshots)
            || intersects(payload.state.validations, current.validations)
            || intersects(payload.state.effects, current.effects)
            || intersects(payload.state.externalEvents, current.externalEvents)
            || intersects(payload.state.artifactEdges, current.artifactEdges)
            || intersects(payload.state.stateRecords, current.stateRecords)
            || intersects(payload.state.artifactRoles, current.artifactRoles)
            || !Set(payload.artifacts.map(\.record.id)).isDisjoint(with: snapshot.operations.artifacts.map(\.id))
    }

    private func intersects<Value: Identifiable>(_ imported: [Value], _ current: [Value]) -> Bool where Value.ID == String {
        !Set(imported.map(\.id)).isDisjoint(with: current.map(\.id))
    }

    private func restoreInstallationArtifacts(
        _ artifacts: [DesktopWorkflowInstallationArtifact],
        workflowID: String,
        artifactRoles: [DesktopWorkflowArtifactRoleRecord]
    ) throws -> [DesktopArtifactRecord] {
        guard let root = workflowInstallationStorageURL(workflowID: workflowID) else {
            return artifacts.map { artifact in
                var record = artifact.record
                record.localPath = ""
                return record
            }
        }
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw DesktopWorkflowTransferError.installationConflict
        }
        let storage = DesktopWorkflowStorage(installationRoot: root)
        return try artifacts.map { artifact in
            var record = artifact.record
            guard let data = artifact.data else {
                record.localPath = ""
                return record
            }
            let role = artifactRoles.first { $0.artifactDigest == artifact.record.digest }
            let stored = try storage.importArtifact(
                data: data, filename: role?.filename ?? artifact.record.name,
                mediaType: role?.mediaType ?? "application/octet-stream",
                createdAtUnixMillis: artifact.record.createdAtUnixMillis
            )
            guard stored.sha256 == artifact.record.digest else { throw DesktopWorkflowTransferError.unsafeArtifact }
            record.localPath = try storage.artifactURL(sha256: stored.sha256).path
            return record
        }
    }
}
