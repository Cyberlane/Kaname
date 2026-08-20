import CryptoKit
import Foundation

public enum DesktopWorkflowDataReferenceSource: String, Codable, CaseIterable, Equatable, Sendable {
    case trigger
    case configuration
    case binding
    case stepOutput
    case artifact
    case state
    case dataset
    case batchItem

    public var label: String {
        switch self {
        case .trigger: "Trigger input"
        case .configuration: "Installation configuration"
        case .binding: "Private binding"
        case .stepOutput: "Prior step output"
        case .artifact: "Artifact role"
        case .state: "Workflow state"
        case .dataset: "Dataset"
        case .batchItem: "Current batch item"
        }
    }
}

public struct DesktopWorkflowDataReference: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var source: DesktopWorkflowDataReferenceSource
    public var sourceID: String?
    public var pointer: String
    public var schema: String
    public var required: Bool

    public init(
        id: String,
        source: DesktopWorkflowDataReferenceSource,
        sourceID: String? = nil,
        pointer: String = "",
        schema: String = #"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}"#,
        required: Bool = true
    ) {
        self.id = id
        self.source = source
        self.sourceID = sourceID
        self.pointer = pointer
        self.schema = schema
        self.required = required
    }
}

public struct DesktopWorkflowDataMapping: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var targetPointer: String
    public var reference: DesktopWorkflowDataReference

    public init(id: String, targetPointer: String, reference: DesktopWorkflowDataReference) {
        self.id = id
        self.targetPointer = targetPointer
        self.reference = reference
    }
}

public enum DesktopWorkflowBatchAggregationPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case requireAll
    case allowPartial
    case stopOnFirstFailure

    public var label: String {
        switch self {
        case .requireAll: "Require every item"
        case .allowPartial: "Keep successful items"
        case .stopOnFirstFailure: "Stop on first failure"
        }
    }
}

public struct DesktopWorkflowBatchPolicy: Codable, Equatable, Sendable {
    public var itemsPointer: String
    public var maximumItems: Int
    public var maximumConcurrency: Int
    public var aggregation: DesktopWorkflowBatchAggregationPolicy

    public init(
        itemsPointer: String = "/items",
        maximumItems: Int = 100,
        maximumConcurrency: Int = 1,
        aggregation: DesktopWorkflowBatchAggregationPolicy = .requireAll
    ) {
        self.itemsPointer = itemsPointer
        self.maximumItems = maximumItems
        self.maximumConcurrency = maximumConcurrency
        self.aggregation = aggregation
    }
}

public enum DesktopWorkflowBatchItemState: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case unknown
    case cancelled
}

public struct DesktopWorkflowBatchItemRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var runID: String
    public var stepID: String
    public var ordinal: Int
    public var inputDigest: String
    public var outputDigest: String?
    public var state: DesktopWorkflowBatchItemState
    public var attempt: Int
    public var errorSummary: String?
    public var startedAtUnixMillis: Int64?
    public var completedAtUnixMillis: Int64?
}

public struct DesktopWorkflowCanvasNodePosition: Codable, Equatable, Identifiable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var x: Double
    public var y: Double

    public init(stepID: String, x: Double, y: Double) {
        self.stepID = stepID
        self.x = x
        self.y = y
    }
}

public struct DesktopWorkflowStudioManifestMetadata: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var source: String
    public var license: String
    public var correlationSummary: String
    public var contextSummary: String
    public var completionSummary: String
    public var datasets: [DesktopWorkflowDatasetDefinition]?
    public var configurationSchema: String?
    public var configurationSchemaVersion: Int?
    public var manualRunInputSchema: String?
    public var bindingSlots: [DesktopWorkflowBindingSlotDefinition]?
    public var providerFeatures: [DesktopWorkflowProviderFeatureRequirement]?
    public var hostCompatibility: DesktopWorkflowHostCompatibility?
    public var dependencies: [DesktopWorkflowDependencyConstraint]?
    public var publisher: DesktopWorkflowPublisher?
    public var provenance: DesktopWorkflowPackageProvenance?
    public var uiHints: [DesktopWorkflowUIHint]?
    public var configurationMigrations: [DesktopWorkflowConfigurationMigration]?

    public static let newDraft = Self(
        schemaVersion: 3,
        source: "Kaname Workflow Studio",
        license: "Private",
        correlationSummary: "Configured in Workflow Studio",
        contextSummary: "Compile declared workflow context and current artifacts.",
        completionSummary: "Complete after declared validators, reviews, and effects.",
        datasets: nil,
        configurationSchema: nil,
        configurationSchemaVersion: nil,
        manualRunInputSchema: nil,
        bindingSlots: nil,
        providerFeatures: nil,
        hostCompatibility: .init(minimumWorkspaceSchema: 24),
        dependencies: nil,
        publisher: .init(name: "Local author", identifier: "local.author"),
        provenance: .init(buildSystem: "Kaname Workflow Studio"),
        uiHints: nil,
        configurationMigrations: nil
    )
}

