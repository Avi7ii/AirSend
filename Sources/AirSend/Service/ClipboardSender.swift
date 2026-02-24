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
    
    init(fingerprint: String, localProtocol: ProtocolType = .https) {
        self.myFingerprint = fingerprint
        self.localProtocol = localProtocol
        self.sessionDelegate = SessionDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5 // Short timeout
        self.session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }

    func sendText(_ text: String, to device: Device) async throws {
        let preferredScheme = device.https ? "https" : "http"
        do {
            try await internalSend(text: text, to: device, scheme: preferredScheme)
        } catch {
            print("Failed with \(preferredScheme): \(error)")
            let fallbackScheme = (preferredScheme == "http") ? "https" : "http"
            try await internalSend(text: text, to: device, scheme: fallbackScheme)
        }
    }

    // 🚀 新增：发送图片数据
    func sendImage(_ imageData: Data, to device: Device) async throws {
        let preferredScheme = device.https ? "https" : "http"
        do {
            try await internalSendImage(imageData: imageData, to: device, scheme: preferredScheme)
        } catch {
            print("Failed with \(preferredScheme): \(error)")
            let fallbackScheme = (preferredScheme == "http") ? "https" : "http"
            try await internalSendImage(imageData: imageData, to: device, scheme: fallbackScheme)
        }
    }

    private func internalSendImage(imageData: Data, to device: Device, scheme: String) async throws {
        var host = device.ip
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
        let urlString = "\(scheme)://\(host):\(device.port)/api/localsend/v2/prepare-upload"
        
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let fileId = UUID().uuidString
        let fileSize = Int64(imageData.count)
        
        // 标记为 image/png，这样 Android 端就会当成图片存盘，而不是剪贴板文本
        let fileDto = FileDto(
            id: fileId,
            fileName: "Mac_Screenshot_\(Int(Date().timeIntervalSince1970)).png",
            size: fileSize,
            fileType: "image/png", 
            sha256: nil,
            preview: nil
        )
        
        let infoDto = RegisterDto(alias: alias, version: "2.1", deviceModel: deviceModel, deviceType: deviceType.rawValue, fingerprint: myFingerprint, port: 53317, protocolType: localProtocol.rawValue, download: true)
        
        let requestDto = PrepareUploadRequestDto(info: infoDto, files: [fileId: fileDto])
        request.httpBody = try JSONEncoder().encode(requestDto)
        
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            let responseDto = try JSONDecoder().decode(PrepareUploadResponseDto.self, from: data)
            if let token = responseDto.files[fileId] {
                // 协议复用，调用现成的上传函数，只是把 body 换成 Data
                try await uploadImageFile(imageData, to: device, fileId: fileId, token: token, sessionId: responseDto.sessionId, scheme: scheme)
            }
        }
    }

    private func uploadImageFile(_ imageData: Data, to device: Device, fileId: String, token: String, sessionId: String, scheme: String) async throws {
        var host = device.ip
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
        let urlString = "\(scheme)://\(host):\(device.port)/api/localsend/v2/upload?sessionId=\(sessionId)&fileId=\(fileId)&token=\(token)"
        
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = imageData
        
        let _ = try await session.data(for: request)
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
            deviceType: deviceType.rawValue,
            fingerprint: myFingerprint,
            port: 53317,
            protocolType: localProtocol.rawValue,
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
