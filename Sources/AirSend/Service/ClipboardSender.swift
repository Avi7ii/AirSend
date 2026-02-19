import Foundation
import Security

// SessionDelegate moved to SessionDelegate.swift

actor ClipboardSender {
    // ... (Existing properties)
    private let alias = Host.current().localizedName ?? "Mac Headless"
    private let deviceModel = "macOS"
    private let deviceType = DeviceType.desktop
    private let myFingerprint: String
    
    // Custom session
    private let session: URLSession
    private let sessionDelegate: SessionDelegate // Keep strong ref
    private let localProtocol: ProtocolType
    
    init(fingerprint: String, localProtocol: ProtocolType = .http) {
        self.myFingerprint = fingerprint
        self.localProtocol = localProtocol
        self.sessionDelegate = SessionDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5 // Short timeout
        self.session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }

    func sendText(_ text: String, to device: Device) async throws {
        // Try preferred scheme first
        let preferredScheme = device.https ? "https" : "http"
        do {
            try await internalSend(text: text, to: device, scheme: preferredScheme)
        } catch {
            print("Failed with \(preferredScheme): \(error)")
            // Fallback trial
            let fallbackScheme = (preferredScheme == "http") ? "https" : "http"
            print("Retrying with \(fallbackScheme)...")
            try await internalSend(text: text, to: device, scheme: fallbackScheme)
        }
    }

    private func internalSend(text: String, to device: Device, scheme: String) async throws {
        var host = device.ip
        if host.contains(":") && !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        
        let urlString = "\(scheme)://\(host):\(device.port)/api/localsend/v2/prepare-upload"
        
        guard let url = URL(string: urlString) else { 
            print("Invalid URL string: \(urlString)")
            return 
        }
        
        print("Prepare sending to \(urlString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // ... (DTO values)
        let fileId = UUID().uuidString
        let fileSize = Int64(text.utf8.count)
        
        let fileDto = FileDto(
            id: fileId,
            fileName: "\(Int(Date().timeIntervalSince1970)).txt",
            size: fileSize,
            fileType: "text/plain",
            sha256: nil,
            preview: text
        )
        
        let infoDto = RegisterDto(
            alias: alias,
            version: "2.1",
            deviceModel: deviceModel,
            deviceType: deviceType,
            fingerprint: myFingerprint,
            port: 53317,
            protocolType: localProtocol,
            download: true
        )
        
        let requestDto = PrepareUploadRequestDto(
            info: infoDto,
            files: [fileId: fileDto]
        )
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestDto)
        
        // Use session with delegate for self-signed certs
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            print("Prepare response (\(scheme)): \(httpResponse.statusCode)")
            if let responseStr = String(data: data, encoding: .utf8) {
                print("Response body: \(responseStr)")
            }
            
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                if httpResponse.statusCode == 200 {
                    let decoder = JSONDecoder()
                    do {
                        let responseDto = try decoder.decode(PrepareUploadResponseDto.self, from: data)
                        if let token = responseDto.files[fileId] {
                            print("Uploading file content...")
                            try await uploadTextFile(text, to: device, fileId: fileId, token: token, sessionId: responseDto.sessionId, scheme: scheme)
                        } else {
                            print("No upload required")
                        }
                    } catch {
                        print("Failed to decode response: \(error)")
                    }
                } else {
                    print("Receiver returned 204")
                }
            } else {
                 throw NSError(domain: "ClipboardSender", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Request failed with status \(httpResponse.statusCode)"])
            }
        }
    }
    
    private func uploadTextFile(_ text: String, to device: Device, fileId: String, token: String, sessionId: String, scheme: String) async throws {
        var host = device.ip
        if host.contains(":") && !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        let urlString = "\(scheme)://\(host):\(device.port)/api/localsend/v2/upload?sessionId=\(sessionId)&fileId=\(fileId)&token=\(token)"
        
        guard let url = URL(string: urlString) else { 
            print("Invalid Upload URL: \(urlString)")
            return 
        }
        
        print("Uploading to \(urlString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = text.data(using: .utf8)
        
        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse {
            print("Upload response: \(httpResponse.statusCode)")
        }
    }
}