public struct DesktopWorkflowStudioSnapshot: Codable, Equatable, Sendable {
    public var steps: [DesktopWorkflowStepDefinition]
    public var triggerKinds: [DesktopWorkflowTriggerKind]
    public var permissions: DesktopWorkflowPermissionEnvelope
    public var subflows: [DesktopWorkflowSubflowReference]
    public var canvasPositions: [DesktopWorkflowCanvasNodePosition]
    public var metadata: DesktopWorkflowStudioManifestMetadata
}

public enum DesktopWorkflowStudioGraphEditing {
    private static let canvasColumns = 3
    private static let canvasOrigin = 30.0
    private static let canvasColumnStride = 310.0
    private static let canvasNodeWidth = 244.0
    private static let canvasMinimumNodeHeight = 96.0
    private static let canvasOutputTop = 58.0
    private static let canvasOutputSpacing = 34.0
    private static let canvasHorizontalGap = 36.0
    private static let canvasVerticalGap = 50.0

    public static func defaultCanvasPositions(
        for steps: [DesktopWorkflowStepDefinition]
    ) -> [DesktopWorkflowCanvasNodePosition] {
        var positions: [DesktopWorkflowCanvasNodePosition] = []
        var rowOrigin = canvasOrigin

        for rowStart in stride(from: 0, to: steps.count, by: canvasColumns) {
            let rowEnd = min(rowStart + canvasColumns, steps.count)
            let rowSteps = steps[rowStart..<rowEnd]
            for (column, step) in rowSteps.enumerated() {
                positions.append(.init(
                    stepID: step.id,
                    x: canvasOrigin + Double(column) * canvasColumnStride,
                    y: rowOrigin
                ))
            }
            rowOrigin += rowSteps.map(canvasNodeHeight).max() ?? canvasMinimumNodeHeight
            rowOrigin += canvasVerticalGap
        }

        return positions
    }

    @discardableResult
    public static func normalizeCanvasPositions(
        _ positions: inout [DesktopWorkflowCanvasNodePosition],
        for steps: [DesktopWorkflowStepDefinition]
    ) -> Bool {
        let validStepIDs = Set(steps.map(\.id))
        var storedByStepID: [String: DesktopWorkflowCanvasNodePosition] = [:]
        for position in positions where validStepIDs.contains(position.stepID) {
            guard position.x.isFinite, position.y.isFinite,
                  storedByStepID[position.stepID] == nil else { continue }
            storedByStepID[position.stepID] = position
        }

        let defaults = defaultCanvasPositions(for: steps)
        let defaultsByStepID = Dictionary(uniqueKeysWithValues: defaults.map { ($0.stepID, $0) })
        var normalized = steps.compactMap { step in
            storedByStepID[step.id] ?? defaultsByStepID[step.id]
        }

        if containsCanvasCollision(normalized, steps: steps) {
            normalized = defaults
        }

        guard normalized != positions else { return false }
        positions = normalized
        return true
    }

    public static func initialTransitions(
        for kind: DesktopWorkflowStepKind
    ) -> [DesktopWorkflowTransitionDefinition] {
        switch kind {
        case .complete:
            []
        case .branch:
            [
                route(label: "Yes", outcome: .matched),
                route(label: "No", outcome: .notMatched),
            ]
        case .match:
            [
                route(label: "Case 1", outcome: .selected),
                route(label: "Case 2", outcome: .selected),
                route(label: "Otherwise", outcome: .notMatched),
            ]
        case .humanReview, .requestApproval:
            [
                route(label: "Approved", outcome: .approved),
                route(label: "Rejected", outcome: .rejected),
            ]
        case .effect, .createEmailDraft, .sendEmail, .validate:
            [
                route(label: "Succeeded", outcome: .succeeded),
                route(label: "Failed", outcome: .failed),
            ]
        case .waitForEmail:
            [
                route(label: "Resumed", outcome: .succeeded),
                route(label: "Timed out", outcome: .timedOut),
                route(label: "Failed", outcome: .failed),
            ]
        default:
            [route(label: "Next", outcome: .always)]
        }
    }

    public static func route(
        label: String,
        outcome: DesktopWorkflowTransitionOutcome,
        targetStepID: String = "",
        predicates: [DesktopWorkflowPredicate] = []
    ) -> DesktopWorkflowTransitionDefinition {
        .init(
            routeID: newRouteID(),
            label: label,
            outcome: outcome,
            targetStepID: targetStepID,
            predicates: predicates
        )
    }

    @discardableResult
    public static func normalizeRouteIDs(
        in steps: inout [DesktopWorkflowStepDefinition]
    ) -> Bool {
        var changed = false
        var seen = Set<String>()
        for stepIndex in steps.indices {
            guard var transitions = steps[stepIndex].transitions else { continue }
            for transitionIndex in transitions.indices {
                if let routeID = transitions[transitionIndex].routeID,
                   !routeID.isEmpty,
                   seen.insert(routeID).inserted {
                    continue
                }
                let routeID = newRouteID()
                transitions[transitionIndex].routeID = routeID
                seen.insert(routeID)
                changed = true
            }
            steps[stepIndex].transitions = transitions
        }
        return changed
    }

