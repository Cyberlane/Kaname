import CryptoKit
import Foundation

public struct DesktopWorkflowLegacyImportSource: Codable, Equatable, Sendable {
    public var definition: DesktopWorkflowDefinitionRecord
    public var revision: DesktopWorkflowRevisionRecord

    public init(definition: DesktopWorkflowDefinitionRecord, revision: DesktopWorkflowRevisionRecord) {
        self.definition = definition
        self.revision = revision
    }
}

public enum DesktopWorkflowLegacyImportLossSeverity: String, Codable, Equatable, Sendable {
    case blocking
    case warning
}

public struct DesktopWorkflowLegacyImportLoss: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(code):\(pointer)" }
    public var severity: DesktopWorkflowLegacyImportLossSeverity
    public var code: String
    public var pointer: String
    public var summary: String
}

public struct DesktopWorkflowV1EndpointDocument: Codable, Equatable, Sendable {
    public var nodeId: String
    public var portId: String
}

public struct DesktopWorkflowV1EdgeDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var from: DesktopWorkflowV1EndpointDocument
    public var to: DesktopWorkflowV1EndpointDocument
    public var mappingId: String
    public var mapping: DesktopWorkflowJSONValue
}

public struct DesktopWorkflowV1NodeDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var key: String
    public var name: String
    public var type: String
    public var typeVersion: Int
    public var config: DesktopWorkflowJSONValue
    public var policyRefs: [String: String]?
    public var annotations: [String: DesktopWorkflowJSONValue]?
}

public struct DesktopWorkflowV1EntrypointDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var nodeId: String
    public var key: String?
}

public struct DesktopWorkflowV1GraphDocument: Codable, Equatable, Sendable {
    public var entrypoints: [DesktopWorkflowV1EntrypointDocument]
    public var nodes: [DesktopWorkflowV1NodeDocument]
    public var edges: [DesktopWorkflowV1EdgeDocument]
}

public struct DesktopWorkflowV1Document: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var workflowId: String
    public var packageId: String
    public var name: String
    public var summary: String
    public var graph: DesktopWorkflowV1GraphDocument
    public var interfaces: [String: [DesktopWorkflowJSONValue]]
    public var resources: [String: String]
    public var policies: [String: DesktopWorkflowJSONValue]
    public var storage: [String: DesktopWorkflowJSONValue]
    public var metadata: [String: DesktopWorkflowJSONValue]
}

public struct DesktopWorkflowV1LayoutNodeDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: String { nodeId }
    public var nodeId: String
    public var x: Double
    public var y: Double
}

public struct DesktopWorkflowV1LayoutDocument: Codable, Equatable, Sendable {
    public var nodes: [DesktopWorkflowV1LayoutNodeDocument]
}

public struct DesktopWorkflowLegacyImportResult: Equatable, Identifiable, Sendable {
    public var id: String { sourceDigest }
    public var sourceDigest: String
    public var workflow: DesktopWorkflowV1Document
    public var layout: DesktopWorkflowV1LayoutDocument
    public var canonicalSource: String
    public var canonicalLayoutSource: String
    public var losses: [DesktopWorkflowLegacyImportLoss]
    /// Stable v1 node identity for each legacy Builder step, so compiler
    /// decisions about the graph can be shown on the steps that produced it.
    public var nodeIDByLegacyStepID: [String: String] = [:]

    public var isLossless: Bool {
        !losses.contains { $0.severity == .blocking }
    }
}

public enum DesktopWorkflowLegacyImportError: Error, Equatable, LocalizedError {
    case sourceEncodingFailed
    case outputEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .sourceEncodingFailed: "The legacy workflow snapshot could not be encoded deterministically."
        case .outputEncodingFailed: "The read-only v2 draft could not be encoded deterministically."
        }
    }
}

public enum DesktopWorkflowLegacyImporter {
    private static let dataSchemaRef = DesktopWorkflowNodeRegistry.dataSchemaRef
    private static let fallbackPackageID = "dev.kaname.legacy"
    private static let identityMapping: DesktopWorkflowJSONValue = .object(["whole": .boolean(true)])

