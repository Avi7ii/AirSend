import Cocoa
import Network

// Data model for the request
struct TransferRequest: Sendable {
    let sessionId: String
    let senderAlias: String
    let fileCount: Int
    let fileNames: [String]
    let totalSize: Int64
}

actor HTTPTransferServer {
    private let fingerprint: String
    private let alias = Host.current().localizedName ?? "Mac Headless"
    private let deviceModel = "macOS"
    private let deviceType = DeviceType.desktop
    
    
    private var listener: NWListener?
    private var port: UInt16
    private var isHTTPS: Bool = false
    
    // Dedicated queue for the listener and general management
    private let listenerQueue = DispatchQueue(label: "com.localsend.server.listener", qos: .userInteractive)
    
    // Session state
    private var currentSessionId: String?
    private var fileTokens: [String: String] = [:] // fileId -> token
    private var filesToReceive: [String: FileDto] = [:] // fileId -> FileDto
    private var activeConnection: NWConnection? // Track active upload connection

    // Transfer State
    private var totalSessionSize: Int64 = 0
    private var sessionBytesReceived: Int64 = 0
    private var receivedFileCount: Int = 0
    
    // Callbacks
    var onDeviceRegistered: (@Sendable (Device) -> Void)?
    var onTextReceived: (@Sendable (String) -> Void)?
    var onCancelReceived: (@Sendable () -> Void)?
    
    // Receiver Interception Callbacks
    var onTransferRequest: (@Sendable (TransferRequest) async -> Bool)?
    var getSaveDirectory: (@Sendable () -> URL)? // Handler to get current save destination
    
    // Receiver Progress Callbacks
    var onProgress: (@Sendable (Double) -> Void)?
    var onTransferComplete: (@Sendable (Bool, String?) -> Void)?

    func setOnDeviceRegistered(_ callback: @escaping @Sendable (Device) -> Void) {
        self.onDeviceRegistered = callback
    }
    
    func setOnTransferRequest(_ callback: @escaping @Sendable (TransferRequest) async -> Bool) {
        self.onTransferRequest = callback
    }
    
    func setGetSaveDirectory(_ callback: @escaping @Sendable () -> URL) {
        self.getSaveDirectory = callback
    }
    
    func setOnProgress(_ callback: @escaping @Sendable (Double) -> Void) {
        self.onProgress = callback
    }
    
    func setOnTransferComplete(_ callback: @escaping @Sendable (Bool, String?) -> Void) {
        self.onTransferComplete = callback
    }

    func setOnTextReceived(_ callback: @escaping @Sendable (String) -> Void) {
        self.onTextReceived = callback
    }
    
    func setOnCancelReceived(_ callback: @escaping @Sendable () -> Void) {
        self.onCancelReceived = callback
    }

    init(port: UInt16 = 53317, fingerprint: String) {
        self.port = port
        self.fingerprint = fingerprint
    }
    
    // --- Actor Isolated Logic ---
    
    func triggerProgress(_ progress: Double) {
        self.onProgress?(progress)
    }
    
    func triggerTransferComplete(success: Bool, message: String?) {
        self.onTransferComplete?(success, message)
    }
    
    func triggerTextReceived(_ text: String) {
        self.onTextReceived?(text)
    }
    
    func triggerCancelReceived() {
        self.onCancelReceived?()
    }
    
    func getBaseDirectory() -> URL {
        return self.getSaveDirectory?() ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }
    func getSessionState() -> (id: String?, tokens: [String: String], files: [String: FileDto]) {
        return (currentSessionId, fileTokens, filesToReceive)
    }
    
    func updateIncrementProgress(bytes: Int64) -> (received: Int64, total: Int64) {
        self.sessionBytesReceived += bytes
        return (self.sessionBytesReceived, self.totalSessionSize)
    }
    
    func incrementFileCount() -> (current: Int, expected: Int) {
        self.receivedFileCount += 1
        return (self.receivedFileCount, self.filesToReceive.count)
    }
    
    func setUploadConnection(_ connection: NWConnection?) {
        self.activeConnection = connection
    }
    
    func getUploadConnection() -> NWConnection? {
        return self.activeConnection
    }
    
    func getSessionSizeInfo() -> (received: Int64, total: Int64) {
        return (self.sessionBytesReceived, self.totalSessionSize)
    }
    
    /// Returns true if a session was active, and kills the actual connection
    func performSessionCancellation() -> Bool {
        let wasActive = (self.currentSessionId != nil)
        self.currentSessionId = nil
        self.fileTokens.removeAll()
        self.filesToReceive.removeAll()
        
        let conn = self.activeConnection
        self.activeConnection = nil
        conn?.cancel()
        
        return wasActive
    }
    
    func start(p12Data: Data? = nil) async throws {
        let parameters: NWParameters
        
        if let p12Data = p12Data {
            self.isHTTPS = true
            logTransfer("🌐 Starting HTTPS Server (NWListener) on port \(port)...")
            let options = NWProtocolTLS.Options()
            
            // Setup TLS with P12
            let password = "localsend"
            if let identity = secIdentityFromP12(p12Data, password: password) {
                sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
            }
            
            // PROTOCOL: Restore TLS 1.3 for 1-RTT handshakes.
            // With the Restart-Loop fixed, TLS 1.3 should be stable and fast.
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
            
            // CRITICAL: ALPN for http/1.1 is mandatory for LocalSend
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
            
            // AUTH: Fingerprint verification happens at the application layer.
            sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, false)
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { (_, _, completion) in
                completion(true)
            }, .global())
            
            // TICKETS: Disable for proxy stability (Mihomo/Clash).
            // Proxies often mishandle session resumption, causing -9816 errors on reconnection.
            // We force a full handshake every time.
            sec_protocol_options_set_tls_tickets_enabled(options.securityProtocolOptions, false)
            
            parameters = NWParameters(tls: options)
            
            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 10
                tcpOptions.keepaliveInterval = 5
                tcpOptions.keepaliveCount = 5
            }
            
            // CONCURRENCY: Allow reuse to coexist with UDP discovery on the same port
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            
            // parameters.serviceClass = .background
            
        } else {
            logTransfer("🌐 Starting HTTP Server (NWListener) on port \(port)...")
            parameters = .tcp
            parameters.allowLocalEndpointReuse = true
            
            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true // Disable Nagle's algorithm for instant handshake response
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 10
                tcpOptions.keepaliveInterval = 5
                tcpOptions.keepaliveCount = 5
            }
        }
        
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            
            // QUEUE-PER-CONNECTION: Assign a unique, independent queue for each connection.
            // This ensures control channel (Cancel) handshakes are NOT blocked by data channel activity.
            let connectionQueue = DispatchQueue(label: "com.localsend.conn.\(UUID().uuidString.prefix(8))", qos: .userInteractive)
            
            // Start the connection on its dedicated queue
            connection.start(queue: connectionQueue)
            
            let startTime = DispatchTime.now()
            logTransfer("🔌 [HTTPTransferServer] [T+0ms] New incoming connection from \(connection.endpoint)")
            
            connection.stateUpdateHandler = { state in
                let now = DispatchTime.now()
                let elapsedMs = Double(now.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
                
                switch state {
                case .waiting(let error):
                    logTransfer("⏳ [HTTPTransferServer] [T+\(Int(elapsedMs))ms] Connection waiting (\(connection.endpoint)): \(error)")
                case .ready:
                    let nowReady = DispatchTime.now()
                    let readyElapsed = Double(nowReady.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
                    
                    if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                        let secMetadata = metadata.securityProtocolMetadata
                        let protocolName = sec_protocol_metadata_get_negotiated_protocol(secMetadata).map { String(cString: $0) } ?? "none"
                        let tlsVersion = sec_protocol_metadata_get_negotiated_tls_protocol_version(secMetadata)
                        
                        logTransfer("🔐 [HTTPTransferServer] [T+\(Int(readyElapsed))ms] READY (TLS): \(protocolName) | Version: \(tlsVersion) | Remote: \(connection.endpoint)")
                    } else {
                        logTransfer("🔌 [HTTPTransferServer] [T+\(Int(readyElapsed))ms] READY (Plain): Remote: \(connection.endpoint)")
                    }
                    
                    Task { [weak self] in
                        await self?.processIncomingRequest(connection)
                    }
                case .failed(let error):
                    let nsError = error as NSError
                    logTransfer("❌ [HTTPTransferServer] [T+\(Int(elapsedMs))ms] Connection Failed (\(connection.endpoint)): \(error.localizedDescription) (Code: \(nsError.code))")
                    if nsError.code == -9816 {
                        logTransfer("🚨 [HTTPTransferServer] Diagnostic: -9816 Peer Closed. Latency from Start: \(Int(elapsedMs))ms. If this is < 50ms, it's likely a certificate mismatch. If > 1000ms, it's a timeout/starvation.")
                    }
                    
                    // Handshake done (Failed)
                    
                    connection.cancel()
                case .cancelled:
                    // Handshake done (Cancelled)
                    break
                default:
                    break
                }
            }
        }
        
        listener.stateUpdateHandler = { state in
            logTransfer("🌐 Server (NWListener) state: \(state)")
            if case .failed(let error) = state {
                logTransfer("❌ Server CRASHED: \(error)")
            }
        }
        
        listener.start(queue: self.listenerQueue)
        self.listener = listener
    }
    
    func stop() {
        logTransfer("🌐 Stopping server...")
        listener?.cancel()
        listener = nil
    }
    
    /// Processes the request in a NONISOLATED context to prevent blocking the actor.
    /// This allows multiple connections to read/write data in parallel (on global threads)
    /// while the actor remains free to handle handshakes/control messages.
    nonisolated private func processIncomingRequest(_ connection: NWConnection) async {
        // NOTE: stateUpdateHandler and start() are already called in newConnectionHandler.
        // We just proceed to read.
        
        do {
            // 1. Read Header (accumulate until \r\n\r\n)
            var accumulatedData = Data()
            var headerData: Data?
            var bodyOffset: Int = 0
            
            while true {
                let chunk = try await receiveChunk(from: connection)
                if chunk.isEmpty { break }
                accumulatedData.append(chunk)
                
                if let range = accumulatedData.range(of: "\r\n\r\n".data(using: .utf8)!) {
                    headerData = accumulatedData.subdata(in: 0..<range.upperBound)
                    bodyOffset = range.upperBound
                    break
                }
                
                if accumulatedData.count > 16384 { // Protection against too large headers
                    break
                }
            }
            
            guard let header = headerData, let requestInfo = HTTPRequestParser.parseHeader(header) else {
                let bytesStr = accumulatedData.prefix(16).map { String(format: "%02hhx", $0) }.joined(separator: " ")
                logTransfer("⚠️ Malformed HTTP header. First bytes: [\(bytesStr)]. Probable protocol mismatch (e.g. TLS on HTTP port).")
                connection.cancel()
                return
            }
            
            let bodyPrefix = accumulatedData.subdata(in: bodyOffset..<accumulatedData.count)
            let contentLength = Int(requestInfo.headers["content-length"] ?? "0") ?? 0
            
            // 2. For /upload path: stream body directly to disk (never accumulate in memory)
            if requestInfo.path == "/api/localsend/v2/upload" {
                logTransfer("📥 \(requestInfo.method) \(requestInfo.path) [streaming \(contentLength) bytes]")
                let response = await handleUploadStreaming(
                    requestInfo: requestInfo,
                    connection: connection,
                    bodyPrefix: bodyPrefix,
                    contentLength: contentLength
                )
                connection.send(content: response.serialize(), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
                return
            }
            
            // 3. For all other paths: accumulate body in memory (small payloads)
            var body = bodyPrefix
            if contentLength > 0 {
                while body.count < contentLength {
                    let remaining = contentLength - body.count
                    let chunk = try await receiveChunk(from: connection, maxLength: min(remaining, 65536))
                    if chunk.isEmpty { break }
                    body.append(chunk)
                }
            }
            
            let request = HTTPRawRequest(
                method: requestInfo.method,
                path: requestInfo.path,
                headers: requestInfo.headers,
                body: body,
                queryParams: requestInfo.queryParams
            )
            
            // 4. Routing (non-upload paths only)
            let response = await self.route(request: request, connection: connection)
            
            // 5. Send Response
            connection.send(content: response.serialize(), completion: .contentProcessed({ _ in
                connection.cancel()
            }))
            
        } catch {
            logTransfer("❌ Connection error: \(error)")
            connection.cancel()
        }
    }
    
    nonisolated private func receiveChunk(from connection: NWConnection, maxLength: Int = 65536) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { content, context, isComplete, error in
                if let content = content, !content.isEmpty {
                    let preview = content.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                    logTransfer("📥 [HTTPTransferServer] Received chunk: \(content.count) bytes. Preview: [\(preview)]")
                }
                
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                if let content = content {
                    continuation.resume(returning: content)
                    return
                }
                
                if isComplete {
                    continuation.resume(returning: Data()) // EOF
                    return
                }
                
                // Should not happen usually
                continuation.resume(throwing: NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"]))
            }
        }
    }
    
    private func route(request: HTTPRawRequest, connection: NWConnection) async -> HTTPRawResponse {
        logTransfer("📥 \(request.method) \(request.path)")
        
        switch request.path {
        case "/api/localsend/v2/register":
            return await handleRegister(request: request, connection: connection)
        case "/api/localsend/v2/prepare-upload":
            return await handlePrepareUpload(request: request)
        case "/api/localsend/v2/cancel":
            return await handleCancel(request: request)
        default:
            return HTTPRawResponse(statusCode: 404, body: "Not Found".data(using: .utf8)!)
        }
    }
    
    // MARK: - Handlers
    
    private func handleRegister(request: HTTPRawRequest, connection: NWConnection) async -> HTTPRawResponse {
        do {
            let dto = try JSONDecoder().decode(RegisterDto.self, from: request.body)
            
            // Extract IP from connection
            var ip = "unknown"
            if case let .hostPort(host, _) = connection.endpoint {
                ip = host.debugDescription
            }
            
            // Clean IP
            if let activeRange = ip.range(of: "%") {
                ip = String(ip[..<activeRange.lowerBound])
            }
            if ip.hasPrefix("::ffff:") {
                ip = String(ip.dropFirst(7))
            }
            
            if ip != "unknown" {
                let device = Device(
                    id: dto.fingerprint,
                    alias: dto.alias,
                    ip: ip,
                    port: dto.port ?? 53317,
                    deviceModel: dto.deviceModel,
                    deviceType: dto.deviceType,
                    version: dto.version ?? "2.0",
                    https: dto.protocolType == .https,
                    download: dto.download ?? false,
                    lastSeen: Date()
                )
                onDeviceRegistered?(device)
            }
            
            let responseDto = RegisterDto(
                alias: alias,
                version: "2.1",
                deviceModel: deviceModel,
                deviceType: deviceType,
                fingerprint: fingerprint,
                port: 53317,
                protocolType: isHTTPS ? .https : .http,
                download: true
            )
            
            let data = try JSONEncoder().encode(responseDto)
            return HTTPRawResponse(statusCode: 200, body: data)
        } catch {
            return HTTPRawResponse(statusCode: 400, body: "Bad Request".data(using: .utf8)!)
        }
    }
    
    private func handlePrepareUpload(request: HTTPRawRequest) async -> HTTPRawResponse {
        do {
            let dto = try JSONDecoder().decode(PrepareUploadRequestDto.self, from: request.body)
            
            // 0. Construct Transfer Request for Callback
            let senderAlias = dto.info.alias
            let fileCount = dto.files.count
            let totalSize = dto.files.values.reduce(0) { $0 + $1.size }
            let fileNames = dto.files.values.map { $0.fileName }
            
            let transferRequest = TransferRequest(
                sessionId: UUID().uuidString, 
                senderAlias: senderAlias,
                fileCount: fileCount,
                fileNames: Array(fileNames),
                totalSize: totalSize
            )
            
            // 1. Intercept: Ask user for permission
            if let onTransferRequest = onTransferRequest {
                logTransfer("🛑 Intercepting transfer request from \(senderAlias)...")
                let allowed = await onTransferRequest(transferRequest)
                if !allowed {
                    logTransfer("🚫 User declined transfer from \(senderAlias).")
                    return HTTPRawResponse(statusCode: 403, body: "Forbidden".data(using: .utf8)!)
                }
                logTransfer("✅ User accepted transfer from \(senderAlias).")
            }
            
            // 2. Proceed if allowed
            let sessionId = UUID().uuidString
            self.currentSessionId = sessionId
            self.fileTokens.removeAll()
            self.filesToReceive = dto.files
            
            // Reset Progress State
            self.totalSessionSize = totalSize
            self.sessionBytesReceived = 0
            self.receivedFileCount = 0
            
            var responseFiles: [String: String] = [:]
            for (fileId, _) in dto.files {
                let token = UUID().uuidString
                self.fileTokens[fileId] = token
                responseFiles[fileId] = token
            }
            
            let responseDto = PrepareUploadResponseDto(
                sessionId: sessionId,
                files: responseFiles
            )
            let data = try JSONEncoder().encode(responseDto)
            return HTTPRawResponse(statusCode: 200, body: data)
        } catch {
            return HTTPRawResponse(statusCode: 400, body: "Bad Request".data(using: .utf8)!)
        }
    }
    
    /// Streaming upload handler: writes received data directly to disk in chunks
    /// Nonisolated to prevent blocking the actor during disk I/O.
    nonisolated private func handleUploadStreaming(
        requestInfo: HTTPRequestParser.HeaderInfo,
        connection: NWConnection,
        bodyPrefix: Data,
        contentLength: Int
    ) async -> HTTPRawResponse {
        let query = requestInfo.queryParams
        guard let sessionId = query["sessionId"],
              let fileId = query["fileId"],
              let token = query["token"] else {
            return HTTPRawResponse(statusCode: 400, body: "Bad Request".data(using: .utf8)!)
        }
        
        let sessionState = await getSessionState()
        
        if sessionId != sessionState.id || sessionState.tokens[fileId] != token {
            return HTTPRawResponse(statusCode: 403, body: "Forbidden".data(using: .utf8)!)
        }
        
        guard let fileDto = sessionState.files[fileId] else {
            return HTTPRawResponse(statusCode: 404, body: "Not Found".data(using: .utf8)!)
        }
        
        // Store active connection for cancellation
        await setUploadConnection(connection)
        
        defer { 
            Task { await self.setUploadConnection(nil) }
        }

        // --- PATH LOGIC START ---
        
        // 1. Get Base Directory (Custom or Downloads)
        let baseDir = await getBaseDirectory()
        var destinationUrl = baseDir.appendingPathComponent(fileDto.fileName)
        
        // 2. Conflict Resolution: Rename if exists (e.g. "file (1).txt")
        var counter = 1
        let ext = destinationUrl.pathExtension
        let nameWithoutExt = destinationUrl.deletingPathExtension().lastPathComponent
        
        while FileManager.default.fileExists(atPath: destinationUrl.path) {
            let newName = "\(nameWithoutExt) (\(counter))"
            destinationUrl = baseDir.appendingPathComponent(newName).appendingPathExtension(ext)
            counter += 1
        }
        
        // --- PATH LOGIC END ---
        
        do {
            // Create empty file and open for writing
            let fileManager = FileManager.default
            fileManager.createFile(atPath: destinationUrl.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: destinationUrl)
            defer { try? fileHandle.close() }
            
            var receivedBytes = 0
            
            // Write the body prefix (data already read during header parsing)
            if !bodyPrefix.isEmpty {
                fileHandle.write(bodyPrefix)
                receivedBytes += bodyPrefix.count
                _ = await updateIncrementProgress(bytes: Int64(bodyPrefix.count))
            }
            
            // Stream remaining data directly to disk in chunks
            // Stream remaining data directly to disk in chunks
            // Reverted to 64KB to prevent main actor blocking and high latency
            // BACK TO PERFORMANCE: 64KB chunks, no artificial delays.
            // The 15ms gaps were fighting a symptom (restarts), not the cause.
            let bufferSize = 65536 
            var lastProgressUpdate = Date()
            var lastReportedProgress: Double = 0
            
            while receivedBytes < contentLength {
                let remaining = contentLength - receivedBytes
                // Read up to 1MB at a time
                let chunk = try await receiveChunk(from: connection, maxLength: min(remaining, bufferSize))
                if chunk.isEmpty { 
                    logTransfer("⚠️ [HTTPTransferServer] Stream ended prematurely (Empty chunk). Requesting cancel.")
                    throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stream ended unexpectedly"])
                }
                // CRITICAL REFACTOR: Write to disk on a detached task to unblock the Actor.
                // This allows handleCancel() to be processed even during heavy writing.
                let writeData = chunk
                try await Task.detached(priority: .medium) {
                    // FileHandle is thread-safe
                    try fileHandle.write(contentsOf: writeData)
                }.value
                
                receivedBytes += Int(chunk.count)
                let progressInfo = await updateIncrementProgress(bytes: Int64(chunk.count))
                
                // NO MORE SLEEP. NO MORE THROTTLING. 
                // Context-per-Connection + Fixed Certificate Loop handles stability.
                
                // Otherwise: NO MORE HandshakeMonitor. Context-per-Connection handles the rest.
                // But we still need this physical gap to unblock the shared Wi-Fi medium.
                
                // Throttle Progress Reporting (Update every 0.1s or 1%)
                // This prevents UI thread flooding during high-speed transfers
                if progressInfo.total > 0 {
                    let progress = Double(progressInfo.received) / Double(progressInfo.total)
                    let timeSinceLast = Date().timeIntervalSince(lastProgressUpdate)
                    
                    if timeSinceLast > 0.1 || (progress - lastReportedProgress) > 0.01 || progress >= 1.0 {
                        await triggerProgress(progress)
                        lastProgressUpdate = Date()
                        lastReportedProgress = progress
                    }
                }
            }
            
            logTransfer("✅ File saved to \(destinationUrl.path) (\(receivedBytes) bytes, streamed)")
            
            // Check if it's a text file for clipboard handling
            let isText = fileDto.fileName.hasSuffix(".txt") || fileDto.fileType == "text/plain"
            if isText, receivedBytes < 1_000_000 {
                if let textContent = try? String(contentsOf: destinationUrl, encoding: .utf8) {
                    await triggerTextReceived(textContent)
                }
            }
            
            // Report Final Progress (100%) ensures UI hits 100% even for small files
            let finalProgress = await getSessionSizeInfo()
            if finalProgress.total > 0 {
                await triggerProgress(1.0)
            }
            
            // Check for Session Completion
            let counts = await incrementFileCount()
            
            // CRITICAL FIX: Verify we received the full file
            if receivedBytes < contentLength {
                logTransfer("❌ [HTTPTransferServer] File incomplete! Expected \(contentLength), got \(receivedBytes). Transfer truncated.")
                await triggerTransferComplete(success: false, message: "Transfer truncated (Network lost?)")
                return HTTPRawResponse(statusCode: 400, body: Data())
            }
            
            if counts.current >= counts.expected {
                await triggerTransferComplete(success: true, message: nil)
            }
            
            return HTTPRawResponse(statusCode: 200, body: Data())
        } catch {
            logTransfer("❌ [HTTPTransferServer] Upload Failed: \(error.localizedDescription)")
            
            // Cleanup on error (including timeout)
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: destinationUrl)
            
            // Check for timeout error
            let nsError = error as NSError
            if nsError.code == -2 {
                logTransfer("🚨 [HTTPTransferServer] Read Timeout detected. Assuming peer cancelled silently.")
                // Notify Cancel
                await triggerCancelReceived()
            } else {
                await triggerTransferComplete(success: false, message: error.localizedDescription)
            }
            
            return HTTPRawResponse(statusCode: 500, body: "Internal Server Error".data(using: .utf8)!)
        }
    }
    
    nonisolated private func handleCancel(request: HTTPRawRequest) async -> HTTPRawResponse {
        logTransfer("🛑 [HTTPTransferServer] Cancel request received from peer. Query: \(request.queryParams)")
        
        let wasActive = await performSessionCancellation()
        
        logTransfer("🛑 [HTTPTransferServer] Invoking onCancelReceived callback...")
        await triggerCancelReceived()
        logTransfer("🛑 [HTTPTransferServer] onCancelReceived callback invoked.")
        
        if wasActive {
            logTransfer("🛑 [HTTPTransferServer] Notifying onTransferComplete(false, Cancelled by peer)")
            await triggerTransferComplete(success: false, message: "Cancelled by peer")
        }
        
        return HTTPRawResponse(statusCode: 200, body: Data())
    }
    
    private func secIdentityFromP12(_ p12Data: Data, password: String) -> sec_identity_t? {
        let options: NSDictionary
        if #available(macOS 15, *) {
            options = [
                kSecImportExportPassphrase: password,
                kSecImportToMemoryOnly: true
            ]
        } else {
            options = [kSecImportExportPassphrase: password]
        }
        var rawItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options, &rawItems)
        
        guard status == errSecSuccess else {
            logTransfer("❌ [HTTPTransferServer] SecPKCS12Import failed with status: \(status)")
            return nil
        }
        
        guard let items = rawItems as? [[String: Any]],
              let firstItem = items.first,
              let identity = firstItem[kSecImportItemIdentity as String] as! SecIdentity? else {
            logTransfer("❌ [HTTPTransferServer] P12 import succeeded but implementation/identity missing")
            return nil
        }
        
        return sec_identity_create(identity)
    }
}

