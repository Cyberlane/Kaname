import Foundation
import KanameProtocol

public enum DesktopWorkflowDiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case error
    case warning
    case info
    case unknown

    fileprivate var sortOrder: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .info: 2
        case .unknown: 3
        }
    }
}

public enum DesktopWorkflowDiagnosticProjection: String, Codable, CaseIterable, Sendable {
    case canvas
    case outline
    case source
}

public struct DesktopWorkflowDiagnosticSourcePosition: Codable, Equatable, Sendable {
    public var byteOffset: UInt64
    public var line: UInt32
    public var column: UInt32

    public init(byteOffset: UInt64, line: UInt32, column: UInt32) {
        self.byteOffset = byteOffset
        self.line = line
        self.column = column
    }
}

public struct DesktopWorkflowDiagnosticSourceRange: Codable, Equatable, Sendable {
    public var sourceID: String
    public var jsonPointer: String
    public var start: DesktopWorkflowDiagnosticSourcePosition
    public var end: DesktopWorkflowDiagnosticSourcePosition
}

public struct DesktopWorkflowDiagnosticFocusTarget: Codable, Equatable, Sendable {
    public var projection: DesktopWorkflowDiagnosticProjection
    public var nodeID: String?
    public var edgeID: String?
    public var jsonPointer: String?
    public var sourceRange: DesktopWorkflowDiagnosticSourceRange?

    public static func canvas(
        nodeID: String? = nil,
        edgeID: String? = nil,
        jsonPointer: String? = nil
    ) -> Self {
        Self(
            projection: .canvas,
            nodeID: nodeID,
            edgeID: edgeID,
            jsonPointer: jsonPointer,
            sourceRange: nil
        )
    }

    public static func outline(nodeID: String, jsonPointer: String? = nil) -> Self {
        Self(
            projection: .outline,
            nodeID: nodeID,
            edgeID: nil,
            jsonPointer: jsonPointer,
            sourceRange: nil
        )
    }
}

public struct DesktopWorkflowDiagnosticFixMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var explanation: String

    public init(id: String, title: String, explanation: String) {
        self.id = id
        self.title = title
        self.explanation = explanation
    }
}

public struct DesktopWorkflowDiagnosticRouteKey: Hashable, Sendable {
    public var code: String
    public var instancePointer: String

    public init(code: String, instancePointer: String) {
        self.code = code
        self.instancePointer = instancePointer
    }
}

public struct DesktopWorkflowDiagnosticPresentation: Identifiable, Equatable, Sendable {
    public var id: String
    public var code: String
    public var severity: DesktopWorkflowDiagnosticSeverity
    public var summary: String
    public var instancePointer: String
    public var schemaPointer: String
    public var focusTarget: DesktopWorkflowDiagnosticFocusTarget
    public var fix: DesktopWorkflowDiagnosticFixMetadata?

    public var accessibilityLabel: String {
        "\(severity.rawValue.capitalized), \(code), \(summary)"
    }
}

public enum DesktopWorkflowDiagnosticMapper {
    public static func presentations(
        response: Kaname_V1_CompileWorkflowResponse,
        routes: [DesktopWorkflowDiagnosticRouteKey: DesktopWorkflowDiagnosticFocusTarget] = [:],
        fixes: [DesktopWorkflowDiagnosticRouteKey: DesktopWorkflowDiagnosticFixMetadata] = [:]
    ) -> [DesktopWorkflowDiagnosticPresentation] {
        response.diagnostics.map { diagnostic in
            let key = DesktopWorkflowDiagnosticRouteKey(
                code: diagnostic.code,
                instancePointer: diagnostic.instancePointer
            )
            let range = sourceRange(diagnostic)
            var target = routes[key] ?? DesktopWorkflowDiagnosticFocusTarget(
                projection: .source,
                jsonPointer: firstNonempty(diagnostic.location.jsonPointer, diagnostic.instancePointer),
                sourceRange: range
            )
            if target.jsonPointer == nil {
                target.jsonPointer = firstNonempty(diagnostic.location.jsonPointer, diagnostic.instancePointer)
            }
            if target.sourceRange == nil {
                target.sourceRange = range
            }
            return DesktopWorkflowDiagnosticPresentation(
                id: stableID(diagnostic),
                code: diagnostic.code,
                severity: severity(diagnostic.severity),
                summary: diagnostic.summary,
                instancePointer: diagnostic.instancePointer,
                schemaPointer: diagnostic.schemaPointer,
                focusTarget: target,
                fix: fixes[key]
            )
        }
        .sorted { lhs, rhs in
            let left = (
                lhs.severity.sortOrder,
                lhs.focusTarget.sourceRange?.sourceID ?? "",
                lhs.focusTarget.sourceRange?.start.byteOffset ?? 0,
                lhs.code,
                lhs.instancePointer,
                lhs.summary
            )
            let right = (
                rhs.severity.sortOrder,
                rhs.focusTarget.sourceRange?.sourceID ?? "",
                rhs.focusTarget.sourceRange?.start.byteOffset ?? 0,
                rhs.code,
                rhs.instancePointer,
                rhs.summary
            )
            return left < right
        }
    }