    public static func importSource(
        _ source: DesktopWorkflowLegacyImportSource
    ) throws -> DesktopWorkflowLegacyImportResult {
        guard let sourceData = try? DesktopWorkflowCanonicalJSON.encode(source) else {
            throw DesktopWorkflowLegacyImportError.sourceEncodingFailed
        }
        let sourceDigest = digest(sourceData)
        let definition = source.definition
        let revision = source.revision
        let identitySeed = definition.id
        let workflowID = stableUUID(seed: "workflow|\(identitySeed)")
        var losses: [DesktopWorkflowLegacyImportLoss] = []
        let packageID = portablePackageID(definition.id, workflowID: workflowID, losses: &losses)
        let name = bounded(
            definition.name,
            maximum: 160,
            pointer: "/name",
            code: "legacy.text.name-truncated",
            losses: &losses
        )
        let summary = bounded(
            definition.summary,
            maximum: 1_000,
            pointer: "/summary",
            code: "legacy.text.summary-truncated",
            losses: &losses
        )

        if !revision.permissions.permissions.isEmpty
            || !revision.permissions.accountIDs.isEmpty
            || !revision.permissions.filesystemScopes.isEmpty
            || !revision.permissions.capabilityIDs.isEmpty
            || !revision.permissions.networkDestinations.isEmpty
            || !revision.permissions.dataClassesLeavingDevice.isEmpty {
            appendLoss(
                "legacy.authority.requires-rebinding",
                "/policies",
                "Legacy permissions and bindings are not portable authority. Review and rebind them before publication.",
                to: &losses
            )
        }

        let declaredTriggerKinds = definition.triggerKinds.isEmpty ? [.manual] : definition.triggerKinds
        let triggerKinds = declaredTriggerKinds.reduce(into: [DesktopWorkflowTriggerKind]()) { result, trigger in
            if !result.contains(trigger) { result.append(trigger) }
        }
        if definition.triggerKinds.isEmpty {
            appendLoss(
                "legacy.trigger.missing",
                "/graph/entrypoints",
                "The legacy definition has no trigger; the preview inserts a manual trigger.",
                to: &losses
            )
        }
        if triggerKinds.count != declaredTriggerKinds.count {
            appendLoss(
                "legacy.trigger.identity-duplicate",
                "/graph/entrypoints",
                "Duplicate legacy triggers collapse to one stable v2 entrypoint per trigger kind.",
                to: &losses
            )
        }

        var nodes: [DesktopWorkflowV1NodeDocument] = []
        var entrypoints: [DesktopWorkflowV1EntrypointDocument] = []
        var edges: [DesktopWorkflowV1EdgeDocument] = []
        var policies: [String: DesktopWorkflowJSONValue] = [:]
        let legacyStepIDs = revision.steps.map(\.id)
        let duplicateStepIDs = Set(Dictionary(grouping: legacyStepIDs, by: { $0 })
            .filter { $0.value.count > 1 }.map(\.key))
        if !duplicateStepIDs.isEmpty {
            appendLoss(
                "legacy.step.identity-duplicate",
                "/graph/nodes",
                "Duplicate legacy step identities cannot be assigned distinct stable v2 identities.",
                to: &losses
            )
        }
        let nodeIDs = revision.steps.enumerated().map { index, step in
            stableUUID(seed: duplicateStepIDs.contains(step.id)
                ? "node|\(identitySeed)|\(step.id)|duplicate|\(index)"
                : "node|\(identitySeed)|\(step.id)")
        }
        let nodeIDByLegacyID = Dictionary(
            zip(legacyStepIDs, nodeIDs),
            uniquingKeysWith: { first, _ in first }
        )

        for (index, trigger) in triggerKinds.enumerated() {
            let triggerID = stableUUID(seed: "trigger|\(identitySeed)|\(trigger.rawValue)")
            let triggerKey = stableKey("legacy-\(trigger.rawValue)-trigger", seed: triggerID)
            let converted = triggerNode(trigger, id: triggerID, key: triggerKey)
            nodes.append(converted)
            entrypoints.append(.init(
                id: stableUUID(seed: "entrypoint|\(identitySeed)|\(trigger.rawValue)"),
                nodeId: triggerID,
                key: triggerKey
            ))
            if let first = revision.steps.first, let targetID = nodeIDByLegacyID[first.id] {
                edges.append(edge(
                    seed: "trigger-edge|\(identitySeed)|\(trigger.rawValue)",
                    fromNodeID: triggerID,
                    fromPortID: "success",
                    toNodeID: targetID,
                    toPortID: "input"
                ))
            } else if index == 0 {
                appendLoss(
                    "legacy.graph.empty",
                    "/graph/nodes",
                    "The legacy revision contains no steps.",
                    to: &losses
                )
            }
        }

        for (index, step) in revision.steps.enumerated() {
            let nodeID = nodeIDs[index]
            let conversion = convert(
                step: step,
                index: index,
                nodeID: nodeID,
                identitySeed: identitySeed,
                losses: &losses
            )
            nodes.append(conversion.node)
            if conversion.needsAuthorityPolicy {
                policies["legacy-authority"] = authorityPolicy()
            }
        }

        for (stepIndex, step) in revision.steps.enumerated() {
            let sourceNodeID = nodeIDs[stepIndex]
            for (transitionIndex, transition) in (step.transitions ?? []).enumerated() {
                guard let targetNodeID = nodeIDByLegacyID[transition.targetStepID] else {
                    appendLoss(
                        "legacy.transition.target-missing",
                        "/graph/nodes/\(stepIndex)/transitions/\(transitionIndex)/targetStepID",
                        "The transition target does not exist in the legacy snapshot.",
                        to: &losses
                    )
                    continue
                }
                guard step.kind != .complete else {
                    appendLoss(
                        "legacy.terminal.has-transition",
                        "/graph/nodes/\(stepIndex)/transitions/\(transitionIndex)",
                        "A terminal legacy step cannot preserve an outgoing transition.",
                        to: &losses
                    )
                    continue
                }
                let sourcePort = transitionPort(
                    step: step,
                    transition: transition,
                    transitionIndex: transitionIndex,
                    identitySeed: identitySeed
                )
                edges.append(edge(
                    seed: "edge|\(identitySeed)|\(step.id)|\(transition.id)|\(transitionIndex)",
                    fromNodeID: sourceNodeID,
                    fromPortID: sourcePort,
                    toNodeID: targetNodeID,
                    toPortID: "input"
                ))
            }
            appendTransitionLosses(step: step, index: stepIndex, losses: &losses)
        }

        let layout = layoutDocument(
            identitySeed: identitySeed,
            triggerKinds: triggerKinds,
            steps: revision.steps,
            nodeIDs: nodeIDs
        )
        let workflow = DesktopWorkflowV1Document(
            formatVersion: 1,
            workflowId: workflowID,
            packageId: packageID,
            name: name.isEmpty ? "Imported workflow" : name,
            summary: summary,
            graph: .init(entrypoints: entrypoints, nodes: nodes, edges: edges),
            interfaces: [:],
            resources: [:],
            policies: policies,
            storage: [:],
            metadata: [
                "readOnly": .boolean(true),
                "legacyImport": .boolean(true),
                "legacyRevisionId": .string(revision.id),
                "legacySourceDigest": .string(sourceDigest),
            ]
        )
        guard let workflowData = try? DesktopWorkflowCanonicalJSON.encode(workflow),
              let layoutData = try? DesktopWorkflowCanonicalJSON.encode(layout),
              let canonicalSource = String(data: workflowData, encoding: .utf8),
              let canonicalLayoutSource = String(data: layoutData, encoding: .utf8) else {
            throw DesktopWorkflowLegacyImportError.outputEncodingFailed
        }
        return DesktopWorkflowLegacyImportResult(
            sourceDigest: sourceDigest,
            workflow: workflow,
            layout: layout,
            canonicalSource: canonicalSource,
            canonicalLayoutSource: canonicalLayoutSource,
            losses: losses.sorted { ($0.pointer, $0.code) < ($1.pointer, $1.code) },
            nodeIDByLegacyStepID: nodeIDByLegacyID
        )
    }