    @discardableResult
    public static func connect(
        routeID: String,
        to targetStepID: String,
        in steps: inout [DesktopWorkflowStepDefinition]
    ) -> Bool {
        guard let sourceIndex = steps.firstIndex(where: { step in
            (step.transitions ?? []).contains { $0.routeID == routeID }
        }),
        steps[sourceIndex].id != targetStepID,
        steps.contains(where: { $0.id == targetStepID }),
        let transitionIndex = steps[sourceIndex].transitions?.firstIndex(where: {
            $0.routeID == routeID
        }) else { return false }
        guard steps[sourceIndex].transitions?[transitionIndex].targetStepID != targetStepID else {
            return false
        }
        steps[sourceIndex].transitions?[transitionIndex].targetStepID = targetStepID
        return true
    }

    @discardableResult
    public static func disconnect(
        routeID: String,
        in steps: inout [DesktopWorkflowStepDefinition]
    ) -> Bool {
        guard let sourceIndex = steps.firstIndex(where: { step in
            (step.transitions ?? []).contains { $0.routeID == routeID }
        }),
        let transitionIndex = steps[sourceIndex].transitions?.firstIndex(where: {
            $0.routeID == routeID
        }),
        steps[sourceIndex].transitions?[transitionIndex].isConnected == true else { return false }
        steps[sourceIndex].transitions?[transitionIndex].targetStepID = ""
        return true
    }

    @discardableResult
    public static func removeSteps(
        _ stepIDs: Set<String>,
        in steps: inout [DesktopWorkflowStepDefinition]
    ) -> Bool {
        let existingIDs = Set(steps.map(\.id))
        let removedIDs = stepIDs.intersection(existingIDs)
        guard !removedIDs.isEmpty else { return false }

        steps.removeAll { removedIDs.contains($0.id) }
        for stepIndex in steps.indices {
            guard var transitions = steps[stepIndex].transitions else { continue }
            for transitionIndex in transitions.indices where removedIDs.contains(
                transitions[transitionIndex].targetStepID
            ) {
                transitions[transitionIndex].targetStepID = ""
            }
            steps[stepIndex].transitions = transitions
        }
        return true
    }

    private static func containsCanvasCollision(
        _ positions: [DesktopWorkflowCanvasNodePosition],
        steps: [DesktopWorkflowStepDefinition]
    ) -> Bool {
        let stepsByID = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
        for firstIndex in positions.indices {
            guard let firstStep = stepsByID[positions[firstIndex].stepID] else { continue }
            let first = positions[firstIndex]
            let firstHeight = canvasNodeHeight(firstStep)
            for secondIndex in positions.indices where secondIndex > firstIndex {
                guard let secondStep = stepsByID[positions[secondIndex].stepID] else { continue }
                let second = positions[secondIndex]
                let separatedHorizontally = first.x + canvasNodeWidth + canvasHorizontalGap <= second.x
                    || second.x + canvasNodeWidth + canvasHorizontalGap <= first.x
                let separatedVertically = first.y + firstHeight + canvasVerticalGap <= second.y
                    || second.y + canvasNodeHeight(secondStep) + canvasVerticalGap <= first.y
                if !separatedHorizontally && !separatedVertically { return true }
            }
        }
        return false
    }

    private static func canvasNodeHeight(_ step: DesktopWorkflowStepDefinition) -> Double {
        max(
            canvasMinimumNodeHeight,
            canvasOutputTop + Double(step.transitions?.count ?? 0) * canvasOutputSpacing + 8
        )
    }

    @discardableResult
    public static func connect(
        from sourceStepID: String,
        to targetStepID: String,
        outcome: DesktopWorkflowTransitionOutcome,
        in steps: inout [DesktopWorkflowStepDefinition]
    ) -> Bool {
        guard sourceStepID != targetStepID,
              let sourceIndex = steps.firstIndex(where: { $0.id == sourceStepID }),
              steps[sourceIndex].kind != .complete,
              steps.contains(where: { $0.id == targetStepID }) else { return false }

        var transitions = steps[sourceIndex].transitions ?? []
        guard !transitions.contains(where: {
            $0.outcome == outcome && $0.targetStepID == targetStepID
        }) else { return false }

        if let unconditionedIndex = transitions.firstIndex(where: {
            $0.outcome == outcome && $0.predicates.isEmpty
        }) {
            transitions[unconditionedIndex].targetStepID = targetStepID
        } else {
            transitions.append(route(
                label: outcome == .always ? "Next" : outcome.rawValue.capitalized,
                outcome: outcome,
                targetStepID: targetStepID
            ))
        }
        steps[sourceIndex].transitions = transitions
        return true
    }

