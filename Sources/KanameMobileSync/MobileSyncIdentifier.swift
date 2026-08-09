enum MobileSyncIdentifier {
    static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.utf8.allSatisfy { byte in
                (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || (48...57).contains(byte)
                    || byte == 45
                    || byte == 46
                    || byte == 58
            }
    }
}