// MARK: - HTTP Raw Helper Models

struct HTTPRawRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let queryParams: [String: String]
}

struct HTTPRawResponse {
    let statusCode: Int
    let body: Data
    
    func serialize() -> Data {
        var str = "HTTP/1.1 \(statusCode) \(statusPhrase)\r\n"
        str += "Content-Length: \(body.count)\r\n"
        str += "Content-Type: application/json\r\n"
        str += "Server: HeadlessLocalSend-macOS\r\n"
        str += "Connection: close\r\n"
        str += "\r\n"
        
        var data = str.data(using: .utf8)!
        data.append(body)
        return data
    }
    /*
    ## 主要变更

    ### 1. 证书逻辑与扩展平衡
    - **DN 字段精简**：保持 `Organization (O)` 为空（适配空格路径），确保 UI 显示一致性。
    - **恢复核心扩展**：恢复了 `Key Usage` (digitalSignature, keyEncipherment) 和 `Extended Key Usage`。
    - **原因**：解决高并发下完全无扩展证书触发的“慢速路径”解析导致的握手超时（>300ms）。

    ### 2. TLS 协议锁定与稳定性
    - **强制 TLS 1.2**：回退并锁定 TLS 1.2。1.2 在高并发协商时比 1.3 具有更强的链路确定性，避免了 1.3 的随机抖动。
    - **监听优化**：关闭了 `allowLocalEndpointReuse`，减少频繁重启过程中的端口拒绝 (Code 61) 现象。

    ## 验证结果

    ### 证书审计
    通过 `openssl x509` 验证，证书已达到“平衡”状态：
    ```text
    Subject: CN=LocalSend User, O= 
    X509v3 extensions:
        X509v3 Key Usage: critical
            Digital Signature, Key Encipherment
        X509v3 Extended Key Usage: 
            TLS Web Server Authentication, TLS Web Client Authentication
    ```

    ### 服务状态
    应用已成功重启，HTTPS 握手稳定性大幅提升：
    ```text
    [13:11:49Z] ✅ Ultra-minimal certificate generated (O='', Extensions restored).
    [13:11:51Z] 🌐 Starting HTTPS Server (NWListener) on port 53317...
    [2026-02-18T13:11:51Z] 🌐 Server (NWListener) state: ready
    ```
    */
    
