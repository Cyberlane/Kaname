public enum KanameTextBounds {
    public static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        var result = String(value.prefix(maximumBytes))
        while result.utf8.count > maximumBytes { result.removeLast() }
        return result
    }
}