    private struct NodeConversion {
        var node: DesktopWorkflowV1NodeDocument
        var needsAuthorityPolicy: Bool
    }

    private static func convert(
        step: DesktopWorkflowStepDefinition,
        index: Int,
        nodeID: String,
        identitySeed: String,
        losses: inout [DesktopWorkflowLegacyImportLoss]
    ) -> NodeConversion {
        let pointer = "/graph/nodes/\(index)"
        let key = stableKey(step.id, seed: nodeID)
        let name = bounded(
            step.name,
            maximum: 160,
            pointer: pointer + "/name",
            code: "legacy.text.step-name-truncated",
            losses: &losses
        )
        let type: String
        let config: DesktopWorkflowJSONValue
        var needsAuthority = false

        switch step.kind {
        case .complete:
            type = "terminal.complete"
            config = .object([:])
            if hasNonTerminalConfiguration(step) {
                appendLoss(
                    "legacy.complete.configuration-dropped",
                    pointer + "/config",
                    "Configuration attached to the legacy Complete step has no terminal equivalent.",
                    to: &losses
                )
            }
        case .branch:
            type = "control.decision"
            let decisionTransition = (step.transitions ?? []).first {
                $0.outcome == .matched
            } ?? step.transitions?.first
            config = .object([
                "when": condition(decisionTransition?.predicates ?? []),
            ])
            appendLoss(
                "legacy.decision.routing-contract",
                pointer + "/config",
                "The legacy Decision predicates require strict typed review before v2 publication.",
                to: &losses
            )
        case .match:
            type = "control.match"
            config = matchConfiguration(
                step: step,
                nodeID: nodeID,
                identitySeed: identitySeed,
                pointer: pointer,
                losses: &losses
            )
            appendLoss(
                "legacy.match.routing-contract",
                pointer + "/config",
                "The legacy Match routes require strict typed source and hit-policy review before v2 publication.",
                to: &losses
            )
        case .forEach:
            type = "control.for-each"
            let policy = step.batchPolicy ?? .init()
            config = .object([
                "items": reference(root: "input", pointer: policy.itemsPointer),
                "as": .string("item"),
                "maximumConcurrency": .number(Double(policy.maximumConcurrency)),
                "failurePolicy": .string(
                    policy.aggregation == .stopOnFirstFailure ? "fail-fast" : "collect"
                ),
            ])
            appendLoss(
                "legacy.foreach.body-unbound",
                pointer + "/config",
                "The legacy batch policy has no explicit v2 subgraph body or join contract.",
                to: &losses
            )
        case .waitForEmail:
            type = "control.wait"
            let contract = step.waitContract
            let correlation = contract?.correlationPointer
                ?? contract?.conversationPointer
                ?? contract?.accountPointer
                ?? ""
            config = .object([
                "kind": .string("reply"),
                "correlation": .array([reference(root: "input", pointer: correlation)]),
                "expirySeconds": .number(Double(contract?.timeoutSeconds ?? 604_800)),
            ])
            appendLoss(
                "legacy.wait.connector-contract",
                pointer + "/config",
                "The legacy connector, source, supersession, and account-scoping rules require a reviewed v2 wait contract.",
                to: &losses
            )
        case .humanReview, .requestApproval:
            type = "control.human-review"
            config = .object([
                "proposal": identityMapping,
                "authorityPolicy": .string("legacy-authority"),
                "expirySeconds": .number(604_800),
                "staleCheck": .string("digest"),
            ])
            needsAuthority = true
            appendLoss(
                "legacy.review.contract-incomplete",
                pointer + "/config",
                "Legacy review actions and inline schemas need explicit v2 proposal and result contracts.",
                to: &losses
            )
        case .effect, .createEmailDraft, .sendEmail:
            type = "effect.connector"
            let connector = portableCapabilityID(step.capabilityID)
            config = .object([
                "connectorClass": .string(connector),
                "action": .string(step.kind.rawValue),
                "input": identityMapping,
                "previewContract": .string("legacy-preview-required"),
                "reconciliationContract": .string("legacy-reconciliation-required"),
                "idempotency": .string(step.isIdempotent ? "required" : "reconcile-only"),
            ])
            needsAuthority = true
            appendLoss(
                "legacy.effect.dependency-unpinned",
                pointer + "/config/connectorClass",
                "The legacy effect has no immutable connector digest, preview contract, or reconciliation contract.",
                to: &losses
            )
        case .invokeTool:
            type = "compute.capability"
            let capability = portableCapabilityID(step.capabilityID)
            config = .object([
                "capabilityId": .string(capability),
                "version": .string("0.0.0"),
                "input": identityMapping,
                "outputSchemaRef": .string(step.outputSchemaReference ?? dataSchemaRef),
            ])
            appendLoss(
                "legacy.capability.dependency-unpinned",
                pointer + "/config/version",
                "The legacy capability reference has no immutable package version and digest.",
                to: &losses
            )
        case .agent, .structuredModel:
            type = "compute.llm"
            config = .object([
                "modelClass": .string("balanced"),
                "prompt": identityMapping,
                "context": .array([reference(root: "input", pointer: "")]),
                "tools": .array((step.agentPolicy?.allowedCapabilityIDs ?? []).filter(validPackageID).map {
                    .string($0)
                }),
                "outputSchemaRef": .string(step.outputSchemaReference ?? dataSchemaRef),
                "conversationScope": .string("job"),
            ])
            appendLoss(
                "legacy.llm.prompt-unavailable",
                pointer + "/config/prompt",
                "The legacy model step does not persist a typed prompt, context map, or model class.",
                to: &losses
            )
        case .validate:
            if let schema = step.outputSchemaReference ?? step.inputSchemaReference, !schema.isEmpty {
                type = "data.validate"
                config = .object(["schemaRef": .string(schema)])
            } else {
                type = "data.map"
                config = .object(["mapping": identityMapping])
                appendLoss(
                    "legacy.validate.schema-missing",
                    pointer + "/config/schemaRef",
                    "The legacy validation step has no portable schema reference.",
                    to: &losses
                )
            }
        case .registerArtifact:
            type = "data.register-artifact"
            config = .object([
                "role": .string(step.artifactInputs?.first?.role ?? "legacy-artifact"),
                "mediaTypes": .array([.string("application/octet-stream")]),
            ])
            appendLoss(
                "legacy.artifact.output-contract",
                pointer + "/config",
                "The legacy artifact step does not declare exact output media types and role semantics.",
                to: &losses
            )
        case .classifyEvent, .correlateWork, .compileContext:
            type = "data.map"
            config = .object(["mapping": identityMapping])
            appendLoss(
                "legacy.step.behavior-opaque",
                pointer + "/config",
                "The legacy \(step.kind.label) behavior has no declarative v2 mapping contract.",
                to: &losses
            )
        }

        appendCommonStepLosses(step: step, pointer: pointer, losses: &losses)
        return NodeConversion(
            node: .init(
                id: nodeID,
                key: key,
                name: name.isEmpty ? step.kind.label : name,
                type: type,
                typeVersion: 1,
                config: config,
                policyRefs: needsAuthority ? ["authority": "legacy-authority"] : nil,
                annotations: [
                    "legacyStepId": .string(step.id),
                    "legacyStepKind": .string(step.kind.rawValue),
                    "readOnly": .boolean(true),
                ]
            ),
            needsAuthorityPolicy: needsAuthority
        )
    }

