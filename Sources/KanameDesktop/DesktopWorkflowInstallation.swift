import CryptoKit
import Foundation
import KanameDomain

public enum DesktopWorkflowBindingSlotKind: String, Codable, CaseIterable, Equatable, Sendable {
    case account
    case providerResource
    case folder
    case secretReference
    case capability
    case connector
    case renderer
    case subflow

    public var label: String {
        switch self {
        case .account: "Account"
        case .providerResource: "Provider resource"
        case .folder: "Folder"
        case .secretReference: "Secret reference"
        case .capability: "Capability"
        case .connector: "Connector"
        case .renderer: "Renderer"
        case .subflow: "Reusable subflow"
        }
    }
}

public struct DesktopWorkflowBindingSlotDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var label: String
    public var summary: String
    public var kind: DesktopWorkflowBindingSlotKind
    public var required: Bool
    public var allowsMultiple: Bool
    public var providerFeatureID: String?

    public init(
        id: String,
        label: String,
        summary: String,
        kind: DesktopWorkflowBindingSlotKind,
        required: Bool = true,
        allowsMultiple: Bool = false,
        providerFeatureID: String? = nil
    ) {
        self.id = id
        self.label = label
        self.summary = summary
        self.kind = kind
        self.required = required
        self.allowsMultiple = allowsMultiple
        self.providerFeatureID = providerFeatureID
    }
}

public struct DesktopWorkflowProviderFeatureRequirement: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var providerKind: String
    public var feature: String
    public var required: Bool
    public var explanation: String

    public init(id: String, providerKind: String, feature: String, required: Bool = true, explanation: String) {
        self.id = id
        self.providerKind = providerKind
        self.feature = feature
        self.required = required
        self.explanation = explanation
    }
}

public struct DesktopWorkflowHostCompatibility: Codable, Equatable, Sendable {
    public var minimumWorkspaceSchema: Int
    public var maximumWorkspaceSchema: Int?
    public var minimumHostVersion: String?
    public var maximumHostVersion: String?

    public init(
        minimumWorkspaceSchema: Int,
        maximumWorkspaceSchema: Int? = nil,
        minimumHostVersion: String? = nil,
        maximumHostVersion: String? = nil
    ) {
        self.minimumWorkspaceSchema = minimumWorkspaceSchema
        self.maximumWorkspaceSchema = maximumWorkspaceSchema
        self.minimumHostVersion = minimumHostVersion
        self.maximumHostVersion = maximumHostVersion
    }

    public func supports(workspaceSchema: Int) -> Bool {
        workspaceSchema >= minimumWorkspaceSchema && workspaceSchema <= (maximumWorkspaceSchema ?? Int.max)
    }
}

public enum DesktopWorkflowDependencyKind: String, Codable, CaseIterable, Equatable, Sendable {
    case workflow
    case capability
    case connector
    case renderer
    case subflow
}

public struct DesktopWorkflowDependencyConstraint: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var kind: DesktopWorkflowDependencyKind
    public var versionRequirement: String
    public var required: Bool

    public init(id: String, kind: DesktopWorkflowDependencyKind, versionRequirement: String, required: Bool = true) {
        self.id = id
        self.kind = kind
        self.versionRequirement = versionRequirement
        self.required = required
    }
}

enum DesktopWorkflowVersionConstraint {
    static func satisfies(version: String, requirement: String) -> Bool {
        let alternatives = requirement.split(separator: "|").map(String.init).filter { !$0.isEmpty }
        return alternatives.contains { alternative in
            alternative.replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .allSatisfy { satisfiesClause(version: version, clause: $0) }
        }
    }

    private static func satisfiesClause(version: String, clause: String) -> Bool {
        if clause == "*" { return true }
        guard let actual = components(version) else { return false }
        if clause.hasPrefix("^") {
            guard let floor = components(String(clause.dropFirst())) else { return false }
            let ceiling = floor[0] > 0 ? [floor[0] + 1, 0, 0, 0]
                : floor[1] > 0 ? [0, floor[1] + 1, 0, 0] : [0, 0, floor[2] + 1, 0]
            return compare(actual, floor) >= 0 && compare(actual, ceiling) < 0
        }
        if clause.hasPrefix("~") {
            guard let floor = components(String(clause.dropFirst())) else { return false }
            let ceiling = [floor[0], floor[1] + 1, 0, 0]
            return compare(actual, floor) >= 0 && compare(actual, ceiling) < 0
        }
        for operation in [">=", "<=", ">", "<", "="] where clause.hasPrefix(operation) {
            guard let expected = components(String(clause.dropFirst(operation.count))) else { return false }
            let order = compare(actual, expected)
            switch operation {
            case ">=": return order >= 0
            case "<=": return order <= 0
            case ">": return order > 0
            case "<": return order < 0
            default: return order == 0
            }
        }
        guard let expected = components(clause) else { return false }
        return compare(actual, expected) == 0
    }

    private static func components(_ value: String) -> [Int]? {
        let numeric = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let values = numeric.split(separator: ".").map(String.init)
        guard !values.isEmpty, values.count <= 4,
              values.allSatisfy({ Int($0) != nil }) else { return nil }
        return values.compactMap(Int.init) + Array(repeating: 0, count: 4 - values.count)
    }

    private static func compare(_ left: [Int], _ right: [Int]) -> Int {
        for index in 0..<min(left.count, right.count) {
            if left[index] != right[index] { return left[index] < right[index] ? -1 : 1 }
        }
        return 0
    }
}

public struct DesktopWorkflowPublisher: Codable, Equatable, Sendable {
    public var name: String
    public var identifier: String
    public var website: String?
    public var signingKeyFingerprint: String?

