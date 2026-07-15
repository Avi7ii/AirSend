import Foundation

enum AirSendAppMetadata {
    static var version: String {
        let value = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "development" : normalized
    }
}
