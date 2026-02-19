import Foundation

struct InfoDto: Codable {
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: DeviceType?
    let fingerprint: String?
    let download: Bool?
}

struct RegisterDto: Codable {
    let alias: String
    let version: String?
    let deviceModel: String?
    let deviceType: DeviceType?
    let fingerprint: String
    let port: Int?
    let protocolType: ProtocolType?
    let download: Bool?
    
    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download
        case protocolType = "protocol"
    }
}

struct FileDto: Codable {
    let id: String
    let fileName: String
    let size: Int64
    let fileType: String // e.g., "image/jpeg"
    let sha256: String?
    let preview: String? // Base64 preview?
}

struct PrepareUploadRequestDto: Codable {
    let info: RegisterDto
    let files: [String: FileDto] // Map fileId -> FileDto
}

struct PrepareUploadResponseDto: Codable {
    let sessionId: String
    let files: [String: String] // Map fileId -> token
}
