import CryptoKit
import Foundation

/// Derives stable task identity for sources that do not carry their own ID.
///
/// Hooks supply `session_id` / `turn_id`; the Doubao trajectory supplies neither.
/// Both fold through the same length-prefixed scheme so a component can never be
/// forged by concatenating the others (e.g. `["ab", "c"]` != `["a", "bc"]`).
public enum IdentityDigest {
    public static func digest(namespace: String, components: [String]) -> String {
        SHA256.hash(data: identityData(namespace: namespace, components: components))
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func uuid(namespace: String, components: [String]) -> UUID {
        uuid(bytes: Array(SHA256.hash(data: identityData(namespace: namespace, components: components)).prefix(16)))
    }

    public static func uuid(bytes: [UInt8]) -> UUID {
        UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func identityData(namespace: String, components: [String]) -> Data {
        Data(([namespace] + components).map { "\($0.utf8.count):\($0)" }.joined().utf8)
    }
}