    @discardableResult
    public static func disconnect(
        from sourceStepID: String,
        to targetStepID: String,
        outcome: DesktopWorkflowTransitionOutcome,
        in steps: inout [DesktopWorkflowStepDefinition]
    ) -> Bool {
        guard let sourceIndex = steps.firstIndex(where: { $0.id == sourceStepID }),
              var transitions = steps[sourceIndex].transitions,
              let transitionIndex = transitions.firstIndex(where: {
                  $0.outcome == outcome && $0.targetStepID == targetStepID
              }) else { return false }
        transitions.remove(at: transitionIndex)
        steps[sourceIndex].transitions = transitions.isEmpty ? nil : transitions
        return true
    }

    public static func suggestedOutcome(
        from sourceStepID: String,
        in steps: [DesktopWorkflowStepDefinition]
    ) -> DesktopWorkflowTransitionOutcome? {
        guard let step = steps.first(where: { $0.id == sourceStepID }), step.kind != .complete else {
            return nil
        }
        let existing = Set((step.transitions ?? []).map(\.outcome))
        let candidates: [DesktopWorkflowTransitionOutcome] = switch step.kind {
        case .branch:
            [.matched, .notMatched, .selected]
        case .match:
            [.selected]
        case .humanReview, .requestApproval:
            [.approved, .rejected, .edited]
        case .effect, .createEmailDraft, .sendEmail, .validate:
            [.succeeded, .failed, .timedOut]
        case .waitForEmail:
            [.succeeded, .timedOut, .failed]
        default:
            [.always]
        }
        return candidates.first(where: { !existing.contains($0) })
    }

    private static func newRouteID() -> String {
        "route-\(UUID().uuidString.lowercased())"
    }
}

public enum DesktopWorkflowSourceFormatting {
    public static func prettyPrintedJSON(_ source: String) -> String? {
        guard let data = source.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return nil
        }

        let characters = Array(source)
        var nextSignificant = [Character?](repeating: nil, count: characters.count)
        var next: Character?
        for index in characters.indices.reversed() {
            nextSignificant[index] = next
            if !characters[index].isWhitespace { next = characters[index] }
        }

        var output = ""
        var indentation = 0
        var inString = false
        var escaped = false
        var previousSignificant: Character?

        func appendLineBreak() {
            output.append("\n")
            output.append(String(repeating: "  ", count: indentation))
        }

        for index in characters.indices {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                previousSignificant = character
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                previousSignificant = character
                continue
            }
            if character.isWhitespace { continue }

            switch character {
            case "{", "[":
                output.append(character)
                indentation += 1
                let closingCharacter: Character = character == "{" ? "}" : "]"
                if nextSignificant[index] != closingCharacter { appendLineBreak() }
            case "}", "]":
                indentation = max(0, indentation - 1)
                let openingCharacter: Character = character == "}" ? "{" : "["
                if previousSignificant != openingCharacter { appendLineBreak() }
                output.append(character)
            case ",":
                output.append(character)
                appendLineBreak()
            case ":":
                output.append(": ")
            default:
                output.append(character)
            }
            previousSignificant = character
        }
        return output
    }
}

public enum DesktopWorkflowSourceTokenKind: String, Equatable, Sendable {
    case key
    case string
    case number
    case literal
    case punctuation
}

public struct DesktopWorkflowSourceToken: Equatable, Sendable {
    public let kind: DesktopWorkflowSourceTokenKind
    public let location: Int
    public let length: Int

    public init(kind: DesktopWorkflowSourceTokenKind, location: Int, length: Int) {
        self.kind = kind
        self.location = location
        self.length = length
    }
}

public enum DesktopWorkflowSourceSyntax {
    public static func tokens(in source: String) -> [DesktopWorkflowSourceToken] {
        let text = source as NSString
        var tokens: [DesktopWorkflowSourceToken] = []
        var index = 0

        while index < text.length {
            let character = text.character(at: index)
            if isWhitespace(character) {
                index += 1
            } else if character == 34 {
                let start = index
                index += 1
                var escaped = false
                while index < text.length {
                    let current = text.character(at: index)
                    index += 1
                    if escaped {
                        escaped = false
                    } else if current == 92 {
                        escaped = true
                    } else if current == 34 {
                        break
                    }
                }
                var cursor = index
                while cursor < text.length, isWhitespace(text.character(at: cursor)) { cursor += 1 }
                tokens.append(.init(
                    kind: cursor < text.length && text.character(at: cursor) == 58 ? .key : .string,
                    location: start,
                    length: index - start
                ))
            } else if isNumberCharacter(character) {
                let start = index
                repeat { index += 1 } while index < text.length && isNumberCharacter(text.character(at: index))
                tokens.append(.init(kind: .number, location: start, length: index - start))
            } else if isLetter(character) {
                let start = index
                repeat { index += 1 } while index < text.length && isLetter(text.character(at: index))
                let value = text.substring(with: NSRange(location: start, length: index - start))
                if value == "true" || value == "false" || value == "null" {
                    tokens.append(.init(kind: .literal, location: start, length: index - start))
                }
            } else if isPunctuation(character) {
                tokens.append(.init(kind: .punctuation, location: index, length: 1))
                index += 1
            } else {
                index += 1
            }
        }
        return tokens
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 9 || character == 10 || character == 13 || character == 32
    }

