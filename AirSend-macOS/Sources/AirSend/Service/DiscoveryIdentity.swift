import Foundation

enum DiscoveryIdentity {
    static func fingerprintsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedFingerprint(lhs)
        let right = normalizedFingerprint(rhs)
        return !left.isEmpty && left == right
    }

    private static func normalizedFingerprint(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