    public init(name: String, identifier: String, website: String? = nil, signingKeyFingerprint: String? = nil) {
        self.name = name
        self.identifier = identifier
        self.website = website
        self.signingKeyFingerprint = signingKeyFingerprint
    }
}

public struct DesktopWorkflowPackageProvenance: Codable, Equatable, Sendable {
    public var sourceURL: String?
    public var sourceRevision: String?
    public var buildSystem: String?
    public var builtAtUnixMillis: Int64?

    public init(
        sourceURL: String? = nil,
        sourceRevision: String? = nil,
        buildSystem: String? = nil,
        builtAtUnixMillis: Int64? = nil
    ) {
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.buildSystem = buildSystem
        self.builtAtUnixMillis = builtAtUnixMillis
    }
}

public enum DesktopWorkflowFormControl: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case text
    case multilineText
    case toggle
    case number
    case picker
    case date
    case dateTime
}

public struct DesktopWorkflowUIHint: Codable, Equatable, Identifiable, Sendable {
    public var id: String { pointer }
    public var pointer: String
    public var control: DesktopWorkflowFormControl
    public var label: String?
    public var help: String?
    public var placeholder: String?

    public init(
        pointer: String,
        control: DesktopWorkflowFormControl = .automatic,
        label: String? = nil,
        help: String? = nil,
        placeholder: String? = nil
    ) {
        self.pointer = pointer
        self.control = control
        self.label = label
        self.help = help
        self.placeholder = placeholder
    }
}

public enum DesktopWorkflowConfigurationMigrationOperationKind: String, Codable, CaseIterable, Equatable, Sendable {
    case rename
    case setDefault
    case remove
}

public struct DesktopWorkflowConfigurationMigrationOperation: Codable, Equatable, Sendable {
    public var kind: DesktopWorkflowConfigurationMigrationOperationKind
    public var pointer: String
    public var destinationPointer: String?
    /// Canonical JSON fragment. Secret values are never a valid migration input.
    public var value: String?

    public init(
        kind: DesktopWorkflowConfigurationMigrationOperationKind,
        pointer: String,
        destinationPointer: String? = nil,
        value: String? = nil
    ) {
        self.kind = kind
        self.pointer = pointer
        self.destinationPointer = destinationPointer
        self.value = value
    }
}

public struct DesktopWorkflowConfigurationMigration: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(fromVersion)-\(toVersion)" }
    public var fromVersion: Int
    public var toVersion: Int
    public var operations: [DesktopWorkflowConfigurationMigrationOperation]

    public init(fromVersion: Int, toVersion: Int, operations: [DesktopWorkflowConfigurationMigrationOperation]) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.operations = operations
    }
}

public struct DesktopWorkflowInstallationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var name: String
    public var workflowRevisionID: String
    public var currentConfigurationRevisionID: String
    public var currentBindingRevisionID: String
    public var currentDependencyLockRevisionID: String
    public var currentCapturePolicyRevisionID: String
    public var currentRetentionPolicyRevisionID: String
    public var enabled: Bool
    public var readinessIssues: [String]
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

public struct DesktopWorkflowConfigurationRevisionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var installationID: String
    public var schemaVersion: Int
    public var canonicalJSON: String
    public var digest: String
    public var migratedFromRevisionID: String?
    public var createdAtUnixMillis: Int64
}

public struct DesktopWorkflowBindingResolution: Codable, Equatable, Identifiable, Sendable {
    public var id: String { slotID }
    public var slotID: String
    public var kind: DesktopWorkflowBindingSlotKind
    /// Stable local/provider identifier or a Keychain reference name. Never a secret value.
    public var resourceIDs: [String]
    public var displayLabels: [String]

    public init(slotID: String, kind: DesktopWorkflowBindingSlotKind, resourceIDs: [String], displayLabels: [String]) {
        self.slotID = slotID
        self.kind = kind
        self.resourceIDs = resourceIDs
        self.displayLabels = displayLabels
    }
}

public struct DesktopWorkflowBindingRevisionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var installationID: String
    public var resolutions: [DesktopWorkflowBindingResolution]
    public var digest: String
    public var createdAtUnixMillis: Int64
}

public struct DesktopWorkflowDependencyLockEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(kind.rawValue):\(componentID)" }
    public var componentID: String
    public var kind: DesktopWorkflowDependencyKind
    public var version: String
    public var digest: String?

    public init(componentID: String, kind: DesktopWorkflowDependencyKind, version: String, digest: String? = nil) {
        self.componentID = componentID
        self.kind = kind
        self.version = version
        self.digest = digest
    }
}

public struct DesktopWorkflowDependencyLockRevisionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var installationID: String
    public var entries: [DesktopWorkflowDependencyLockEntry]
    public var digest: String
    public var createdAtUnixMillis: Int64
}

public enum DesktopWorkflowMailCaptureLevel: String, Codable, CaseIterable, Equatable, Sendable {
    case metadataOnly
    case allowlistedHeaders
    case selectedBodyParts
    case fullBody
}

public struct DesktopWorkflowCapturePolicy: Codable, Equatable, Sendable {
    public var mailLevel: DesktopWorkflowMailCaptureLevel
    public var headerAllowlist: [String]
    public var includeAttachments: Bool
    public var attachmentMIMETypes: [String]
    public var maximumAttachmentBytes: Int
    public var maximumTotalBytes: Int
    public var maximumAttachmentCount: Int

