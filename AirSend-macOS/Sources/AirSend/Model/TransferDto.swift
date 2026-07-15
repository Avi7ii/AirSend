import Foundation

struct InfoDto: Codable, Sendable {
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String?
    let download: Bool?
}

struct RegisterDto: Codable, Sendable {
    let alias: String
    let version: String?
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String
    let macAddress: String?
    let port: Int?
    let protocolType: String?
    let download: Bool?
    
    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, macAddress, port, download
        case protocolType = "protocol"
    }
}

struct FileDto: Codable, Sendable {
    let id: String
    let fileName: String
    let size: Int64
    let fileType: String // e.g., "image/jpeg"
    let sha256: String?
    let preview: String? // Base64 preview?
}

struct PrepareUploadRequestDto: Codable, Sendable {
    let info: RegisterDto
    let files: [String: FileDto] // Map fileId -> FileDto
}

struct PrepareUploadResponseDto: Codable, Sendable {
    let sessionId: String
    let files: [String: String] // Map fileId -> token
}
