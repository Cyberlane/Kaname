/// Non-authoritative client preflight for Link identifiers. The Rust gateway
/// remains authoritative and checks identity, membership, capability, space,
/// action, object, sequence, and size on every request.
public enum KanameLinkProtocolClientPreflight {
    public static let maximumIdentifierBytes = 128

    public static func acceptsIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= maximumIdentifierBytes else {
            return false
        }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"),
                 UInt8(ascii: "."), UInt8(ascii: ":"):
                true
            default:
                false
            }
        }
    }
}