    public init(
        mailLevel: DesktopWorkflowMailCaptureLevel = .metadataOnly,
        headerAllowlist: [String] = [],
        includeAttachments: Bool = false,
        attachmentMIMETypes: [String] = [],
        maximumAttachmentBytes: Int = 0,
        maximumTotalBytes: Int = 0,
        maximumAttachmentCount: Int = 0
    ) {
        self.mailLevel = mailLevel
        self.headerAllowlist = headerAllowlist
        self.includeAttachments = includeAttachments
        self.attachmentMIMETypes = attachmentMIMETypes
        self.maximumAttachmentBytes = maximumAttachmentBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumAttachmentCount = maximumAttachmentCount
    }
}

public struct DesktopWorkflowCapturePolicyRevisionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var installationID: String
    public var policy: DesktopWorkflowCapturePolicy
    public var digest: String
    public var createdAtUnixMillis: Int64
}

public enum DesktopWorkflowSettledContentPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case purgeOrdinaryContent
    case retainUntilExplicitRemoval
}

public struct DesktopWorkflowRetentionPolicy: Codable, Equatable, Sendable {
    public var settledContent: DesktopWorkflowSettledContentPolicy
    public var retainAuditReceipts: Bool
    public var retainPromotedArtifacts: Bool
    public var unresolvedContentMaximumDays: Int?

    public init(
        settledContent: DesktopWorkflowSettledContentPolicy = .purgeOrdinaryContent,
        retainAuditReceipts: Bool = true,
        retainPromotedArtifacts: Bool = true,
        unresolvedContentMaximumDays: Int? = nil
    ) {
        self.settledContent = settledContent
        self.retainAuditReceipts = retainAuditReceipts
        self.retainPromotedArtifacts = retainPromotedArtifacts
        self.unresolvedContentMaximumDays = unresolvedContentMaximumDays
    }
}

public struct DesktopWorkflowRetentionPolicyRevisionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var installationID: String
    public var policy: DesktopWorkflowRetentionPolicy
    public var digest: String
    public var createdAtUnixMillis: Int64
}

public struct DesktopWorkflowUpgradeDiff: Equatable, Sendable {
    public var fromRevisionID: String
    public var toRevisionID: String
    public var configurationSchemaChanged: Bool
    public var addedBindingSlotIDs: [String]
    public var removedBindingSlotIDs: [String]
    public var addedDependencyIDs: [String]
    public var removedDependencyIDs: [String]
    public var permissionBroadening: Bool
    public var authorityCarriedForward: Bool

    public init(
        fromRevisionID: String,
        toRevisionID: String,
        configurationSchemaChanged: Bool,
        addedBindingSlotIDs: [String],
        removedBindingSlotIDs: [String],
        addedDependencyIDs: [String],
        removedDependencyIDs: [String],
        permissionBroadening: Bool,
        authorityCarriedForward: Bool = false
    ) {
        self.fromRevisionID = fromRevisionID
        self.toRevisionID = toRevisionID
        self.configurationSchemaChanged = configurationSchemaChanged
        self.addedBindingSlotIDs = addedBindingSlotIDs
        self.removedBindingSlotIDs = removedBindingSlotIDs
        self.addedDependencyIDs = addedDependencyIDs
        self.removedDependencyIDs = removedDependencyIDs
        self.permissionBroadening = permissionBroadening
        self.authorityCarriedForward = authorityCarriedForward
    }
}

public struct DesktopWorkflowFormField: Codable, Equatable, Identifiable, Sendable {
    public var id: String { pointer }
    public var pointer: String
    public var title: String
    public var description: String?
    public var type: String
    public var format: String?
    public var required: Bool
    public var defaultJSON: String?
    public var enumChoices: [String]
    public var control: DesktopWorkflowFormControl
    public var placeholder: String?
}

public enum DesktopWorkflowSchemaForm {
    public static func fields(schemaText: String, hints: [DesktopWorkflowUIHint] = []) -> [DesktopWorkflowFormField] {
        guard let data = schemaText.data(using: .utf8),
              DesktopWorkflowJSONSchemaValidator.schemaDiagnostics(data).isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = root["properties"] as? [String: Any] else { return [] }
        let required = Set(root["required"] as? [String] ?? [])
        return properties.keys.sorted().compactMap { key in
            guard let schema = properties[key] as? [String: Any] else { return nil }
            let pointer = "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            let hint = hints.first { $0.pointer == pointer }
            let type = schema["type"] as? String ?? "string"
            let defaultJSON = schema["default"].flatMap(canonicalFragment)
            let choices = (schema["enum"] as? [Any] ?? []).compactMap(canonicalFragment)
            return DesktopWorkflowFormField(
                pointer: pointer,
                title: hint?.label ?? schema["title"] as? String ?? humanized(key),
                description: hint?.help ?? schema["description"] as? String,
                type: type,
                format: schema["format"] as? String,
                required: required.contains(key),
                defaultJSON: defaultJSON,
                enumChoices: choices,
                control: resolvedControl(hint?.control ?? .automatic, type: type, format: schema["format"] as? String, hasChoices: !choices.isEmpty),
                placeholder: hint?.placeholder
            )
        }
    }

    private static func resolvedControl(
        _ requested: DesktopWorkflowFormControl,
        type: String,
        format: String?,
        hasChoices: Bool
    ) -> DesktopWorkflowFormControl {
        if requested != .automatic { return requested }
        if hasChoices { return .picker }
        if type == "boolean" { return .toggle }
        if type == "integer" || type == "number" { return .number }
        if format == "date" { return .date }
        if format == "date-time" { return .dateTime }
        return .text
    }

