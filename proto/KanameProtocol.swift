/// Non-authoritative client preflight for the request shape enforced by the Rust ingress.
public enum WorkflowProtocolClientPreflight {
    public static let maximumRequestIDBytes = 128

    public static func acceptsRequestID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= maximumRequestIDBytes else {
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
