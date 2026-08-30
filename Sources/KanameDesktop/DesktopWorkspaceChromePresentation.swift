import Foundation

/// Deterministic presentation guidance for the desktop workspace shell.
///
/// The inspector remains a persistent split-view preference at roomy widths,
/// while compact windows expose the same content through a transient popover.
/// Keeping those states separate avoids opening a blocking presentation merely
/// because a restored window became narrow.
public struct DesktopWorkspaceChromePresentation: Equatable, Sendable {
    public enum InspectorPlacement: Equatable, Sendable {
        case hidden
        case split
        case popover
    }

    public enum InspectorToggleAction: Equatable, Sendable {
        case setSplitVisible(Bool)
        case setCompactPopoverPresented(Bool)
    }

    public static let splitInspectorMinimumWidth = 980.0

    public let availableWidth: Double
    public let splitInspectorVisible: Bool
    public let compactInspectorPresented: Bool

    public init(
        availableWidth: Double,
        splitInspectorVisible: Bool,
        compactInspectorPresented: Bool
    ) {
        self.availableWidth = availableWidth.isFinite ? max(0, availableWidth) : 0
        self.splitInspectorVisible = splitInspectorVisible
        self.compactInspectorPresented = compactInspectorPresented
    }

    public var usesCompactLayout: Bool {
        availableWidth < Self.splitInspectorMinimumWidth
    }

    public var inspectorPlacement: InspectorPlacement {
        if usesCompactLayout {
            return compactInspectorPresented ? .popover : .hidden
        }
        return splitInspectorVisible ? .split : .hidden
    }

    public var inspectorToggleAction: InspectorToggleAction {
        if usesCompactLayout {
            return .setCompactPopoverPresented(!compactInspectorPresented)
        }
        return .setSplitVisible(!splitInspectorVisible)
    }

    public var inspectorToggleTitle: String {
        switch inspectorPlacement {
        case .split:
            "Hide Inspector"
        case .popover:
            "Close Inspector"
        case .hidden:
            "Show Inspector"
        }
    }

    public var inspectorToggleSystemImage: String {
        inspectorPlacement == .popover ? "xmark" : "sidebar.right"
    }
}