    private static func canonicalFragment(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]),
              var text = String(data: data, encoding: .utf8) else { return nil }
        text.removeFirst()
        text.removeLast()
        return text
    }

    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
}

enum DesktopWorkflowRevisionDigest {
    static func canonical<Value: Encodable>(_ value: Value) throws -> (json: String, digest: String) {
        let data = try DesktopWorkflowCanonicalJSON.encode(value)
        guard let json = String(data: data, encoding: .utf8) else { throw DesktopWorkflowPackageError.invalidSchema }
        return (json, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func canonicalJSON(_ data: Data) throws -> (json: String, digest: String) {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard JSONSerialization.isValidJSONObject(object) else { throw DesktopWorkflowPackageError.invalidSchema }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: canonical, encoding: .utf8) else { throw DesktopWorkflowPackageError.invalidSchema }
        return (json, SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined())
    }
}

struct DesktopWorkflowInstallationSeed {
    var installation: DesktopWorkflowInstallationRecord
    var configuration: DesktopWorkflowConfigurationRevisionRecord
    var binding: DesktopWorkflowBindingRevisionRecord
    var dependencyLock: DesktopWorkflowDependencyLockRevisionRecord
    var capturePolicy: DesktopWorkflowCapturePolicyRevisionRecord
    var retentionPolicy: DesktopWorkflowRetentionPolicyRevisionRecord

    static func make(
        manifest: DesktopWorkflowPackageManifest,
        revisionID: String,
        installationID: String,
        name: String,
        configurationData: Data? = nil,
        resolutions: [DesktopWorkflowBindingResolution] = [],
        dependencyEntries: [DesktopWorkflowDependencyLockEntry] = [],
        capturePolicy: DesktopWorkflowCapturePolicy = .init(),
        retentionPolicy: DesktopWorkflowRetentionPolicy = .init(),
        timestamp: Int64
    ) throws -> Self {
        let configData = configurationData
            ?? manifest.configurationSchema.flatMap(DesktopWorkflowJSONSchemaValidator.defaultInstance)
            ?? Data("{}".utf8)
        let configurationIssues = manifest.configurationSchema.map {
            DesktopWorkflowJSONSchemaValidator.validationDiagnostics(instance: configData, against: $0)
        } ?? []
        if configurationData != nil, let issue = configurationIssues.first {
            throw DesktopWorkflowPackageError.invalidContract(path: "/configuration" + issue.path, message: issue.message)
        }
        try rejectSecretConfigurationKeys(configData)
        let configCanonical = try DesktopWorkflowRevisionDigest.canonicalJSON(configData)
        let configurationID = "\(installationID):configuration:\(configCanonical.digest.prefix(16))"
        let configuration = DesktopWorkflowConfigurationRevisionRecord(
            id: configurationID,
            installationID: installationID,
            schemaVersion: manifest.configurationSchemaVersion ?? 1,
            canonicalJSON: configCanonical.json,
            digest: configCanonical.digest,
            migratedFromRevisionID: nil,
            createdAtUnixMillis: timestamp
        )
        let normalizedResolutions = resolutions.sorted { $0.slotID < $1.slotID }
        let bindingCanonical = try DesktopWorkflowRevisionDigest.canonical(normalizedResolutions)
        let binding = DesktopWorkflowBindingRevisionRecord(
            id: "\(installationID):binding:\(bindingCanonical.digest.prefix(16))",
            installationID: installationID,
            resolutions: normalizedResolutions,
            digest: bindingCanonical.digest,
            createdAtUnixMillis: timestamp
        )
        let normalizedEntries = dependencyEntries.sorted { ($0.kind.rawValue, $0.componentID) < ($1.kind.rawValue, $1.componentID) }
        let dependencyCanonical = try DesktopWorkflowRevisionDigest.canonical(normalizedEntries)
        let dependencyLock = DesktopWorkflowDependencyLockRevisionRecord(
            id: "\(installationID):dependencies:\(dependencyCanonical.digest.prefix(16))",
            installationID: installationID,
            entries: normalizedEntries,
            digest: dependencyCanonical.digest,
            createdAtUnixMillis: timestamp
        )
        let captureCanonical = try DesktopWorkflowRevisionDigest.canonical(capturePolicy)
        let capture = DesktopWorkflowCapturePolicyRevisionRecord(
            id: "\(installationID):capture:\(captureCanonical.digest.prefix(16))",
            installationID: installationID,
            policy: capturePolicy,
            digest: captureCanonical.digest,
            createdAtUnixMillis: timestamp
        )
        let retentionCanonical = try DesktopWorkflowRevisionDigest.canonical(retentionPolicy)
        let retention = DesktopWorkflowRetentionPolicyRevisionRecord(
            id: "\(installationID):retention:\(retentionCanonical.digest.prefix(16))",
            installationID: installationID,
            policy: retentionPolicy,
            digest: retentionCanonical.digest,
            createdAtUnixMillis: timestamp
        )
        var issues = readinessIssues(
            manifest: manifest,
            resolutions: normalizedResolutions,
            dependencyEntries: normalizedEntries,
            workspaceSchema: KanameDesktopStateSchema.currentVersion
        )
        issues.append(contentsOf: configurationIssues.map {
            "Configure \($0.path.isEmpty ? "/" : $0.path): \($0.message)"
        })
        issues.sort()
        return Self(
            installation: DesktopWorkflowInstallationRecord(
                id: installationID,
                workflowID: manifest.id,
                name: name,
                workflowRevisionID: revisionID,
                currentConfigurationRevisionID: configuration.id,
                currentBindingRevisionID: binding.id,
                currentDependencyLockRevisionID: dependencyLock.id,
                currentCapturePolicyRevisionID: capture.id,
                currentRetentionPolicyRevisionID: retention.id,
                enabled: false,
                readinessIssues: issues,
                createdAtUnixMillis: timestamp,
                updatedAtUnixMillis: timestamp
            ),
            configuration: configuration,
            binding: binding,
            dependencyLock: dependencyLock,
            capturePolicy: capture,
            retentionPolicy: retention
        )
    }