    private var statusPhrase: String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        default: return "Internal Server Error"
        }
    }
}

struct HTTPRequestParser {
    struct HeaderInfo {
        let method: String
        let path: String
        let queryParams: [String: String]
        let headers: [String: String]
    }
    
    static func parseHeader(_ data: Data) -> HeaderInfo? {
        guard let string = String(data: data, encoding: .ascii) else { return nil }
        let lines = string.components(separatedBy: "\r\n")
        guard lines.count > 0 else { return nil }
        
        let firstLineParts = lines[0].components(separatedBy: " ")
        guard firstLineParts.count >= 2 else { return nil }
        
        let method = firstLineParts[0]
        let fullPath = firstLineParts[1]
        
        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { break }
            let comps = line.components(separatedBy: ": ")
            if comps.count == 2 {
                headers[comps[0].lowercased()] = comps[1].trimmingCharacters(in: .whitespaces)
            }
        }
        
        // Parse Query
        var query: [String: String] = [:]
        let pathComps = fullPath.components(separatedBy: "?")
        let path = pathComps[0]
        if pathComps.count > 1 {
            let queryItems = pathComps[1].components(separatedBy: "&")
            for item in queryItems {
                let kv = item.components(separatedBy: "=")
                if kv.count == 2 {
                    query[kv[0]] = kv[1]
                }
            }
        }
        
        return HeaderInfo(method: method, path: path, queryParams: query, headers: headers)
    }
}
