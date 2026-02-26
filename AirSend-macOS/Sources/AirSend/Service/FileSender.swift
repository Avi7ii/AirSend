import Foundation
import Network

actor FileSender {
    private let alias = Host.current().localizedName ?? "Mac Headless"
    private let deviceModel = "macOS"
    private let deviceType = DeviceType.desktop
    private let myFingerprint: String
    
    private let session: URLSession
    private let sessionDelegate: SessionDelegate
    private let localProtocol: ProtocolType
    
    // Callback for progress: (overallProgress 0.0-1.0)
    var onProgress: (@Sendable (Double) -> Void)?
    // Callback when receiver clicks "Accept"
    var onAccepted: (@Sendable () -> Void)?
    // Callback when transfer is cancelled
    var onCancelled: (@Sendable () -> Void)?
    
    // Progress tracking
    private var totalBytes: Int64 = 0
    private var sentBytesMap: [String: Int64] = [:]
    
    // Active upload sessions (for cancellation)
    private var activeSessions: Set<URLSession> = []
    private var isCancelled = false

    init(fingerprint: String, localProtocol: ProtocolType = .https) {
        self.myFingerprint = fingerprint
        self.localProtocol = localProtocol
        let delegate = SessionDelegate()
        self.sessionDelegate = delegate
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45 
        config.timeoutIntervalForResource = 86400 
        
        // LIMIT to 1 connection per host to ensure maximum stability and avoid H2 multiplexing issues
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = true
        config.httpShouldUsePipelining = false
        
        // CRITICAL: Bypass system proxy (Clash etc.) for local network communication
        config.connectionProxyDictionary = [:]
        
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    
    func setOnProgress(_ callback: @escaping @Sendable (Double) -> Void) {
        self.onProgress = callback
    }
    
    func setOnAccepted(_ callback: @escaping @Sendable () -> Void) {
        self.onAccepted = callback
    }
    
    func setOnCancelled(_ callback: @escaping @Sendable () -> Void) {
        self.onCancelled = callback
    }
    
    /// Cancel the current upload immediately
    /// Cancel the current upload immediately
    func cancelCurrentTransfer() {
        logTransfer("🛑 [FileSender] cancelCurrentTransfer called. isCancelled: \(isCancelled), activeSessions count: \(activeSessions.count)")
        isCancelled = true
        for session in activeSessions {
            logTransfer("🛑 [FileSender] Invalidating and cancelling an active URLSession...")
            session.invalidateAndCancel()
        }
        activeSessions.removeAll()
        logTransfer("🛑 [FileSender] All uploads cancelled by user/system")
        onCancelled?()
    }
    
    private func updateGlobalProgress() {
        guard totalBytes > 0 else { return }
        let totalSent = sentBytesMap.values.reduce(0, +)
        let progress = min(Double(totalSent) / Double(totalBytes), 1.0)
        onProgress?(progress)
    }
    
    func sendFiles(_ urls: [URL], to device: Device) async throws {
        let preferredScheme = device.https ? "https" : "http"
        logTransfer("🚀 Starting sendFiles to \(device.alias) (\(device.ip)) using \(preferredScheme)")
        
        let context = try await prepareContext(urls: urls)
        
        // 清理临时文件（必须在 sendFiles 层 defer，不能放 internalSend 里，
        // 否则 HTTPS→HTTP 回退时临时文件会被提前删除）
        defer {
            for url in context.tempFiles {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        // Reset progress tracking
        self.totalBytes = context.fileDtos.values.reduce(0) { $0 + $1.size }
        self.sentBytesMap = [:]
        self.isCancelled = false
        
        do {
            try await internalSend(context: context, to: device, scheme: preferredScheme)
        } catch {
            let nsErr = error as NSError
            // CRITICAL: If we are cancelled, or connection is lost/refused mid-transfer, do NOT retry.
            // -999: Cancelled
            // -1005: Network connection lost (often on peer cancel)
            // -1004: Connection refused (peer closed server)
            // -9816: SSL Handshake closed (common with certificate/cancel issues)

            // CRITICAL CHANGE: Treat Connection Lost (-1005) and Timeout (-1001) as explicit CANCEL by peer
            // when we are already deep in the transfer.
            if nsErr.code == NSURLErrorNetworkConnectionLost || nsErr.code == NSURLErrorTimedOut {
                 logTransfer("🛑 [FileSender] Network lost/timeout detected (-1005/-1001). Assuming PEER CANCELLED.")
                 isCancelled = true // Mark as cancelled internally so UI shows "Cancelled" instead of "Error"
                 onCancelled?()     // Trigger cancellation callback immediately
                 throw error        // Stop retry loop
            }

            let isFatalForRetry = isCancelled || 
                                 nsErr.code == NSURLErrorCancelled || 
                                 nsErr.code == NSURLErrorCannotConnectToHost ||
                                 nsErr.code == -9816
            
            if isFatalForRetry {
                logTransfer("🛑 [FileSender] Transfer stopped during \(preferredScheme) phase. Code: \(nsErr.code), isCancelled: \(isCancelled). Error: \(nsErr.localizedDescription)")
                throw error
            }
            
            logTransfer("⚠️ Failed with \(preferredScheme): \(error)")
            let fallbackScheme = (preferredScheme == "http") ? "https" : "http"
            logTransfer("🔄 Retrying with \(fallbackScheme)...")
            try await internalSend(context: context, to: device, scheme: fallbackScheme)
        }
    }
    
    private struct SendContext {
        let fileDtos: [String: FileDto]
        let fileMap: [String: URL]
        let tempFiles: [URL]
    }
    
    // Track session in actor
    private func registerSession(_ session: URLSession) {
        activeSessions.insert(session)
    }
    
    private func unregisterSession(_ session: URLSession) {
        activeSessions.remove(session)
    }
    
    private func prepareContext(urls: [URL]) async throws -> SendContext {
        var fileDtos: [String: FileDto] = [:]
        var fileMap: [String: URL] = [:]
        var tempFiles: [URL] = []
        
        for url in urls {
            let fileId = UUID().uuidString
            fileMap[fileId] = url
            
            let resources = try url.resourceValues(forKeys: [.fileSizeKey, .nameKey, .contentTypeKey])
            let fileName = resources.name ?? url.lastPathComponent
            
            var isDir: ObjCBool = false
            var finalUrl = url
            var isTemp = false
            
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                logTransfer("📂 Directory detected: \(fileName). Zipping...")
                if let zipUrl = zipDirectory(at: url) {
                    finalUrl = zipUrl
                    isTemp = true
                } else {
                    logTransfer("❌ Failed to zip directory: \(fileName)")
                    continue
                }
            }
            
            let finalResources = try finalUrl.resourceValues(forKeys: [.fileSizeKey, .nameKey, .contentTypeKey])
            let finalFileSize = Int64(finalResources.fileSize ?? 0)
            let finalFileName = finalResources.name ?? finalUrl.lastPathComponent
            let finalFileType = finalFileName.hasSuffix(".zip") ? "application/zip" : (finalResources.contentType?.identifier ?? "application/octet-stream")

            let fileDto = FileDto(
                id: fileId,
                fileName: finalFileName,
                size: finalFileSize,
                fileType: finalFileType,
                sha256: nil,
                preview: nil
            )
            fileDtos[fileId] = fileDto
            fileMap[fileId] = finalUrl
            
            if isTemp {
                 tempFiles.append(finalUrl)
            }
        }
        return SendContext(fileDtos: fileDtos, fileMap: fileMap, tempFiles: tempFiles)
    }
    
    private func internalSend(context: SendContext, to device: Device, scheme: String) async throws {
        var host = device.ip
        if host.contains(":") && !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        
        // 1. Prepare DTOs from context
        let fileDtos = context.fileDtos
        let fileMap = context.fileMap
        
        // Pass fingerprint for verification
        sessionDelegate.expectedFingerprints[device.ip] = device.id
        
        // 临时文件清理已移至 sendFiles 的 defer 中，避免 HTTPS→HTTP 重试时文件被提前删除
        
        guard !fileDtos.isEmpty else {
            logTransfer("⚠️ No valid files to send")
            return
        }
        
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
            files: fileDtos
        )
        
        // 2. Send Prepare Request
        let prepareUrlString = "\(scheme)://\(host):\(device.port)/api/localsend/v2/prepare-upload"
        guard let prepareUrl = URL(string: prepareUrlString) else { return }
        
        var request = URLRequest(url: prepareUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LocalSend/2.1", forHTTPHeaderField: "User-Agent")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.timeoutInterval = 60.0 // Give user 60s to click "Accept"
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let bodyData = try encoder.encode(requestDto)
        request.httpBody = bodyData
        
        if let jsonString = String(data: bodyData, encoding: .utf8) {
            logTransfer("📝 Prepare Request Body:\n\(jsonString)")
        }
        
        logTransfer("📡 Sending prepare to \(prepareUrlString)")
        
        let startTime = Date()
        var lastError: Error?
        var handshakeSuccessful = false
        var data: Data = Data()
        var httpResponse: HTTPURLResponse?

        // Retry Loop for Prepare Phase (Handshake)
        // We ONLY retry if we fail to establish a connection (phone offline/locked).
        // Once a request is successfully waiting for a response, we stop retrying and let it wait.
        while Date().timeIntervalSince(startTime) < 120.0 && !handshakeSuccessful {
            do {
                logTransfer("📡 Attempting handshake...")
                let (receivedData, response) = try await session.data(for: request, delegate: sessionDelegate)
                if let res = response as? HTTPURLResponse {
                    data = receivedData
                    httpResponse = res
                    handshakeSuccessful = true
                    logTransfer("📥 Handshake received response: \(res.statusCode)")
                }
            } catch {
                lastError = error
                let nsError = error as NSError
                
                // Retry only on connection-level errors
                if nsError.domain == NSURLErrorDomain && 
                   (nsError.code == NSURLErrorCannotConnectToHost || 
                    nsError.code == NSURLErrorTimedOut || 
                    nsError.code == NSURLErrorNotConnectedToInternet) {
                    
                    logTransfer("📡 Connection failed (\(nsError.code)): \(error.localizedDescription). Retrying in 2s...")
                    try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                } else {
                    // If it's a cancelled error or other non-retryable error, fail immediately
                    logTransfer("❌ Stop retrying due to fatal error: \(error.localizedDescription)")
                    throw error
                }
            }
        }

        guard handshakeSuccessful, let httpResponse = httpResponse else {
             logTransfer("❌ Prepare failed: Timeout or persistent error: \(lastError?.localizedDescription ?? "Unknown")")
             throw lastError ?? NSError(domain: "FileSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Handshake timeout"])
        }
        
        logTransfer("📥 Prepare response status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
             onAccepted?()
             if httpResponse.statusCode == 204 {
                 logTransfer("✅ Receiver finished without requesting files (204)")
                 return
             }
            
            let decoder = JSONDecoder()
            let responseDto = try decoder.decode(PrepareUploadResponseDto.self, from: data)
            
            // 3. Upload Files with Concurrency Control
            let maxConcurrency = 3
            try await withThrowingTaskGroup(of: Void.self) { group in
                var uploadedCount = 0
                let fileEntries = Array(responseDto.files)
                
                for entry in fileEntries {
                    let fileId = entry.key
                    let token = entry.value
                    guard let fileUrl = fileMap[fileId] else { continue }
                    
                    group.addTask {
                        logTransfer("📤 Starting concurrent upload for \(fileUrl.lastPathComponent) (ID: \(fileId))...")
                        try await self.uploadFile(url: fileUrl, to: device, fileId: fileId, token: token, sessionId: responseDto.sessionId, scheme: scheme)
                    }
                    
                    uploadedCount += 1
                    // Simple throttling: if we reach maxConcurrency, wait for one to finish before adding more
                    if uploadedCount >= maxConcurrency {
                        try await group.next()
                        uploadedCount -= 1
                    }
                }
                
                // Wait for any remaining files to finish
                try await group.waitForAll()
            }
            
            logTransfer("🎉 All files sent successfully to \(device.alias)")
            
        } else {
             logTransfer("❌ Prepare declined: \(httpResponse.statusCode)")
             throw NSError(domain: "FileSender", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Request declined: \(httpResponse.statusCode)"])
        }
    }
    
    private func uploadFile(url: URL, to device: Device, fileId: String, token: String, sessionId: String, scheme: String) async throws {
        var host = device.ip
        if host.contains(":") && !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        let urlString = "\(scheme)://\(host):\(device.port)/api/localsend/v2/upload?sessionId=\(sessionId)&fileId=\(fileId)&token=\(token)"
        
        guard let uploadUrl = URL(string: urlString) else {
            throw NSError(domain: "FileSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }
        
        // Get file size without loading into memory
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(resourceValues.fileSize ?? 0)
        
        logTransfer("📦 File to upload: \(url.path), size: \(fileSize) bytes")
        logTransfer("⬆️ Uploading \(fileId) (\(fileSize) bytes) to \(urlString)")
        
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        request.setValue("LocalSend/2.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300
        
        // Create a dedicated upload session with performance tuning
        let uploadConfig = URLSessionConfiguration.default
        uploadConfig.timeoutIntervalForRequest = 60
        uploadConfig.timeoutIntervalForResource = 86400
        uploadConfig.waitsForConnectivity = true
        // CRITICAL: Bypass system proxy for local network
        uploadConfig.connectionProxyDictionary = [:]
        
        // Check if cancelled before starting
        guard !isCancelled else {
            throw NSError(domain: "FileSender", code: -999, userInfo: [NSLocalizedDescriptionKey: "Transfer cancelled"])
        }
        
        // 读取文件数据到内存
        // URLSession.upload(for:fromFile:) 在某些配置下会发送 Content-Length: 0
        let fileData = try Data(contentsOf: url)
        logTransfer("📦 Loaded file data into memory: \(fileData.count) bytes")
        request.httpBody = fileData
        
        let uploadDelegate = SessionDelegate()
        uploadDelegate.expectedFingerprints = sessionDelegate.expectedFingerprints
        uploadDelegate.onProgress = { [weak self] task, totalBytesSent, totalBytesExpectedToSend in
            Task { [weak self] in
                await self?.updateSentBytes(fileId: fileId, sent: totalBytesSent)
            }
        }
        
        let uploadSession = URLSession(configuration: uploadConfig, delegate: uploadDelegate, delegateQueue: nil)
        registerSession(uploadSession)
        
        defer {
            uploadSession.finishTasksAndInvalidate()
            unregisterSession(uploadSession)
        }
        
                // 使用 data(for:) + httpBody 发送，确保 Content-Length 正确
                let (data, response) = try await uploadSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "FileSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        logTransfer("📥 Upload response for \(fileId): HTTP \(httpResponse.statusCode)")
        
        if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
            logTransfer("✅ Upload complete for \(fileId)")
            updateSentBytes(fileId: fileId, sent: fileSize)
        } else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logTransfer("❌ Upload failed for \(fileId): HTTP \(httpResponse.statusCode) - \(body)")
            throw NSError(domain: "FileSender", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Upload failed: HTTP \(httpResponse.statusCode)"])
        }
    }

    private func updateSentBytes(fileId: String, sent: Int64) {
        sentBytesMap[fileId] = sent
        updateGlobalProgress()
    }
    
    private func zipDirectory(at url: URL) -> URL? {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let zipFileName = url.lastPathComponent + ".zip"
        let zipUrl = tempDir.appendingPathComponent(zipFileName)
        
        try? fileManager.removeItem(at: zipUrl)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-y", zipUrl.path, url.lastPathComponent]
        process.currentDirectoryURL = url.deletingLastPathComponent()
        
        let pipe = Pipe()
        process.standardError = pipe
        
        do {
            try process.run()
        } catch {
            logTransfer("❌ zip process failed to launch: \(error)")
            return nil
        }
        process.waitUntilExit()
        
        let stderrData = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
        if !stderrStr.isEmpty {
            logTransfer("⚠️ zip stderr: \(stderrStr)")
        }
        
        if process.terminationStatus == 0 {
            let attrs = try? fileManager.attributesOfItem(atPath: zipUrl.path)
            let size = attrs?[.size] as? Int64 ?? 0
            logTransfer("📦 zip exit: \(process.terminationStatus), output: \(zipUrl.path), size: \(size) bytes")
            return zipUrl
        }
        logTransfer("❌ zip failed with exit code: \(process.terminationStatus)")
        return nil
    }
}