    private static func triggerNode(
        _ trigger: DesktopWorkflowTriggerKind,
        id: String,
        key: String
    ) -> DesktopWorkflowV1NodeDocument {
        let type: String
        let config: DesktopWorkflowJSONValue
        switch trigger {
        case .manual:
            type = "trigger.manual"
            config = .object([:])
        case .schedule:
            type = "trigger.schedule"
            config = .object([
                "scheduleKey": .string("legacy-schedule"),
                "misfirePolicy": .string("run-once"),
            ])
        case .email, .calendar:
            type = "trigger.event"
            config = .object([
                "eventContract": .string("legacy.\(trigger.rawValue)"),
                "deduplication": .string("event-id"),
            ])
        }
        return .init(
            id: id,
            key: key,
            name: "\(trigger.label) trigger",
            type: type,
            typeVersion: 1,
            config: config,
            policyRefs: nil,
            annotations: ["legacyTrigger": .string(trigger.rawValue), "readOnly": .boolean(true)]
        )
    }

    private static func matchConfiguration(
        step: DesktopWorkflowStepDefinition,
        nodeID: String,
        identitySeed: String,
        pointer: String,
        losses: inout [DesktopWorkflowLegacyImportLoss]
    ) -> DesktopWorkflowJSONValue {
        let transitions = step.transitions ?? []
        let finalFallbackIndex = transitions.indices.last.flatMap { index in
            [.always, .notMatched].contains(transitions[index].outcome)
                && transitions[index].predicates.isEmpty
                && transitions.count > 1 ? index : nil
        }
        var cases: [DesktopWorkflowJSONValue] = []
        var otherwise: DesktopWorkflowJSONValue?
        for (index, transition) in transitions.enumerated() {
            let caseID = stableUUID(
                seed: "case|\(identitySeed)|\(nodeID)|\(transition.id)|\(index)"
            )
            let port = casePort(caseID: caseID, transition: transition, index: index)
            if index == finalFallbackIndex {
                otherwise = port
                continue
            }
            guard case var .object(value) = port else { continue }
            value["when"] = condition(transition.predicates)
            cases.append(.object(value))
        }
        if cases.isEmpty {
            let caseID = stableUUID(seed: "case|\(identitySeed)|\(nodeID)|fallback")
            cases.append(.object([
                "id": .string(caseID),
                "key": .string("fallback"),
                "label": .string("Fallback"),
                "when": .object(["exists": reference(root: "value", pointer: "")]),
            ]))
            appendLoss(
                "legacy.branch.empty",
                pointer + "/config/cases",
                "The legacy branch has no ordinary case; the preview inserts a visible fallback case.",
                to: &losses
            )
        }
        var config: [String: DesktopWorkflowJSONValue] = [
            "value": reference(root: "input", pointer: ""),
            "hitPolicy": .string("first"),
            "cases": .array(cases),
        ]
        config["otherwise"] = otherwise
        return .object(config)
    }

