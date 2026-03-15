import Foundation
import Security

// SessionDelegate moved to SessionDelegate.swift

actor ClipboardSender {
    // ... (Existing properties)
    private let alias = Host.current().localizedName ?? "Mac Headless"
    private let deviceModel = "macOS"
    private let deviceType = DeviceType.desktop
    private let myFingerprint: String
    
    private let sessionDelegate: SessionDelegate // Keep strong ref
    private let localProtocol: ProtocolType
    private let campusFallback: CampusFallbackCoordinator?
    
    init(
        fingerprint: String,
        localProtocol: ProtocolType = .https,
        campusFallback: CampusFallbackCoordinator? = nil
    ) {
        self.myFingerprint = fingerprint
        self.localProtocol = localProtocol
        self.campusFallback = campusFallback
        self.sessionDelegate = SessionDelegate()
    }

    private func makeSession(requestTimeout: TimeInterval,
                             resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        config.httpShouldUsePipelining = false
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }

    private func formattedHost(for device: Device) -> String {
        if device.ip.contains(":") && !device.ip.hasPrefix("[") {
            return "[\(device.ip)]"
        }
        return device.ip
    }

    private func buildURL(for device: Device, scheme: String, path: String) -> URL? {
        URL(string: "\(scheme)://\(formattedHost(for: device)):\(device.port)\(path)")
    }

    private struct CurlHTTPResult {
        let statusCode: Int
        let body: Data
    }

    private func writeTemporaryData(_ data: Data, suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airsend-clipboard-\(UUID().uuidString).\(suffix)")
        try data.write(to: url)
        return url
    }

    private func performCurlRequest(url: String,
                                    method: String,
                                    headers: [String],
                                    bodyFile: URL? = nil,
                                    timeout: TimeInterval) async throws -> CurlHTTPResult {
        let responseFile = FileManager.default.temporaryDirectory.appendingPathComponent("airsend-clipboard-response-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: responseFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")

        var arguments = [
            "-sS",
            "-k",
            "--http1.1",
            "--connect-timeout", String(max(1, Int(ceil(min(timeout, 4))))),
            "--max-time", String(max(1, Int(ceil(timeout)))),
            "--output", responseFile.path,
            "--write-out", "%{http_code}",
            "-X", method
        ]

        for header in headers {
            arguments.append(contentsOf: ["-H", header])
        }

        if let bodyFile {
            arguments.append(contentsOf: ["--data-binary", "@\(bodyFile.path)"])
        }

        arguments.append(url)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let terminationStatus: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let body = (try? Data(contentsOf: responseFile)) ?? Data()

        if terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "curl failed"
            throw NSError(domain: "ClipboardSenderCurl", code: Int(terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
        }

        let statusCode = Int(String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
        return CurlHTTPResult(statusCode: statusCode, body: body)
    }

    private func probeReachability(to device: Device, scheme: String) async throws {
        guard let url = buildURL(for: device, scheme: scheme, path: "/api/localsend/v2/info") else {
            throw NSError(domain: "ClipboardSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid probe URL"])
        }

        let response = try await performCurlRequest(
            url: url.absoluteString,
            method: "GET",
            headers: [
                "User-Agent: LocalSend/3.0.1",
                "Connection: close"
            ],
            timeout: 4.0
        )

        guard 200..<300 ~= response.statusCode else {
            throw NSError(domain: "ClipboardSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Probe failed for \(scheme.uppercased())"])
        }
    }

    private func isTransientTransportError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorTimedOut
                || nsError.code == NSURLErrorNetworkConnectionLost
                || nsError.code == NSURLErrorNotConnectedToInternet
        }
        if nsError.domain == "ClipboardSenderCurl" {
            return nsError.code == 28
        }
        return false
    }

    private func shouldFallbackScheme(for device: Device, preferredScheme: String, after error: Error) -> Bool {
        if !device.https {
            return true
        }
        guard preferredScheme == "https" else {
            return true
        }
        return !isTransientTransportError(error)
    }

    private func shouldRetryPrepare(after error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorCannotConnectToHost
                || nsError.code == NSURLErrorNetworkConnectionLost
                || nsError.code == NSURLErrorNotConnectedToInternet
                || nsError.code == NSURLErrorTimedOut
        }
        if nsError.domain == "ClipboardSenderCurl" {
            return nsError.code == 28
        }
        return false
    }

    private func resolveReachableScheme(for device: Device, preferredScheme: String) async throws -> String {
        let fallbackScheme = preferredScheme == "https" ? "http" : "https"
        var lastError: Error?

        let preferredAttempts = (device.https && preferredScheme == "https") ? 3 : 2

        for attempt in 1...preferredAttempts {
            do {
                try await probeReachability(to: device, scheme: preferredScheme)
                if attempt == 1 {
                    logTransfer("✅ Clipboard preflight passed via \(preferredScheme.uppercased()) for \(device.alias)")
                } else {
                    logTransfer("✅ Clipboard preflight recovered via \(preferredScheme.uppercased()) for \(device.alias) on retry \(attempt)/\(preferredAttempts)")
                }
                return preferredScheme
            } catch {
                lastError = error
                logTransfer("⚠️ Clipboard preflight \(preferredScheme.uppercased()) failed for \(device.alias) [attempt \(attempt)/\(preferredAttempts)]: \(error.localizedDescription)")
                if attempt < preferredAttempts && isTransientTransportError(error) {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                break
            }
        }

        if let fallbackTriggerError = lastError, shouldFallbackScheme(for: device, preferredScheme: preferredScheme, after: fallbackTriggerError) {
            do {
                try await probeReachability(to: device, scheme: fallbackScheme)
                logTransfer("🔁 Clipboard preflight switched to \(fallbackScheme.uppercased()) for \(device.alias)")
                return fallbackScheme
            } catch {
                lastError = error
                logTransfer("⚠️ Clipboard preflight \(fallbackScheme.uppercased()) failed for \(device.alias): \(error.localizedDescription)")
            }
        }

        throw lastError ?? NSError(domain: "ClipboardSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Peer preflight failed"])
    }

    func sendText(_ text: String, to device: Device) async throws {
        let preferredScheme = device.https ? "https" : "http"
        sessionDelegate.expectedFingerprints[device.ip] = device.id
        do {
            let resolvedScheme = try await resolveReachableScheme(for: device, preferredScheme: preferredScheme)
            try await internalSend(text: text, to: device, scheme: resolvedScheme)
        } catch {
            guard let campusFallback else { throw error }
            logTransfer("⚠️ Direct text send failed for \(device.alias), switching to campus multicast fallback: \(error.localizedDescription)")
            try await campusFallback.sendText(text, to: device)
        }
    }

    // 🚀 新增：发送图片数据
    func sendImage(_ imageData: Data, to device: Device) async throws {
        let preferredScheme = device.https ? "https" : "http"
        sessionDelegate.expectedFingerprints[device.ip] = device.id
        let screenshotName = "Mac_Screenshot_\(Int(Date().timeIntervalSince1970)).png"
        do {
            let resolvedScheme = try await resolveReachableScheme(for: device, preferredScheme: preferredScheme)
            try await internalSendImage(imageData: imageData, to: device, scheme: resolvedScheme)
        } catch {
            guard let campusFallback else { throw error }
            logTransfer("⚠️ Direct image send failed for \(device.alias), switching to campus multicast fallback: \(error.localizedDescription)")
            let fallbackLimit = CampusFallbackCoordinator.maximumPayloadBytes
            guard imageData.count <= fallbackLimit else {
                throw NSError(
                    domain: "CampusFallback",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Direct image send failed and campus fallback only supports files up to \(fallbackLimit) bytes"]
                )
            }
            try await campusFallback.sendFile(
                data: imageData,
                fileName: screenshotName,
                fileType: "image/png",
                to: device
            )
        }
    }

    private func internalSendImage(imageData: Data, to device: Device, scheme: String) async throws {
        let host = formattedHost(for: device)
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
        
        let infoDto = RegisterDto(alias: alias, version: "3.0.1", deviceModel: deviceModel, deviceType: deviceType.rawValue, fingerprint: myFingerprint, macAddress: LocalNetworkIdentity.primaryHardwareAddress(), port: Int(NetworkPorts.transferPort), protocolType: localProtocol.rawValue, download: true)
        
        let requestDto = PrepareUploadRequestDto(info: infoDto, files: [fileId: fileDto])
        let bodyFile = try writeTemporaryData(try JSONEncoder().encode(requestDto), suffix: "json")
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        
        var response: CurlHTTPResult?
        var lastError: Error?
        var activeScheme = scheme

        for attempt in 1...2 {
            do {
                let activeURLString = "\(activeScheme)://\(host):\(device.port)/api/localsend/v2/prepare-upload"
                response = try await performCurlRequest(
                    url: activeURLString,
                    method: "POST",
                    headers: [
                        "Content-Type: application/json",
                        "User-Agent: LocalSend/3.0.1",
                        "Connection: close"
                    ],
                    bodyFile: bodyFile,
                    timeout: 20.0
                )
                break
            } catch {
                lastError = error
                if attempt < 2 && shouldRetryPrepare(after: error) {
                    logTransfer("♻️ Clipboard image prepare failed for \(device.alias): \(error.localizedDescription). Re-probing peer and retrying once...")
                    activeScheme = try await resolveReachableScheme(for: device, preferredScheme: activeScheme)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                throw error
            }
        }

        guard let response else {
            throw lastError ?? NSError(domain: "ClipboardSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Clipboard image prepare failed"])
        }

        if response.statusCode == 200 {
            let responseDto = try JSONDecoder().decode(PrepareUploadResponseDto.self, from: response.body)
            if let token = responseDto.files[fileId] {
                // 协议复用，调用现成的上传函数，只是把 body 换成 Data
                try await uploadImageFile(imageData, to: device, fileId: fileId, token: token, sessionId: responseDto.sessionId, scheme: activeScheme)
            }
        }
    }

    private func uploadImageFile(_ imageData: Data, to device: Device, fileId: String, token: String, sessionId: String, scheme: String) async throws {
        let host = formattedHost(for: device)
        let urlString = "\(scheme)://\(host):\(device.port)/api/localsend/v2/upload?sessionId=\(sessionId)&fileId=\(fileId)&token=\(token)"
        
        let bodyFile = try writeTemporaryData(imageData, suffix: "bin")
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        let _ = try await performCurlRequest(
            url: urlString,
            method: "POST",
            headers: [
                "Content-Type: application/octet-stream",
                "User-Agent: LocalSend/3.0.1",
                "Connection: close"
            ],
            bodyFile: bodyFile,
            timeout: 120.0
        )
    }

    private func internalSend(text: String, to device: Device, scheme: String) async throws {
        let host = formattedHost(for: device)
        
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
            version: "3.0.1",
            deviceModel: deviceModel,
            deviceType: deviceType.rawValue,
            fingerprint: myFingerprint,
            macAddress: LocalNetworkIdentity.primaryHardwareAddress(),
            port: Int(NetworkPorts.transferPort),
            protocolType: localProtocol.rawValue,
            download: true
        )
        
        let requestDto = PrepareUploadRequestDto(
            info: infoDto,
            files: [fileId: fileDto]
        )
        
        let bodyFile = try writeTemporaryData(try JSONEncoder().encode(requestDto), suffix: "json")
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        var response: CurlHTTPResult?
        var lastError: Error?
        var activeScheme = scheme

        for attempt in 1...2 {
            do {
                let activeURLString = "\(activeScheme)://\(host):\(device.port)/api/localsend/v2/prepare-upload"
                logTransfer("📝 Clipboard prepare sending to \(activeURLString) [attempt \(attempt)/2]")
                response = try await performCurlRequest(
                    url: activeURLString,
                    method: "POST",
                    headers: [
                        "Content-Type: application/json",
                        "User-Agent: LocalSend/3.0.1",
                        "Connection: close"
                    ],
                    bodyFile: bodyFile,
                    timeout: 20.0
                )
                break
            } catch {
                lastError = error
                if attempt < 2 && shouldRetryPrepare(after: error) {
                    logTransfer("♻️ Clipboard text prepare failed for \(device.alias): \(error.localizedDescription). Re-probing peer and retrying once...")
                    activeScheme = try await resolveReachableScheme(for: device, preferredScheme: activeScheme)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                throw error
            }
        }

        guard let response else {
            throw lastError ?? NSError(domain: "ClipboardSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Clipboard text prepare failed"])
        }

        logTransfer("📥 Clipboard prepare response (\(activeScheme)): \(response.statusCode)")
        if let responseStr = String(data: response.body, encoding: .utf8) {
            logTransfer("📥 Clipboard response body: \(responseStr)")
        }
        
        if response.statusCode == 200 || response.statusCode == 204 {
            if response.statusCode == 200 {
                let decoder = JSONDecoder()
                do {
                    let responseDto = try decoder.decode(PrepareUploadResponseDto.self, from: response.body)
                    if let token = responseDto.files[fileId] {
                        logTransfer("📤 Clipboard upload starting for \(device.alias)")
                        try await uploadTextFile(text, to: device, fileId: fileId, token: token, sessionId: responseDto.sessionId, scheme: activeScheme)
                    } else {
                        logTransfer("ℹ️ Clipboard prepare completed without upload for \(device.alias)")
                    }
                } catch {
                    logTransfer("❌ Clipboard response decode failed: \(error.localizedDescription)")
                    throw error
                }
            } else {
                logTransfer("✅ Clipboard receiver returned 204 for \(device.alias)")
            }
        } else {
             throw NSError(domain: "ClipboardSender", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Request failed with status \(response.statusCode)"])
        }
    }
    
    private func uploadTextFile(_ text: String, to device: Device, fileId: String, token: String, sessionId: String, scheme: String) async throws {
        let host = formattedHost(for: device)
        let urlString = "\(scheme)://\(host):\(device.port)/api/localsend/v2/upload?sessionId=\(sessionId)&fileId=\(fileId)&token=\(token)"
        
        logTransfer("📤 Clipboard uploading to \(urlString)")

        let bodyFile = try writeTemporaryData(text.data(using: .utf8) ?? Data(), suffix: "txt")
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        let response = try await performCurlRequest(
            url: urlString,
            method: "POST",
            headers: [
                "Content-Type: application/octet-stream",
                "User-Agent: LocalSend/3.0.1",
                "Connection: close"
            ],
            bodyFile: bodyFile,
            timeout: 120.0
        )
        logTransfer("📥 Clipboard upload response: \(response.statusCode)")
    }
}