    private static func isNumberCharacter(_ character: unichar) -> Bool {
        character == 43 || character == 45 || character == 46
            || (character >= 48 && character <= 57)
            || character == 69 || character == 101
    }

    private static func isLetter(_ character: unichar) -> Bool {
        (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
    }

    private static func isPunctuation(_ character: unichar) -> Bool {
        character == 44 || character == 58
            || character == 91 || character == 93
            || character == 123 || character == 125
    }
}

public enum DesktopWorkflowStudioScaffold {
    public static let blankSource = #"""
    {
      "completionSummary": "Finish at the declared terminal node.",
      "contextSummary": "Use only declared workflow input and artifacts.",
      "correlationSummary": "Manual input starts one workflow run.",
      "icon": "point.3.connected.trianglepath.dotted",
      "hostCompatibility": { "minimumWorkspaceSchema": 24 },
      "id": "local.imported-workflow",
      "license": "Private",
      "name": "Imported workflow",
      "permissions": {
        "accountIDs": [],
        "capabilityIDs": [],
        "dataClassesLeavingDevice": [],
        "filesystemScopes": [],
        "networkDestinations": [],
        "permissions": []
      },
      "provenance": { "buildSystem": "Kaname Workflow Studio" },
      "publisher": { "identifier": "local.author", "name": "Local author" },
      "schemaVersion": 3,
      "source": "Kaname Workflow Studio",
      "steps": [
        {
          "blocking": true,
          "id": "prepare",
          "isIdempotent": true,
          "kind": "classifyEvent",
          "name": "Receive input",
          "retryLimit": 0,
          "transitions": [
            { "outcome": "always", "predicates": [], "targetStepID": "complete" }
          ]
        },
        {
          "blocking": true,
          "id": "complete",
          "isIdempotent": true,
          "kind": "complete",
          "name": "Complete",
          "retryLimit": 0
        }
      ],
      "summary": "A workflow authored from canonical source.",
      "triggers": ["manual"],
      "version": "1.0.0"
    }
    """#
}

public enum DesktopWorkflowStudioDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case error
    case warning
}

public struct DesktopWorkflowStudioDiagnostic: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(severity.rawValue):\(path):\(message)" }
    public var severity: DesktopWorkflowStudioDiagnosticSeverity
    public var path: String
    public var message: String
}

public enum DesktopWorkflowStudioValidation {
    public static func diagnostics(
        steps: [DesktopWorkflowStepDefinition],
        metadata: DesktopWorkflowStudioManifestMetadata
    ) -> [DesktopWorkflowStudioDiagnostic] {
        var result: [DesktopWorkflowStudioDiagnostic] = []
        do { try DesktopWorkflowHostContractValidation.validateGraph(steps) }
        catch { result.append(.init(severity: .error, path: "/steps", message: error.localizedDescription)) }
        let stepIDs = Set(steps.map(\.id))
        for (index, step) in steps.enumerated() {
            do { try DesktopWorkflowHostContractValidation.validate(step: step, stepIDs: stepIDs) }
            catch { result.append(.init(severity: .error, path: "/steps/\(index)", message: error.localizedDescription)) }
            for (mappingIndex, mapping) in (step.inputMappings ?? []).enumerated() {
                let path = "/steps/\(index)/inputMappings/\(mappingIndex)"
                if !mapping.targetPointer.hasPrefix("/") {
                    result.append(.init(severity: .error, path: path + "/targetPointer", message: "Target must be a JSON Pointer."))
                }
                if !mapping.reference.pointer.isEmpty && !mapping.reference.pointer.hasPrefix("/") {
                    result.append(.init(severity: .error, path: path + "/reference/pointer", message: "Source must be a JSON Pointer."))
                }
                if let issue = DesktopWorkflowJSONSchemaValidator.schemaDiagnostics(Data(mapping.reference.schema.utf8), requireDeclaredDialect: true).first {
                    result.append(.init(severity: .error, path: path + "/reference/schema" + issue.path, message: issue.message))
                }
                if mapping.reference.source == .stepOutput {
                    guard let sourceID = mapping.reference.sourceID,
                          let sourceIndex = steps.firstIndex(where: { $0.id == sourceID }), sourceIndex < index else {
                        result.append(.init(severity: .error, path: path + "/reference/sourceID", message: "Step output mappings must reference an earlier reachable step."))
                        continue
                    }
                }
            }
        }
        if metadata.schemaVersion == 3 {
            if let schema = metadata.configurationSchema {
                for issue in DesktopWorkflowJSONSchemaValidator.schemaDiagnostics(Data(schema.utf8), requireDeclaredDialect: true) {
                    result.append(.init(severity: .error, path: "/configurationSchema" + issue.path, message: issue.message))
                }
            }
            if let schema = metadata.manualRunInputSchema {
                for issue in DesktopWorkflowJSONSchemaValidator.schemaDiagnostics(Data(schema.utf8), requireDeclaredDialect: true) {
                    result.append(.init(severity: .error, path: "/manualRunInputSchema" + issue.path, message: issue.message))
                }
            }
        }
        return result
    }
}

public enum DesktopWorkflowRunNodeState: String, Codable, CaseIterable, Equatable, Sendable {
    case notRun
    case queued
    case running
    case waiting
    case needsReview
    case retrying
    case succeeded
    case skipped
    case failed
    case outcomeUnknown
    case cancelled

    public var label: String {
        switch self {
        case .notRun: "Not run"
        case .queued: "Queued"
        case .running: "Running"
        case .waiting: "Waiting"
        case .needsReview: "Needs review"
        case .retrying: "Retrying"
        case .succeeded: "Succeeded"
        case .skipped: "Skipped"
        case .failed: "Failed"
        case .outcomeUnknown: "Outcome unknown—reconcile"
        case .cancelled: "Cancelled"
        }
    }
}

public struct DesktopWorkflowRunNodeProjection: Equatable, Identifiable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var state: DesktopWorkflowRunNodeState
    public var attempt: Int
    public var elapsedMilliseconds: Int64?
    public var detail: String
    public var completedItems: Int
    public var totalItems: Int
    public var failedItems: Int
    public var unknownItems: Int
}

public struct DesktopWorkflowRunStepComparison: Equatable, Identifiable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var leftState: DesktopWorkflowRunNodeState
    public var rightState: DesktopWorkflowRunNodeState
    public var inputChanged: Bool
    public var outputChanged: Bool
    public var durationDeltaMilliseconds: Int64?
    public var branchChanged: Bool
}

public enum DesktopWorkflowDebugAction: String, CaseIterable, Equatable, Sendable {
    case pauseBeforeStep
    case continueSimulation
    case retryFailedStep
    case restartFromCheckpoint
    case reprocessCurrentRevision
    case reconcileUnknownEffect
}

public struct DesktopWorkflowDebugEligibility: Equatable, Sendable {
    public var allowed: Set<DesktopWorkflowDebugAction>
    public var reasons: [DesktopWorkflowDebugAction: String]
}

public enum DesktopWorkflowRunProjection {
    public static func nodes(
        run: DesktopWorkflowRunRecord,
        revision: DesktopWorkflowRevisionRecord,
        attempts: [DesktopWorkflowStepAttemptRecord],
        transitions: [DesktopWorkflowTransitionRecord],
        waits: [DesktopWorkflowWaitSubscriptionRecord],
        reviews: [DesktopWorkflowReviewRequestRecord],
        effects: [DesktopWorkflowEffectRecord],
        batchItems: [DesktopWorkflowBatchItemRecord],
        now: Int64
    ) -> [DesktopWorkflowRunNodeProjection] {
        revision.steps.map { step in
            let relevant = attempts.filter { $0.runID == run.id && $0.stepID == step.id }
            let latest = relevant.max { $0.attempt < $1.attempt }
            let activeWait = waits.first { $0.runID == run.id && $0.stepID == step.id && $0.state == .active }
            let review = reviews.first { $0.runID == run.id && $0.stepID == step.id && $0.state == .pending }
            let unknown = effects.contains { $0.runID == run.id && $0.stepID == step.id && $0.state == .outcomeUnknown }
            let selected = transitions.contains { $0.runID == run.id && $0.toStepID == step.id }
            let items = batchItems.filter { $0.runID == run.id && $0.stepID == step.id }
            let state: DesktopWorkflowRunNodeState
            let detail: String
            if unknown { (state, detail) = (.outcomeUnknown, "Remote outcome must be reconciled before retry.") }
            else if review != nil { (state, detail) = (.needsReview, "A human decision is required.") }
            else if let activeWait { (state, detail) = (.waiting, "Waiting until \(activeWait.deadlineUnixMillis).") }
            else if latest?.state == .running { (state, detail) = (relevant.count > 1 ? .retrying : .running, "Attempt \(latest?.attempt ?? 1) is active.") }
            else if latest?.state == .completed { (state, detail) = (.succeeded, "Completed with durable evidence.") }
            else if latest?.state == .failed { (state, detail) = (.failed, latest?.errorSummary ?? "The step failed.") }
            else if latest?.state == .cancelled { (state, detail) = (.cancelled, "Cancelled.") }
            else if selected || run.currentStepID == step.id { (state, detail) = (.queued, "Ready to run.") }
            else if !transitions.isEmpty { (state, detail) = (.skipped, "This branch was not selected.") }
            else { (state, detail) = (.notRun, "Not run.") }
            let elapsed = latest.map { max(0, ($0.completedAtUnixMillis ?? now) - $0.startedAtUnixMillis) }
            return .init(
                stepID: step.id, state: state, attempt: latest?.attempt ?? 0,
                elapsedMilliseconds: elapsed, detail: detail,
                completedItems: items.filter { $0.state == .succeeded }.count,
                totalItems: items.count,
                failedItems: items.filter { $0.state == .failed }.count,
                unknownItems: items.filter { $0.state == .unknown }.count
            )
        }
    }

    public static func compare(
        left: [DesktopWorkflowRunNodeProjection],
        right: [DesktopWorkflowRunNodeProjection],
        leftAttempts: [DesktopWorkflowStepAttemptRecord],
        rightAttempts: [DesktopWorkflowStepAttemptRecord],
        leftTransitions: [DesktopWorkflowTransitionRecord],
        rightTransitions: [DesktopWorkflowTransitionRecord]
    ) -> [DesktopWorkflowRunStepComparison] {
        let ids = Set(left.map(\.stepID)).union(right.map(\.stepID)).sorted()
        return ids.map { id in
            let lhs = left.first { $0.stepID == id }
            let rhs = right.first { $0.stepID == id }
            let la = leftAttempts.last { $0.stepID == id }
            let ra = rightAttempts.last { $0.stepID == id }
            let lt = leftTransitions.last { $0.fromStepID == id }
            let rt = rightTransitions.last { $0.fromStepID == id }
            return .init(
                stepID: id, leftState: lhs?.state ?? .notRun, rightState: rhs?.state ?? .notRun,
                inputChanged: la?.inputDigest != ra?.inputDigest,
                outputChanged: la?.outputDigest != ra?.outputDigest,
                durationDeltaMilliseconds: duration(ra).flatMap { rightDuration in duration(la).map { rightDuration - $0 } },
                branchChanged: lt?.toStepID != rt?.toStepID || lt?.outcome != rt?.outcome
            )
        }
    }

    public static func debugEligibility(
        step: DesktopWorkflowStepDefinition,
        projection: DesktopWorkflowRunNodeProjection,
        hasUnknownEffect: Bool
    ) -> DesktopWorkflowDebugEligibility {
        var allowed: Set<DesktopWorkflowDebugAction> = [.pauseBeforeStep, .continueSimulation, .reprocessCurrentRevision]
        var reasons: [DesktopWorkflowDebugAction: String] = [:]
        if projection.state == .failed && step.isIdempotent && !hasUnknownEffect { allowed.insert(.retryFailedStep) }
        else { reasons[.retryFailedStep] = hasUnknownEffect ? "Reconcile the unknown effect first." : "The step is not safely idempotent." }
        if [.succeeded, .failed, .cancelled].contains(projection.state) { allowed.insert(.restartFromCheckpoint) }
        else { reasons[.restartFromCheckpoint] = "A durable completed checkpoint is required." }
        if hasUnknownEffect { allowed.insert(.reconcileUnknownEffect) }
        else { reasons[.reconcileUnknownEffect] = "No unknown effect exists." }
        return .init(allowed: allowed, reasons: reasons)
    }

    private static func duration(_ attempt: DesktopWorkflowStepAttemptRecord?) -> Int64? {
        guard let attempt, let completed = attempt.completedAtUnixMillis else { return nil }
        return max(0, completed - attempt.startedAtUnixMillis)
    }
}

@MainActor
public extension DesktopAppModel {
    @discardableResult
    func queueWorkflowDebugRun(
        priorRunID: String,
        action: DesktopWorkflowDebugAction,
        stepID: String? = nil
    ) -> String? {
        guard let prior = snapshot.operations.workflows.runs.first(where: { $0.id == priorRunID }),
              let contextID = prior.contextSnapshotID,
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == prior.workflowRevisionID }) else {
            return nil
        }
        switch action {
        case .retryFailedStep:
            guard prior.state == .failed, let stepID,
                  let step = revision.steps.first(where: { $0.id == stepID }), step.isIdempotent,
                  snapshot.operations.workflows.stepAttempts.contains(where: {
                      $0.runID == priorRunID && $0.stepID == stepID && $0.state == .failed
                  }),
                  !snapshot.operations.workflows.effects.contains(where: {
                      $0.runID == priorRunID && $0.stepID == stepID && $0.state == .outcomeUnknown
                  }) else { return nil }
            return queueWorkflowRun(
                workItemID: prior.workItemID, episodeID: prior.episodeID, contextSnapshotID: contextID,
                retryMode: .failedStep, priorRunID: priorRunID, startStepID: stepID
            )
        case .restartFromCheckpoint:
            guard [.completed, .failed, .cancelled].contains(prior.state), let stepID,
                  snapshot.operations.workflows.stepAttempts.contains(where: {
                      $0.runID == priorRunID && $0.stepID == stepID && $0.state == .completed
                  }),
                  let next = snapshot.operations.workflows.transitionRecords.last(where: {
                      $0.runID == priorRunID && $0.fromStepID == stepID
                  })?.toStepID else { return nil }
            return queueWorkflowRun(
                workItemID: prior.workItemID, episodeID: prior.episodeID, contextSnapshotID: contextID,
                retryMode: .exactReplay, priorRunID: priorRunID, startStepID: next
            )
        case .reprocessCurrentRevision:
            guard [.completed, .failed, .cancelled].contains(prior.state) else { return nil }
            return queueWorkflowRun(
                workItemID: prior.workItemID, episodeID: prior.episodeID, contextSnapshotID: contextID,
                retryMode: .currentRevision, priorRunID: priorRunID
            )
        case .pauseBeforeStep, .continueSimulation, .reconcileUnknownEffect:
            return nil
        }
    }

    func prepareWorkflowBatch(runID: String, stepID: String, input: Data) throws -> [DesktopWorkflowBatchItemRecord] {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
              let step = revision.steps.first(where: { $0.id == stepID }),
              let policy = step.batchPolicy else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("The batch step is unavailable.")
        }
        if !snapshot.operations.workflows.batchItems.filter({ $0.runID == runID && $0.stepID == stepID }).isEmpty {
            return snapshot.operations.workflows.batchItems
                .filter { $0.runID == runID && $0.stepID == stepID }.sorted { $0.ordinal < $1.ordinal }
        }
        guard let value = try DesktopWorkflowStructuredValue.value(at: policy.itemsPointer, in: input),
              let items = value as? [Any], items.count <= policy.maximumItems else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("The batch input is not an array or exceeds its reviewed item limit.")
        }
        let records = try items.enumerated().map { ordinal, item in
            let data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            let digest = DesktopWorkflowStructuredValue.digest(data)
            let identity = DesktopWorkflowStructuredValue.digest(Data("\(runID):\(stepID):\(ordinal):\(digest)".utf8))
            return DesktopWorkflowBatchItemRecord(
                id: identity, runID: runID, stepID: stepID, ordinal: ordinal,
                inputDigest: digest, outputDigest: nil, state: .queued, attempt: 0,
                errorSummary: nil, startedAtUnixMillis: nil, completedAtUnixMillis: nil
            )
        }
        guard mutate({ $0.operations.workflows.batchItems.append(contentsOf: records) }) else {
            throw DesktopWorkflowDataPlaneError.stateConflict
        }
        return records
    }

    @discardableResult
    func updateWorkflowBatchItem(
        id: String,
        state: DesktopWorkflowBatchItemState,
        outputDigest: String? = nil,
        error: String? = nil
    ) -> Bool {
        let timestamp = now()
        return mutateRecord(at: \.operations.workflows.batchItems, id: id) { item in
            item.state = state
            if state == .running {
                item.attempt += 1
                item.startedAtUnixMillis = timestamp
                item.completedAtUnixMillis = nil
            } else if [.succeeded, .failed, .unknown, .cancelled].contains(state) {
                item.completedAtUnixMillis = timestamp
            }
            item.outputDigest = outputDigest
            item.errorSummary = error.map { String($0.prefix(2_048)) }
        }
    }

    func workflowRunProjection(runID: String, now timestamp: Int64? = nil) -> [DesktopWorkflowRunNodeProjection] {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }) else { return [] }
        return DesktopWorkflowRunProjection.nodes(
            run: run, revision: revision,
            attempts: snapshot.operations.workflows.stepAttempts.filter { $0.runID == runID },
            transitions: snapshot.operations.workflows.transitionRecords.filter { $0.runID == runID },
            waits: snapshot.operations.workflows.waitSubscriptions.filter { $0.runID == runID },
            reviews: snapshot.operations.workflows.reviewRequests.filter { $0.runID == runID },
            effects: snapshot.operations.workflows.effects.filter { $0.runID == runID },
            batchItems: snapshot.operations.workflows.batchItems.filter { $0.runID == runID },
            now: timestamp ?? now()
        )
    }

    func compareWorkflowRuns(leftRunID: String, rightRunID: String) -> [DesktopWorkflowRunStepComparison] {
        let leftAttempts = snapshot.operations.workflows.stepAttempts.filter { $0.runID == leftRunID }
        let rightAttempts = snapshot.operations.workflows.stepAttempts.filter { $0.runID == rightRunID }
        return DesktopWorkflowRunProjection.compare(
            left: workflowRunProjection(runID: leftRunID), right: workflowRunProjection(runID: rightRunID),
            leftAttempts: leftAttempts, rightAttempts: rightAttempts,
            leftTransitions: snapshot.operations.workflows.transitionRecords.filter { $0.runID == leftRunID },
            rightTransitions: snapshot.operations.workflows.transitionRecords.filter { $0.runID == rightRunID }
        )
    }
}