    private static func condition(
        _ predicates: [DesktopWorkflowPredicate]
    ) -> DesktopWorkflowJSONValue {
        let conditions = predicates.map { predicate -> DesktopWorkflowJSONValue in
            let valueReference = reference(root: "value", pointer: predicate.pointer)
            switch predicate.operation {
            case .exists:
                return .object(["exists": valueReference])
            case .equals, .notEquals, .contains:
                let operation = switch predicate.operation {
                case .equals: "equal"
                case .notEquals: "notEqual"
                default: "contains"
                }
                return comparison(
                    left: valueReference,
                    operation: operation,
                    literalType: "string",
                    literal: .string(predicate.value ?? "")
                )
            case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
                let operation = switch predicate.operation {
                case .lessThan: "lessThan"
                case .lessThanOrEqual: "lessThanOrEqual"
                case .greaterThan: "greaterThan"
                default: "greaterThanOrEqual"
                }
                return comparison(
                    left: valueReference,
                    operation: operation,
                    literalType: "number",
                    literal: .number(Double(predicate.value ?? "") ?? 0)
                )
            }
        }
        if conditions.isEmpty {
            return .object(["exists": reference(root: "value", pointer: "")])
        }
        if conditions.count == 1 { return conditions[0] }
        return .object(["all": .array(conditions)])
    }