    static func readinessIssues(
        manifest: DesktopWorkflowPackageManifest,
        resolutions: [DesktopWorkflowBindingResolution],
        dependencyEntries: [DesktopWorkflowDependencyLockEntry],
        workspaceSchema: Int
    ) -> [String] {
        var issues: [String] = []
        if let compatibility = manifest.hostCompatibility, !compatibility.supports(workspaceSchema: workspaceSchema) {
            issues.append("Host workspace schema \(workspaceSchema) is outside the package compatibility range.")
        }
        let resolutionBySlot = Dictionary(uniqueKeysWithValues: resolutions.map { ($0.slotID, $0) })
        for slot in (manifest.bindingSlots ?? []).filter(\.required) {
            guard let resolution = resolutionBySlot[slot.id], !resolution.resourceIDs.isEmpty else {
                issues.append("Resolve required \(slot.kind.label.lowercased()) slot “\(slot.label)”.")
                continue
            }
            if !slot.allowsMultiple, resolution.resourceIDs.count != 1 {
                issues.append("Slot “\(slot.label)” requires exactly one selection.")
            }
            if resolution.kind != slot.kind {
                issues.append("Slot “\(slot.label)” has the wrong resource kind.")
            }
        }
        let locked = Dictionary(uniqueKeysWithValues: dependencyEntries.map {
            ("\($0.kind.rawValue):\($0.componentID)", $0)
        })
        for dependency in (manifest.dependencies ?? []).filter(\.required) {
            guard let entry = locked["\(dependency.kind.rawValue):\(dependency.id)"] else {
                issues.append("Resolve required \(dependency.kind.rawValue) dependency \(dependency.id) \(dependency.versionRequirement).")
                continue
            }
            if !DesktopWorkflowVersionConstraint.satisfies(version: entry.version, requirement: dependency.versionRequirement) {
                issues.append("Dependency \(dependency.id) \(entry.version) does not satisfy \(dependency.versionRequirement).")
            }
        }
        return issues.sorted()
    }

    private static func rejectSecretConfigurationKeys(_ data: Data) throws {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw DesktopWorkflowPackageError.invalidContract(path: "/configuration", message: "Configuration is not valid JSON.")
        }
        let forbidden = Set([
            "secret", "password", "token", "apikey", "api_key", "apitoken", "api_token",
            "accesstoken", "access_token", "credential", "clientsecret", "client_secret",
        ])
        func inspect(_ value: Any, path: String) throws {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                    if forbidden.contains(normalized) {
                        throw DesktopWorkflowPackageError.invalidContract(
                            path: path + "/" + key,
                            message: "Secrets belong in a secret-reference binding slot, never configuration JSON."
                        )
                    }
                    try inspect(child, path: path + "/" + key)
                }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() { try inspect(child, path: path + "/\(index)") }
            }
        }
        try inspect(value, path: "/configuration")
    }
}

