import Foundation

/// Keeps desktop Back ownership independent from transient SwiftUI bridge views.
@MainActor
public final class DesktopBackCommandRouter {
    public static let shared = DesktopBackCommandRouter()

    private var handler: (() -> Bool)?

    public init() {}

    public func install(_ handler: @escaping () -> Bool) {
        self.handler = handler
    }

    public func removeHandler() {
        handler = nil
    }

    @discardableResult
    public func performBack() -> Bool {
        handler?() ?? false
    }
}
