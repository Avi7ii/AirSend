import Foundation
import Network

actor FileSender {
    private let alias = Host.current().localizedName ?? "Mac Headless"
    private let deviceModel = "macOS"
    private let deviceType = DeviceType.desktop
    private let myFingerprint: String
    
    private let sessionDelegate: SessionDelegate
    private let localProtocol: ProtocolType
    private let campusFallback: CampusFallbackCoordinator?
    
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
    private var activeProcesses: [Process] = []
    private var isCancelled = false

    init(
        fingerprint: String,
        localProtocol: ProtocolType = .https,
        campusFallback: CampusFallbackCoordinator? = nil
    ) {
        self.myFingerprint = fingerprint
        self.localProtocol = localProtocol
        self.campusFallback = campusFallback
        let delegate = SessionDelegate()
        self.sessionDelegate = delegate
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
    func cancelCurrentTransfer() async {
        logTransfer("🛑 [FileSender] cancelCurrentTransfer called. isCancelled: \(isCancelled), activeSessions count: \(activeSessions.count), activeProcesses count: \(activeProcesses.count)")
        isCancelled = true
        for session in activeSessions {
            logTransfer("🛑 [FileSender] Invalidating and cancelling an active URLSession...")
            session.invalidateAndCancel()
        }
        for process in activeProcesses where process.isRunning {
            logTransfer("🛑 [FileSender] Terminating active curl process...")
            process.terminate()
        }
        activeSessions.removeAll()
        activeProcesses.removeAll()
        if let campusFallback {
            await campusFallback.cancelAllOutgoingTransfers()
        }
        logTransfer("🛑 [FileSender] All uploads cancelled by user/system")
        onCancelled?()
    }
    
    private func updateGlobalProgress() {
        guard totalBytes > 0 else { return }
        let totalSent = sentBytesMap.values.reduce(0, +)
        let progress = min(Double(totalSent) / Double(totalBytes), 1.0)
        onProgress?(progress)
    }

    private func updateFallbackProgress(fileId: String, sentBytes: Int64) {
        sentBytesMap[fileId] = sentBytes
        updateGlobalProgress()
    }

    private func makeSession(requestTimeout: TimeInterval,
                             resourceTimeout: TimeInterval,
                             delegate: SessionDelegate? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        config.httpShouldUsePipelining = false
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: delegate ?? sessionDelegate, delegateQueue: nil)
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

    private func probeReachability(to device: Device, scheme: String) async throws {
        guard let url = buildURL(for: device, scheme: scheme, path: "/api/localsend/v2/info") else {
            throw NSError(domain: "FileSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid probe URL"])
        }

        let response = try await performCurlRequest(
            url: url.absoluteString,
            method: "GET",
            headers: [
                "User-Agent: LocalSend/3.5.0",
                "Connection: close"
            ],
            timeout: 4.0
        )

        guard 200..<300 ~= response.statusCode else {
            throw NSError(domain: "FileSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Probe failed for \(scheme.uppercased())"])
        }
    }

    private func isTransientTransportError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorTimedOut
                || nsError.code == NSURLErrorNetworkConnectionLost
                || nsError.code == NSURLErrorNotConnectedToInternet
        }
        if nsError.domain == "FileSenderCurl" {
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

    private func resolveReachableScheme(for device: Device, preferredScheme: String) async throws -> String {
        let fallbackScheme = preferredScheme == "https" ? "http" : "https"
        var lastError: Error?

        let preferredAttempts = (device.https && preferredScheme == "https") ? 3 : 2

        for attempt in 1...preferredAttempts {
            do {
                try await probeReachability(to: device, scheme: preferredScheme)
                if attempt == 1 {
                    logTransfer("✅ Data-plane preflight passed via \(preferredScheme.uppercased()) for \(device.alias)")
                } else {
                    logTransfer("✅ Data-plane preflight recovered via \(preferredScheme.uppercased()) for \(device.alias) on retry \(attempt)/\(preferredAttempts)")
                }
                return preferredScheme
            } catch {
                lastError = error
                logTransfer("⚠️ Preflight \(preferredScheme.uppercased()) failed for \(device.alias) [attempt \(attempt)/\(preferredAttempts)]: \(error.localizedDescription)")
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
                logTransfer("🔁 Data-plane preflight switched to \(fallbackScheme.uppercased()) for \(device.alias)")
                return fallbackScheme
            } catch {
                lastError = error
                logTransfer("⚠️ Preflight \(fallbackScheme.uppercased()) failed for \(device.alias): \(error.localizedDescription)")
            }
        }

        throw lastError ?? NSError(domain: "FileSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Peer preflight failed"])
    }

    private func shouldRetryPrepare(after error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorCannotConnectToHost
                || nsError.code == NSURLErrorNetworkConnectionLost
                || nsError.code == NSURLErrorNotConnectedToInternet
                || nsError.code == NSURLErrorTimedOut
        }
        if nsError.domain == "FileSenderCurl" {
            return nsError.code == 28
        }
        return false
    }

    private func performPrepareRequest(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url else {
            throw NSError(domain: "FileSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid prepare URL"])
        }

        let bodyFile = try writeTemporaryData(request.httpBody ?? Data(), suffix: "json")
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        let response = try await performCurlRequest(
            url: url.absoluteString,
            method: "POST",
            headers: [
                "Content-Type: application/json",
                "Accept: application/json",
                "User-Agent: LocalSend/3.5.0",
                "Connection: close"
            ],
            bodyFile: bodyFile,
            timeout: 30.0
        )
        return (response.body, response.statusCode)
    }
    
    func sendFiles(_ urls: [URL], to device: Device) async throws {
        let preferredScheme = device.https ? "https" : "http"
        logTransfer("🚀 Starting sendFiles to \(device.alias) (\(device.ip)) using preferred \(preferredScheme)")
        
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
        sessionDelegate.expectedFingerprints[device.ip] = device.id
        
        do {
            let resolvedScheme = try await resolveReachableScheme(for: device, preferredScheme: preferredScheme)
            try await internalSend(context: context, to: device, scheme: resolvedScheme)
        } catch {
            guard let campusFallback else {
                throw error
            }
            logTransfer("⚠️ Direct file send failed for \(device.alias), switching to campus multicast fallback: \(error.localizedDescription)")
            let fallbackLimit = CampusFallbackCoordinator.maximumPayloadBytes
            for (fileId, fileDto) in context.fileDtos {
                guard let fileURL = context.fileMap[fileId] else { continue }
                guard fileDto.size <= Int64(fallbackLimit) else {
                    throw NSError(
                        domain: "CampusFallback",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Direct file send failed and campus fallback only supports files up to \(fallbackLimit) bytes"]
                    )
                }
                let data = try Data(contentsOf: fileURL)
                try await campusFallback.sendFile(
                    data: data,
                    fileName: fileDto.fileName,
                    fileType: fileDto.fileType,
                    to: device,
                    onAccepted: onAccepted,
                    onProgress: { [weak self] progress in
                        Task {
                            await self?.updateFallbackProgress(
                                fileId: fileId,
                                sentBytes: Int64(Double(fileDto.size) * progress)
                            )
                        }
                    }
                )
                updateFallbackProgress(fileId: fileId, sentBytes: fileDto.size)
            }
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

    private func registerProcess(_ process: Process) {
        activeProcesses.append(process)
    }

    private func unregisterProcess(_ process: Process) {
        activeProcesses.removeAll { $0 === process }
    }

    private struct CurlHTTPResult {
        let statusCode: Int
        let body: Data
    }

    private struct Header {
        let name: String
        let value: String

        init(_ line: String) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            self.name = String(parts.first ?? "")
            self.value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        }
    }

    private func writeTemporaryData(_ data: Data, suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airsend-\(UUID().uuidString).\(suffix)")
        try data.write(to: url)
        return url
    }

    private func performCurlRequest(url: String,
                                    method: String,
                                    headers: [String],
                                    bodyFile: URL? = nil,
                                    timeout: TimeInterval) async throws -> CurlHTTPResult {
        let responseFile = FileManager.default.temporaryDirectory.appendingPathComponent("airsend-response-\(UUID().uuidString).tmp")
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

        registerProcess(process)
        defer { unregisterProcess(process) }

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
            throw NSError(domain: "FileSenderCurl", code: Int(terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
        }

        let statusCode = Int(String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
        return CurlHTTPResult(statusCode: statusCode, body: body)
    }

    private func performURLSessionUpload(url: URL,
                                         headers: [String],
                                         bodyFile: URL,
                                         fileId: String,
                                         fileSize: Int64,
                                         device: Device,
                                         timeout: TimeInterval) async throws -> CurlHTTPResult {
        let delegate = SessionDelegate()
        delegate.expectedFingerprints[device.ip] = device.id
        delegate.onProgress = { [weak self] _, totalBytesSent, _ in
            Task {
                await self?.updateSentBytes(fileId: fileId, sent: min(totalBytesSent, fileSize))
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        for header in headers.map(Header.init) where !header.name.isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let session = makeSession(requestTimeout: timeout, resourceTimeout: timeout, delegate: delegate)
        registerSession(session)
        defer {
            unregisterSession(session)
            session.finishTasksAndInvalidate()
        }

        let (data, response) = try await session.upload(for: request, fromFile: bodyFile)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return CurlHTTPResult(statusCode: statusCode, body: data)
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
        let host = formattedHost(for: device)
        
        // 1. Prepare DTOs from context
        let fileDtos = context.fileDtos
        let fileMap = context.fileMap
        
        // Pass fingerprint for verification
        sessionDelegate.expectedFingerprints[device.ip] = device.id
        
        // 临时文件清理已移至 sendFiles 的 defer 中，避免 HTTPS→HTTP 重试时文件被提前删除
        
        guard !fileDtos.isEmpty else {
            logTransfer("⚠️ No valid files to send")
            throw NSError(
                domain: "FileSender",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No valid local files to send"]
            )
        }
        
        let infoDto = RegisterDto(
            alias: alias,
            version: "3.5.0",
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
            files: fileDtos
        )
        
        // 2. Send Prepare Request
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let bodyData = try encoder.encode(requestDto)
        
        if let jsonString = String(data: bodyData, encoding: .utf8) {
            logTransfer("📝 Prepare Request Body:\n\(jsonString)")
        }
        
        var activeScheme = scheme
        var lastError: Error?
        var data: Data = Data()
        var prepareStatusCode: Int?

        for attempt in 1...2 {
            let prepareUrlString = "\(activeScheme)://\(host):\(device.port)/api/localsend/v2/prepare-upload"
            guard let prepareUrl = URL(string: prepareUrlString) else {
                throw NSError(domain: "FileSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid prepare URL"])
            }

            var request = URLRequest(url: prepareUrl)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("LocalSend/3.5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("close", forHTTPHeaderField: "Connection")
            request.timeoutInterval = 30.0
            request.httpBody = bodyData

            do {
                logTransfer("📡 Sending prepare to \(prepareUrlString) [attempt \(attempt)/2]")
                let result = try await performPrepareRequest(request)
                data = result.0
                prepareStatusCode = result.1
                logTransfer("📥 Handshake received response: \(result.1)")
                break
            } catch {
                lastError = error
                if attempt < 2 && shouldRetryPrepare(after: error) {
                    logTransfer("♻️ Prepare transport failed: \(error.localizedDescription). Re-probing peer and retrying once...")
                    activeScheme = try await resolveReachableScheme(for: device, preferredScheme: activeScheme)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                logTransfer("❌ Prepare request failed: \(error.localizedDescription)")
                throw error
            }
        }

        guard let prepareStatusCode = prepareStatusCode else {
             logTransfer("❌ Prepare failed: Timeout or persistent error: \(lastError?.localizedDescription ?? "Unknown")")
             throw lastError ?? NSError(domain: "FileSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Handshake timeout"])
        }
        
        logTransfer("📥 Prepare response status: \(prepareStatusCode)")
        
        if prepareStatusCode == 200 || prepareStatusCode == 204 {
             onAccepted?()
             if prepareStatusCode == 204 {
                 logTransfer("✅ Receiver finished without requesting files (204)")
                 return
             }
            
            let decoder = JSONDecoder()
            let responseDto = try decoder.decode(PrepareUploadResponseDto.self, from: data)
            let uploadScheme = activeScheme
            
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
                        try await self.uploadFile(url: fileUrl, to: device, fileId: fileId, token: token, sessionId: responseDto.sessionId, scheme: uploadScheme)
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
             logTransfer("❌ Prepare declined: \(prepareStatusCode)")
             throw NSError(domain: "FileSender", code: prepareStatusCode, userInfo: [NSLocalizedDescriptionKey: "Request declined: \(prepareStatusCode)"])
        }
    }
    
    private func uploadFile(url: URL, to device: Device, fileId: String, token: String, sessionId: String, scheme: String) async throws {
        let host = formattedHost(for: device)
        let urlString = "\(scheme)://\(host):\(device.port)/api/localsend/v2/upload?sessionId=\(sessionId)&fileId=\(fileId)&token=\(token)"
        
        // Get file size without loading into memory
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(resourceValues.fileSize ?? 0)
        
        logTransfer("📦 File to upload: \(url.path), size: \(fileSize) bytes")
        logTransfer("⬆️ Uploading \(fileId) (\(fileSize) bytes) to \(urlString)")
        
        // Check if cancelled before starting
        guard !isCancelled else {
            throw NSError(domain: "FileSender", code: -999, userInfo: [NSLocalizedDescriptionKey: "Transfer cancelled"])
        }

        guard let uploadURL = URL(string: urlString) else {
            throw NSError(domain: "FileSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }

        let response = try await performURLSessionUpload(
            url: uploadURL,
            headers: [
                "Content-Type: application/octet-stream",
                "User-Agent: LocalSend/3.5.0",
                "Connection: close"
            ],
            bodyFile: url,
            fileId: fileId,
            fileSize: fileSize,
            device: device,
            timeout: 180.0
        )

        logTransfer("📥 Upload response for \(fileId): HTTP \(response.statusCode)")
        
        if response.statusCode >= 200 && response.statusCode < 300 {
            logTransfer("✅ Upload complete for \(fileId)")
            updateSentBytes(fileId: fileId, sent: fileSize)
        } else {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            logTransfer("❌ Upload failed for \(fileId): HTTP \(response.statusCode) - \(body)")
            throw NSError(domain: "FileSender", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Upload failed: HTTP \(response.statusCode)"])
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