    private static func comparison(
        left: DesktopWorkflowJSONValue,
        operation: String,
        literalType: String,
        literal: DesktopWorkflowJSONValue
    ) -> DesktopWorkflowJSONValue {
        .object([
            "compare": .object([
                "left": left,
                "operator": .string(operation),
                "right": .object([
                    "literal": .object(["type": .string(literalType), "value": literal]),
                ]),
            ]),
        ])
    }

    private static func casePort(
        caseID: String,
        transition: DesktopWorkflowTransitionDefinition,
        index: Int
    ) -> DesktopWorkflowJSONValue {
        .object([
            "id": .string(caseID),
            "key": .string(stableKey("\(transition.outcome.rawValue)-\(index + 1)", seed: caseID)),
            "label": .string(transition.displayLabel),
        ])
    }

    private static func transitionPort(
        step: DesktopWorkflowStepDefinition,
        transition: DesktopWorkflowTransitionDefinition,
        transitionIndex: Int,
        identitySeed: String
    ) -> String {
        if step.kind == .match {
            let nodeID = stableUUID(seed: "node|\(identitySeed)|\(step.id)")
            let seed = "case|\(identitySeed)|\(nodeID)|\(transition.id)|\(transitionIndex)"
            return "case-\(stableUUID(seed: seed))"
        }
        if step.kind == .branch {
            return switch transition.outcome {
            case .matched: "matched"
            case .notMatched, .always: "not-matched"
            default: "error"
            }
        }
        if step.kind == .waitForEmail {
            if transition.outcome == .timedOut { return "expired" }
            if [.failed, .cancelled, .rejected].contains(transition.outcome) { return "error" }
            return "resumed"
        }
        if [.failed, .timedOut, .cancelled, .rejected].contains(transition.outcome) {
            return "error"
        }
        return "success"
    }