public extension DesktopAppModel {
    var workflowInstallations: [DesktopWorkflowInstallationRecord] {
        snapshot.operations.workflows.installations.sorted {
            if $0.enabled != $1.enabled { return $0.enabled && !$1.enabled }
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    func workflowInstallations(workflowID: String) -> [DesktopWorkflowInstallationRecord] {
        snapshot.operations.workflows.installations.filter { $0.workflowID == workflowID }
            .sorted { ($0.createdAtUnixMillis, $0.id) < ($1.createdAtUnixMillis, $1.id) }
    }

    @discardableResult
    func createWorkflowInstallation(
        workflowID: String,
        name: String,
        configuration: Data? = nil,
        bindings: [DesktopWorkflowBindingResolution] = [],
        dependencyLock: [DesktopWorkflowDependencyLockEntry] = []
    ) throws -> String {
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == definition.currentRevisionID }),
              let manifest = try? workflowManifest(definition: definition, revision: revision) else {
            throw DesktopWorkflowOperationalError.workflowUnavailable
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf8.count <= 240 else {
            throw DesktopWorkflowOperationalError.invalidConfiguration("Installation name is required and must be at most 240 bytes.")
        }
        try validateBindingResolutions(bindings, manifest: manifest)
        let timestamp = now()
        let installationID = UUID().uuidString.lowercased()
        let seed = try DesktopWorkflowInstallationSeed.make(
            manifest: manifest,
            revisionID: revision.id,
            installationID: installationID,
            name: cleanName,
            configurationData: configuration,
            resolutions: bindings,
            dependencyEntries: dependencyLock,
            timestamp: timestamp
        )
        guard persistInstallationSeed(seed, action: "created") else {
            throw DesktopWorkflowOperationalError.invalidConfiguration("Installation revisions could not be persisted.")
        }
        return installationID
    }

    @discardableResult
    func reviseWorkflowInstallation(
        id: String,
        configuration: Data,
        bindings: [DesktopWorkflowBindingResolution],
        dependencyLock: [DesktopWorkflowDependencyLockEntry],
        capturePolicy: DesktopWorkflowCapturePolicy,
        retentionPolicy: DesktopWorkflowRetentionPolicy
    ) throws -> Bool {
        guard let existing = snapshot.operations.workflows.installations.first(where: { $0.id == id }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == existing.workflowRevisionID }),
              let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == existing.workflowID }),
              let manifest = try? workflowManifest(definition: definition, revision: revision) else {
            throw DesktopWorkflowOperationalError.workflowUnavailable
        }
        try validateBindingResolutions(bindings, manifest: manifest)
        let timestamp = now()
        let seed = try DesktopWorkflowInstallationSeed.make(
            manifest: manifest,
            revisionID: revision.id,
            installationID: id,
            name: existing.name,
            configurationData: configuration,
            resolutions: bindings,
            dependencyEntries: dependencyLock,
            capturePolicy: capturePolicy,
            retentionPolicy: retentionPolicy,
            timestamp: timestamp
        )
        return mutate { state in
            state.operations.workflows.configurationRevisions.append(seed.configuration)
            state.operations.workflows.bindingRevisions.append(seed.binding)
            state.operations.workflows.dependencyLockRevisions.append(seed.dependencyLock)
            state.operations.workflows.capturePolicyRevisions.append(seed.capturePolicy)
            state.operations.workflows.retentionPolicyRevisions.append(seed.retentionPolicy)
            guard let index = state.operations.workflows.installations.firstIndex(where: { $0.id == id }) else { return }
            state.operations.workflows.installations[index].currentConfigurationRevisionID = seed.configuration.id
            state.operations.workflows.installations[index].currentBindingRevisionID = seed.binding.id
            state.operations.workflows.installations[index].currentDependencyLockRevisionID = seed.dependencyLock.id
            state.operations.workflows.installations[index].currentCapturePolicyRevisionID = seed.capturePolicy.id
            state.operations.workflows.installations[index].currentRetentionPolicyRevisionID = seed.retentionPolicy.id
            state.operations.workflows.installations[index].readinessIssues = seed.installation.readinessIssues
            state.operations.workflows.installations[index].enabled = false
            state.operations.workflows.installations[index].updatedAtUnixMillis = timestamp
            state.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(), domain: "workflow-installation", action: "revised",
                target: id, state: .proposed,
                detail: "Created immutable configuration, binding, dependency, capture, and retention revisions. Enablement and authority were not carried forward.",
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    func setWorkflowInstallationEnabled(id: String, enabled: Bool) -> Bool {
        guard let installation = snapshot.operations.workflows.installations.first(where: { $0.id == id }),
              !enabled || installation.readinessIssues.isEmpty else { return false }
        let timestamp = now()
        return mutate { state in
            guard let index = state.operations.workflows.installations.firstIndex(where: { $0.id == id }) else { return }
            state.operations.workflows.installations[index].enabled = enabled
            state.operations.workflows.installations[index].updatedAtUnixMillis = timestamp
            state.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(), domain: "workflow-installation",
                action: enabled ? "enabled" : "disabled", target: id,
                state: enabled ? .approved : .cancelled,
                detail: enabled ? "Enabled one exact ready installation revision set." : "Disabled future dispatch for this installation.",
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    func previewWorkflowUpgrade(installationID: String, toRevisionID: String) -> DesktopWorkflowUpgradeDiff? {
        guard let installation = snapshot.operations.workflows.installations.first(where: { $0.id == installationID }),
              let from = snapshot.operations.workflows.revisions.first(where: { $0.id == installation.workflowRevisionID }),
              let to = snapshot.operations.workflows.revisions.first(where: { $0.id == toRevisionID && $0.workflowID == installation.workflowID }) else { return nil }
        let oldSlots = Set((from.bindingSlots ?? []).map(\.id))
        let newSlots = Set((to.bindingSlots ?? []).map(\.id))
        let oldDependencies = Set((from.dependencies ?? []).map { "\($0.kind.rawValue):\($0.id)" })
        let newDependencies = Set((to.dependencies ?? []).map { "\($0.kind.rawValue):\($0.id)" })
        return DesktopWorkflowUpgradeDiff(
            fromRevisionID: from.id,
            toRevisionID: to.id,
            configurationSchemaChanged: from.configurationSchema != to.configurationSchema
                || from.configurationSchemaVersion != to.configurationSchemaVersion,
            addedBindingSlotIDs: Array(newSlots.subtracting(oldSlots)).sorted(),
            removedBindingSlotIDs: Array(oldSlots.subtracting(newSlots)).sorted(),
            addedDependencyIDs: Array(newDependencies.subtracting(oldDependencies)).sorted(),
            removedDependencyIDs: Array(oldDependencies.subtracting(newDependencies)).sorted(),
            permissionBroadening: to.permissions.broadens(from.permissions),
            authorityCarriedForward: false
        )
    }

    @discardableResult
    func upgradeWorkflowInstallation(installationID: String, toRevisionID: String) throws -> Bool {
        guard let installation = snapshot.operations.workflows.installations.first(where: { $0.id == installationID }),
              let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == installation.workflowID }),
              let fromRevision = snapshot.operations.workflows.revisions.first(where: { $0.id == installation.workflowRevisionID }),
              let toRevision = snapshot.operations.workflows.revisions.first(where: {
                  $0.id == toRevisionID && $0.workflowID == installation.workflowID
              }),
              let targetManifest = try? workflowManifest(definition: definition, revision: toRevision),
              let currentConfiguration = currentWorkflowConfiguration(installationID: installationID),
              let currentBindings = currentWorkflowBindings(installationID: installationID),
              let currentDependencyLock = snapshot.operations.workflows.dependencyLockRevisions.first(where: {
                  $0.id == installation.currentDependencyLockRevisionID
              }),
              let capturePolicy = snapshot.operations.workflows.capturePolicyRevisions.first(where: {
                  $0.id == installation.currentCapturePolicyRevisionID
              })?.policy,
              let retentionPolicy = snapshot.operations.workflows.retentionPolicyRevisions.first(where: {
                  $0.id == installation.currentRetentionPolicyRevisionID
              })?.policy else {
            throw DesktopWorkflowOperationalError.workflowUnavailable
        }
        let currentData = Data(currentConfiguration.canonicalJSON.utf8)
        let targetVersion = targetManifest.configurationSchemaVersion ?? currentConfiguration.schemaVersion
        let migrated = try DesktopWorkflowConfigurationMigrator.migrate(
            currentData,
            fromVersion: currentConfiguration.schemaVersion,
            toVersion: targetVersion,
            migrations: targetManifest.configurationMigrations ?? []
        )
        let targetSlots = Set((targetManifest.bindingSlots ?? []).map(\.id))
        let bindings = currentBindings.resolutions.filter { targetSlots.contains($0.slotID) }
        let targetDependencies = Set((targetManifest.dependencies ?? []).map { "\($0.kind.rawValue):\($0.id)" })
        let lock = currentDependencyLock.entries.filter {
            targetDependencies.contains("\($0.kind.rawValue):\($0.componentID)")
        }
        let timestamp = now()
        var seed = try DesktopWorkflowInstallationSeed.make(
            manifest: targetManifest,
            revisionID: toRevision.id,
            installationID: installationID,
            name: installation.name,
            configurationData: migrated,
            resolutions: bindings,
            dependencyEntries: lock,
            capturePolicy: capturePolicy,
            retentionPolicy: retentionPolicy,
            timestamp: timestamp
        )
        seed.configuration.migratedFromRevisionID = currentConfiguration.id
        seed.installation.createdAtUnixMillis = installation.createdAtUnixMillis
        return mutate { state in
            state.operations.workflows.configurationRevisions.append(seed.configuration)
            state.operations.workflows.bindingRevisions.append(seed.binding)
            state.operations.workflows.dependencyLockRevisions.append(seed.dependencyLock)
            state.operations.workflows.capturePolicyRevisions.append(seed.capturePolicy)
            state.operations.workflows.retentionPolicyRevisions.append(seed.retentionPolicy)
            guard let index = state.operations.workflows.installations.firstIndex(where: { $0.id == installationID }) else { return }
            state.operations.workflows.installations[index] = seed.installation
            for grantIndex in state.operations.workflows.authorityGrants.indices
                where state.operations.workflows.authorityGrants[grantIndex].workflowID == installation.workflowID {
                state.operations.workflows.authorityGrants[grantIndex].state = .revoked
            }
            for bindingIndex in state.operations.workflows.triggerBindings.indices
                where state.operations.workflows.triggerBindings[bindingIndex].workflowID == installation.workflowID {
                state.operations.workflows.triggerBindings[bindingIndex].enabled = false
                state.operations.workflows.triggerBindings[bindingIndex].lastCursor = nil
                state.operations.workflows.triggerBindings[bindingIndex].updatedAtUnixMillis = timestamp
            }
            state.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(), domain: "workflow-installation", action: "upgraded",
                target: installationID, state: .proposed,
                detail: "Migrated configuration from \(fromRevision.version) to \(toRevision.version); installation, triggers, and standing authority remain disabled pending review.",
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    func currentWorkflowConfiguration(installationID: String) -> DesktopWorkflowConfigurationRevisionRecord? {
        guard let installation = snapshot.operations.workflows.installations.first(where: { $0.id == installationID }) else { return nil }
        return snapshot.operations.workflows.configurationRevisions.first { $0.id == installation.currentConfigurationRevisionID }
    }

    func currentWorkflowBindings(installationID: String) -> DesktopWorkflowBindingRevisionRecord? {
        guard let installation = snapshot.operations.workflows.installations.first(where: { $0.id == installationID }) else { return nil }
        return snapshot.operations.workflows.bindingRevisions.first { $0.id == installation.currentBindingRevisionID }
    }

    private func workflowManifest(
        definition: DesktopWorkflowDefinitionRecord,
        revision: DesktopWorkflowRevisionRecord
    ) throws -> DesktopWorkflowPackageManifest {
        DesktopWorkflowPackageManifest(
            schemaVersion: revision.schemaVersion,
            id: definition.id,
            name: definition.name,
            summary: definition.summary,
            icon: definition.icon,
            version: revision.version,
            source: definition.source,
            license: definition.license,
            triggers: definition.triggerKinds,
            steps: revision.steps,
            permissions: revision.permissions,
            correlationSummary: revision.correlationSummary,
            contextSummary: revision.contextSummary,
            completionSummary: revision.completionSummary,
            datasets: revision.datasetDefinitions,
            configurationSchema: revision.configurationSchema,
            configurationSchemaVersion: revision.configurationSchemaVersion,
            manualRunInputSchema: revision.manualRunInputSchema,
            bindingSlots: revision.bindingSlots,
            providerFeatures: revision.providerFeatures,
            hostCompatibility: revision.hostCompatibility,
            dependencies: revision.dependencies,
            publisher: revision.publisher,
            provenance: revision.provenance,
            uiHints: revision.uiHints,
            configurationMigrations: revision.configurationMigrations
        )
    }

    private func validateBindingResolutions(
        _ resolutions: [DesktopWorkflowBindingResolution],
        manifest: DesktopWorkflowPackageManifest
    ) throws {
        guard Set(resolutions.map(\.slotID)).count == resolutions.count else {
            throw DesktopWorkflowOperationalError.invalidConfiguration("A binding slot was resolved more than once.")
        }
        let slots = Dictionary(uniqueKeysWithValues: (manifest.bindingSlots ?? []).map { ($0.id, $0) })
        for resolution in resolutions {
            guard let slot = slots[resolution.slotID], slot.kind == resolution.kind,
                  resolution.resourceIDs.count == resolution.displayLabels.count,
                  resolution.resourceIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }),
                  slot.allowsMultiple || resolution.resourceIDs.count <= 1 else {
                throw DesktopWorkflowOperationalError.invalidConfiguration("Binding slot \(resolution.slotID) has an invalid resource selection.")
            }
        }
    }

    private func persistInstallationSeed(_ seed: DesktopWorkflowInstallationSeed, action: String) -> Bool {
        mutate { state in
            state.operations.workflows.installations.append(seed.installation)
            state.operations.workflows.configurationRevisions.append(seed.configuration)
            state.operations.workflows.bindingRevisions.append(seed.binding)
            state.operations.workflows.dependencyLockRevisions.append(seed.dependencyLock)
            state.operations.workflows.capturePolicyRevisions.append(seed.capturePolicy)
            state.operations.workflows.retentionPolicyRevisions.append(seed.retentionPolicy)
            state.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(), domain: "workflow-installation", action: action,
                target: seed.installation.id, state: .proposed,
                detail: seed.installation.readinessIssues.isEmpty
                    ? "Installed disabled and ready for explicit enablement."
                    : "Installed disabled with \(seed.installation.readinessIssues.count) unresolved readiness item(s).",
                recordedAtUnixMillis: seed.installation.createdAtUnixMillis
            ))
        }
    }
}