    private static func severity(
        _ severity: Kaname_V1_WorkflowDiagnosticSeverity
    ) -> DesktopWorkflowDiagnosticSeverity {
        switch severity {
        case .error: .error
        case .warning: .warning
        case .info: .info
        case .unspecified, .UNRECOGNIZED: .unknown
        }
    }

    private static func sourceRange(
        _ diagnostic: Kaname_V1_WorkflowDiagnostic
    ) -> DesktopWorkflowDiagnosticSourceRange? {
        guard diagnostic.hasLocation,
              diagnostic.location.hasStart,
              diagnostic.location.hasEnd else { return nil }
        return DesktopWorkflowDiagnosticSourceRange(
            sourceID: diagnostic.location.sourceID,
            jsonPointer: diagnostic.location.jsonPointer,
            start: .init(
                byteOffset: diagnostic.location.start.byteOffset,
                line: diagnostic.location.start.line,
                column: diagnostic.location.start.column
            ),
            end: .init(
                byteOffset: diagnostic.location.end.byteOffset,
                line: diagnostic.location.end.line,
                column: diagnostic.location.end.column
            )
        )
    }

    private static func stableID(_ diagnostic: Kaname_V1_WorkflowDiagnostic) -> String {
        [
            diagnostic.code,
            diagnostic.instancePointer,
            diagnostic.location.sourceID,
            String(diagnostic.location.start.byteOffset),
            diagnostic.summary,
        ].joined(separator: "\u{001f}")
    }

    private static func firstNonempty(_ values: String...) -> String? {
        values.first { !$0.isEmpty }
    }
}

public enum DesktopWorkflowDiagnosticFocusOutcome: Equatable, Sendable {
    case focused(DesktopWorkflowDiagnosticFocusTarget)
    case targetUnavailable
}

public struct DesktopWorkflowDiagnosticNavigationState: Equatable, Sendable {
    public private(set) var projection: DesktopWorkflowDiagnosticProjection
    public private(set) var selectedDiagnosticID: String?
    public private(set) var selectedNodeID: String?
    public private(set) var selectedEdgeID: String?
    public private(set) var selectedSourceRange: DesktopWorkflowDiagnosticSourceRange?
    public private(set) var selectedJSONPointer: String?
    public private(set) var unresolvedDiagnosticID: String?

    public init(projection: DesktopWorkflowDiagnosticProjection = .canvas) {
        self.projection = projection
    }

    @discardableResult
    public mutating func focus(
        _ diagnostic: DesktopWorkflowDiagnosticPresentation,
        availableNodeIDs: Set<String>,
        availableEdgeIDs: Set<String>
    ) -> DesktopWorkflowDiagnosticFocusOutcome {
        selectedDiagnosticID = diagnostic.id
        let target = diagnostic.focusTarget
        let nodeAvailable = target.nodeID.map(availableNodeIDs.contains) ?? true
        let edgeAvailable = target.edgeID.map(availableEdgeIDs.contains) ?? true
        let hasGraphTarget = target.nodeID != nil || target.edgeID != nil
        let hasSourceTarget = target.sourceRange != nil || target.jsonPointer != nil
        guard nodeAvailable, edgeAvailable,
              target.projection == .source ? hasSourceTarget : hasGraphTarget else {
            unresolvedDiagnosticID = diagnostic.id
            return .targetUnavailable
        }

        projection = target.projection
        selectedNodeID = target.nodeID
        selectedEdgeID = target.edgeID
        selectedSourceRange = target.sourceRange
        selectedJSONPointer = target.jsonPointer
        unresolvedDiagnosticID = nil
        return .focused(target)
    }
}