    private static func appendTransitionLosses(
        step: DesktopWorkflowStepDefinition,
        index: Int,
        losses: inout [DesktopWorkflowLegacyImportLoss]
    ) {
        let transitions = step.transitions ?? []
        let portPairs = transitions.enumerated().map { transitionIndex, transition in
            (
                port: transitionPort(
                    step: step,
                    transition: transition,
                    transitionIndex: transitionIndex,
                    identitySeed: "fanout-check"
                ),
                transition: transition
            )
        }
        let grouped = Dictionary(grouping: portPairs, by: \.port)
        if step.kind != .match, grouped.values.contains(where: { $0.count > 1 }) {
            appendLoss(
                "legacy.transition.output-fanout",
                "/graph/nodes/\(index)/transitions",
                "Several ordered legacy routes share one output; v2 needs an explicit Match node.",
                to: &losses
            )
        }
        for (transitionIndex, transition) in transitions.enumerated() {
            if !transition.predicates.isEmpty {
                appendLoss(
                    "legacy.predicate.coercion",
                    "/graph/nodes/\(index)/transitions/\(transitionIndex)/predicates",
                    "Legacy predicates coerce scalar values to strings; strict typed Match cannot preserve that implicitly.",
                    to: &losses
                )
            }
            if ![.branch, .match].contains(step.kind),
               ![.always, .succeeded, .failed, .timedOut, .cancelled].contains(transition.outcome) {
                appendLoss(
                    "legacy.transition.outcome-specialized",
                    "/graph/nodes/\(index)/transitions/\(transitionIndex)/outcome",
                    "This specialized legacy outcome needs a dedicated v2 decision or review route.",
                    to: &losses
                )
            }
        }
    }

    private static func appendCommonStepLosses(
        step: DesktopWorkflowStepDefinition,
        pointer: String,
        losses: inout [DesktopWorkflowLegacyImportLoss]
    ) {
        if step.retryLimit > 0 || step.executionPolicy?.maximumAttempts ?? 1 > 1 {
            appendLoss(
                "legacy.retry.requires-controller",
                pointer + "/policyRefs/retry",
                "Embedded retry counts require an explicit bounded Retry controller and idempotency review.",
                to: &losses
            )
        }
        if step.inputMappings?.isEmpty == false {
            appendLoss(
                "legacy.mapping.reference-model",
                pointer + "/config",
                "Legacy input mappings use a different reference model and require reviewed v2 mappings.",
                to: &losses
            )
        }
        if step.stateInputs?.isEmpty == false {
            appendLoss(
                "legacy.storage.scope-model",
                pointer + "/config",
                "Legacy state inputs require explicit job, case, or workflow storage declarations.",
                to: &losses
            )
        }
        if step.artifactInputs?.isEmpty == false, step.kind != .registerArtifact {
            appendLoss(
                "legacy.artifact.mapping",
                pointer + "/config",
                "Legacy artifact inputs require explicit artifact-reference mappings.",
                to: &losses
            )
        }
    }

    private static func hasNonTerminalConfiguration(_ step: DesktopWorkflowStepDefinition) -> Bool {
        step.capabilityID != nil || step.inputSchemaReference != nil || step.outputSchemaReference != nil
            || step.retryLimit != 0 || !step.isIdempotent || !step.blocking
            || step.artifactInputs?.isEmpty == false || step.stateInputs?.isEmpty == false
            || step.reviewContract != nil || step.waitContract != nil || step.executionPolicy != nil
            || step.agentPolicy != nil || step.inputMappings?.isEmpty == false || step.batchPolicy != nil
    }

    private static func authorityPolicy() -> DesktopWorkflowJSONValue {
        .object([
            "key": .string("legacy-authority"),
            "type": .string("authority"),
            "typeVersion": .number(1),
            "config": .object([
                "authorityClass": .string("local-user"),
                "approval": .string("always"),
                "reversible": .boolean(false),
            ]),
        ])
    }

    private static func edge(
        seed: String,
        fromNodeID: String,
        fromPortID: String,
        toNodeID: String,
        toPortID: String
    ) -> DesktopWorkflowV1EdgeDocument {
        .init(
            id: stableUUID(seed: "edge|\(seed)"),
            from: .init(nodeId: fromNodeID, portId: fromPortID),
            to: .init(nodeId: toNodeID, portId: toPortID),
            mappingId: stableUUID(seed: "mapping|\(seed)"),
            mapping: identityMapping
        )
    }

