import Foundation

struct Device: Identifiable, Equatable, Hashable, Codable {
    let id: String // fingerprint
    let alias: String
    let ip: String
    let port: Int
    let deviceModel: String?
    let deviceType: DeviceType?
    let version: String
    let https: Bool
    let download: Bool
    
    // Last seen timestamp for purging
    let lastSeen: Date
    
    static func == (lhs: Device, rhs: Device) -> Bool {
        return lhs.id == rhs.id && lhs.ip == rhs.ip
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(ip)
    }
}
