import Foundation

public struct KanameID: Codable, Comparable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public static func < (lhs: KanameID, rhs: KanameID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