    private static func layoutDocument(
        identitySeed: String,
        triggerKinds: [DesktopWorkflowTriggerKind],
        steps: [DesktopWorkflowStepDefinition],
        nodeIDs: [String]
    ) -> DesktopWorkflowV1LayoutDocument {
        var nodes = triggerKinds.enumerated().map { index, trigger in
            DesktopWorkflowV1LayoutNodeDocument(
                nodeId: stableUUID(seed: "trigger|\(identitySeed)|\(trigger.rawValue)"),
                x: 120,
                y: 140 + Double(index) * 180
            )
        }
        var depthByStepID: [String: Int] = [:]
        if let first = steps.first { depthByStepID[first.id] = 1 }
        for _ in steps.indices {
            for step in steps {
                guard let depth = depthByStepID[step.id] else { continue }
                for transition in step.transitions ?? [] {
                    depthByStepID[transition.targetStepID] = max(
                        depthByStepID[transition.targetStepID] ?? 0,
                        depth + 1
                    )
                }
            }
        }
        let indexedSteps = Array(steps.enumerated())
        let groups = Dictionary(grouping: indexedSteps) { depthByStepID[$0.element.id] ?? 1 }
        for (depth, group) in groups {
            for (lane, indexedStep) in group.enumerated() {
                let nodeID = nodeIDs[indexedStep.offset]
                nodes.append(.init(
                    nodeId: nodeID,
                    x: 120 + Double(depth) * 320,
                    y: 140 + Double(lane) * 190
                ))
            }
        }
        return .init(nodes: nodes.sorted { $0.nodeId < $1.nodeId })
    }

    private static func reference(root: String, pointer: String) -> DesktopWorkflowJSONValue {
        .object(["root": .string(root), "pointer": .string(pointer)])
    }

    private static func portablePackageID(
        _ value: String,
        workflowID: String,
        losses: inout [DesktopWorkflowLegacyImportLoss]
    ) -> String {
        if validPackageID(value) { return value }
        appendLoss(
            "legacy.package-id.invalid",
            "/packageId",
            "The legacy workflow identity is not a portable package ID; the preview uses a deterministic placeholder.",
            to: &losses
        )
        return "\(fallbackPackageID)-\(workflowID.prefix(8))"
    }

    private static func validPackageID(_ value: String?) -> Bool {
        value?.range(
            of: #"^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$"#,
            options: .regularExpression
        ) != nil && (value?.utf8.count ?? 241) <= 240
    }

    private static func portableCapabilityID(_ value: String?) -> String {
        guard validPackageID(value), let value else { return fallbackPackageID }
        return value
    }

    private static func stableKey(_ value: String, seed: String) -> String {
        var slug = value.lowercased().unicodeScalars.map { scalar -> Character in
            let ascii = scalar.value
            return (ascii >= 97 && ascii <= 122) || (ascii >= 48 && ascii <= 57)
                ? Character(String(scalar)) : "-"
        }.reduce(into: "") { $0.append($1) }
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.first?.isLetter != true { slug = "step-" + slug }
        if slug.isEmpty { slug = "step" }
        let suffix = digest(Data(seed.utf8)).dropFirst("sha256:".count).prefix(8)
        return String(slug.prefix(54)) + "-" + suffix
    }

    private static func stableUUID(seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }

    private static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func bounded(
        _ value: String,
        maximum: Int,
        pointer: String,
        code: String,
        losses: inout [DesktopWorkflowLegacyImportLoss]
    ) -> String {
        guard value.count > maximum else { return value }
        appendLoss(
            code,
            pointer,
            "The legacy text exceeds the portable v2 limit and is truncated in this read-only preview.",
            to: &losses
        )
        return String(value.prefix(maximum))
    }

    private static func appendLoss(
        _ code: String,
        _ pointer: String,
        _ summary: String,
        to losses: inout [DesktopWorkflowLegacyImportLoss]
    ) {
        losses.append(.init(severity: .blocking, code: code, pointer: pointer, summary: summary))
    }
}

public extension DesktopAppModel {
    func previewLegacyWorkflowAsV2(
        definitionID: String
    ) throws -> DesktopWorkflowLegacyImportResult {
        guard let definition = snapshot.operations.workflows.definitions.first(where: {
            $0.id == definitionID
        }), let revision = snapshot.operations.workflows.revisions.first(where: {
            $0.id == definition.currentRevisionID
        }) else {
            throw DesktopWorkflowLegacyImportError.sourceEncodingFailed
        }
        return try DesktopWorkflowLegacyImporter.importSource(.init(
            definition: definition,
            revision: revision
        ))
    }
}
