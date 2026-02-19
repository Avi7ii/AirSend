import Foundation

enum ProtocolType: String, Codable {
    case http
    case https
}

enum DeviceType: String, Codable {
    case mobile
    case desktop
    case web
    case headless
    case server
    case tablet
}

struct MulticastDto: Codable {
    let alias: String
    let version: String // v2, format: major.minor
    let deviceModel: String?
    let deviceType: DeviceType? // nullable since v2
    let fingerprint: String
    let port: Int? // v2
    let protocolType: ProtocolType? // v2, mapped from 'protocol'
    let download: Bool? // v2
    let announcement: Bool? // v1
    let announce: Bool? // v2

    enum CodingKeys: String, CodingKey {
        case alias
        case version
        case deviceModel
        case deviceType
        case fingerprint
        case port
        case protocolType = "protocol"
        case download
        case announcement
        case announce
    }
}