enum DesktopWorkflowConfigurationMigrator {
    static func migrate(
        _ data: Data,
        fromVersion: Int,
        toVersion: Int,
        migrations: [DesktopWorkflowConfigurationMigration]
    ) throws -> Data {
        guard toVersion >= fromVersion,
              var value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw DesktopWorkflowOperationalError.invalidConfiguration("Configuration migration input is invalid.")
        }
        if fromVersion == toVersion { return data }
        let byVersion = Dictionary(uniqueKeysWithValues: migrations.map { ($0.fromVersion, $0) })
        var version = fromVersion
        while version < toVersion {
            guard let migration = byVersion[version], migration.toVersion == version + 1 else {
                throw DesktopWorkflowOperationalError.invalidConfiguration("No migration exists from configuration schema \(version) to \(version + 1).")
            }
            for operation in migration.operations {
                let source = try segments(operation.pointer)
                switch operation.kind {
                case .remove:
                    _ = remove(path: source, from: &value)
                case .rename:
                    guard let destination = operation.destinationPointer,
                          let moved = remove(path: source, from: &value),
                          set(path: try segments(destination), value: moved, in: &value, onlyIfMissing: false) else {
                        throw DesktopWorkflowOperationalError.invalidConfiguration("Rename migration could not resolve \(operation.pointer).")
                    }
                case .setDefault:
                    guard let fragment = operation.value,
                          let defaultValue = try? JSONSerialization.jsonObject(with: Data(fragment.utf8), options: [.fragmentsAllowed]),
                          set(path: source, value: defaultValue, in: &value, onlyIfMissing: true) else {
                        throw DesktopWorkflowOperationalError.invalidConfiguration("Default migration could not set \(operation.pointer).")
                    }
                }
            }
            version += 1
        }
        guard JSONSerialization.isValidJSONObject(value) else {
            throw DesktopWorkflowOperationalError.invalidConfiguration("Migrated configuration is not a JSON container.")
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func segments(_ pointer: String) throws -> [String] {
        guard pointer.hasPrefix("/"), pointer != "/" else {
            throw DesktopWorkflowOperationalError.invalidConfiguration("Migration path must be a non-root JSON Pointer.")
        }
        return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    private static func remove(path: [String], from value: inout Any) -> Any? {
        guard let head = path.first else { return nil }
        if var object = value as? [String: Any] {
            if path.count == 1 {
                let removed = object.removeValue(forKey: head)
                value = object
                return removed
            }
            guard var child = object[head], let removed = remove(path: Array(path.dropFirst()), from: &child) else { return nil }
            object[head] = child
            value = object
            return removed
        }
        if var array = value as? [Any], let index = Int(head), array.indices.contains(index) {
            if path.count == 1 {
                let removed = array.remove(at: index)
                value = array
                return removed
            }
            var child = array[index]
            guard let removed = remove(path: Array(path.dropFirst()), from: &child) else { return nil }
            array[index] = child
            value = array
            return removed
        }
        return nil
    }

    private static func set(path: [String], value newValue: Any, in value: inout Any, onlyIfMissing: Bool) -> Bool {
        guard let head = path.first else { return false }
        if var object = value as? [String: Any] {
            if path.count == 1 {
                if onlyIfMissing, object[head] != nil { return true }
                object[head] = newValue
                value = object
                return true
            }
            guard var child = object[head], set(path: Array(path.dropFirst()), value: newValue, in: &child, onlyIfMissing: onlyIfMissing) else { return false }
            object[head] = child
            value = object
            return true
        }
        if var array = value as? [Any], let index = Int(head), array.indices.contains(index) {
            if path.count == 1 {
                if !onlyIfMissing { array[index] = newValue }
                value = array
                return true
            }
            var child = array[index]
            guard set(path: Array(path.dropFirst()), value: newValue, in: &child, onlyIfMissing: onlyIfMissing) else { return false }
            array[index] = child
            value = array
            return true
        }
        return false
    }
}
