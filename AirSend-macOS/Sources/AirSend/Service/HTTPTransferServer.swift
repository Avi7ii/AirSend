import Cocoa
import Network
import AirSendRuntimeCore
import Darwin

private let maximumControlBodyBytes = 1_048_576
private let receiverSessionIdleTimeout: TimeInterval = 300

struct TransferServerHealthSnapshot: Sendable {
    let isListening: Bool
    let isHTTPS: Bool
    let activeSessionCount: Int
    let listenerState: String
}

// Data model for the request
struct TransferRequest: Sendable {
    let sessionId: String
    let senderAlias: String
    let senderFingerprint: String
    let fileCount: Int
    let fileNames: [String]
    let totalSize: Int64
}

private struct ReceiverSessionState: Sendable {
    let id: String
    let transferID: UUID
    let files: [String: FileDto]
    var availableTokens: [String: String]
    var receivedBytesByFile: [String: Int64]
    var completedFileIDs: Set<String>
    var stagingURLsByFile: [String: URL]
    let stagingDirectory: URL
    let createdAt: Date
    var lastActivityAt: Date

    var totalSize: Int64 {
        files.values.reduce(0) { $0 + max(0, $1.size) }
    }

    var receivedBytes: Int64 {
        min(totalSize, receivedBytesByFile.values.reduce(0, +))
    }
}

private struct ReceiverUploadClaim: Sendable {
    let sessionID: String
    let transferID: UUID
    let fileID: String
    let file: FileDto
    let stagingURL: URL
}

private struct CompletedReceiverSession: Sendable {
    let id: String
    let transferID: UUID
    let files: [String: FileDto]
    let stagingDirectory: URL
    let stagingURLsByFile: [String: URL]
}

actor HTTPTransferServer {
    private let fingerprint: String
    private let alias = Host.current().localizedName ?? "Mac Headless"
    private let deviceModel = "macOS"
    private let deviceType = DeviceType.desktop
    private var macAddress: String? { LocalNetworkIdentity.primaryHardwareAddress() }
    
    
    private var listener: NWListener?
    private var plainCompatServer: PlainHTTPCompatServer?
    private var port: UInt16
    private var isHTTPS: Bool = false
    private let transferCoordinator: TransferCoordinator
    
    // Dedicated queue for the listener and general management
    private let listenerQueue = DispatchQueue(label: "com.localsend.server.listener", qos: .userInteractive)
    
    private var receiverSessions: [String: ReceiverSessionState] = [:]
    private var receiverSessionExpiryTasks: [String: Task<Void, Never>] = [:]
    private var activeConnections: [ObjectIdentifier: (sessionID: String, connection: NWConnection)] = [:]
    private var activeCompatConnections: [Int32: (sessionID: String, connection: PlainHTTPCompatConnection)] = [:]
    
    // Callbacks
    var onDeviceRegistered: (@Sendable (Device) -> Void)?
    var onTextReceived: (@Sendable (String) -> Void)?
    var onCancelReceived: (@Sendable (String) -> Void)?
    private var onHealthChanged: (@Sendable (TransferServerHealthSnapshot) -> Void)?
    
    // Receiver Interception Callbacks
    var onTransferRequest: (@Sendable (TransferRequest) async -> Bool)?
    var getSaveDirectory: (@Sendable (FileDto) -> URL)?
    private var listenerState = "stopped"
    
    // Receiver Progress Callbacks
    var onProgress: (@Sendable (String, Double) -> Void)?
    var onTransferComplete: (@Sendable (String, Bool, String?) -> Void)?

    func setOnDeviceRegistered(_ callback: @escaping @Sendable (Device) -> Void) {
        self.onDeviceRegistered = callback
    }
    
    func setOnTransferRequest(_ callback: @escaping @Sendable (TransferRequest) async -> Bool) {
        self.onTransferRequest = callback
    }
    
    func setGetSaveDirectory(_ callback: @escaping @Sendable (FileDto) -> URL) {
        self.getSaveDirectory = callback
    }
    
    func setOnProgress(_ callback: @escaping @Sendable (String, Double) -> Void) {
        self.onProgress = callback
    }
    
    func setOnTransferComplete(_ callback: @escaping @Sendable (String, Bool, String?) -> Void) {
        self.onTransferComplete = callback
    }

    func setOnTextReceived(_ callback: @escaping @Sendable (String) -> Void) {
        self.onTextReceived = callback
    }
    
    func setOnCancelReceived(_ callback: @escaping @Sendable (String) -> Void) {
        self.onCancelReceived = callback
    }

    func setOnHealthChanged(_ callback: @escaping @Sendable (TransferServerHealthSnapshot) -> Void) {
        onHealthChanged = callback
        callback(healthSnapshot())
    }

    init(
        port: UInt16 = NetworkPorts.transferPort,
        fingerprint: String,
        transferCoordinator: TransferCoordinator = TransferCoordinator()
    ) {
        self.port = port
        self.fingerprint = fingerprint
        self.transferCoordinator = transferCoordinator
    }
    
    // --- Actor Isolated Logic ---
    
    func triggerProgress(sessionID: String, _ progress: Double) {
        self.onProgress?(sessionID, progress)
    }
    
    func triggerTransferComplete(sessionID: String, success: Bool, message: String?) {
        self.onTransferComplete?(sessionID, success, message)
    }
    
    func triggerTextReceived(_ text: String) {
        self.onTextReceived?(text)
    }
    
    func triggerCancelReceived(sessionID: String) {
        self.onCancelReceived?(sessionID)
    }
    
    func getBaseDirectory(for file: FileDto) -> URL {
        getSaveDirectory?(file) ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    func healthSnapshot() -> TransferServerHealthSnapshot {
        TransferServerHealthSnapshot(
            isListening: listener != nil || plainCompatServer != nil,
            isHTTPS: isHTTPS,
            activeSessionCount: receiverSessions.count,
            listenerState: listenerState
        )
    }

    func cancelTransfer(id transferID: UUID) async -> Bool {
        guard let session = receiverSessions.values.first(where: { $0.transferID == transferID }),
              let cancelled = performSessionCancellation(sessionID: session.id) else { return false }
        try? FileManager.default.removeItem(at: cancelled.stagingDirectory)
        _ = try? await transferCoordinator.finishCancelled(id: transferID)
        triggerTransferComplete(sessionID: session.id, success: false, message: "Cancelled locally")
        return true
    }

    private func updateListenerState(_ state: String) {
        listenerState = state
        publishHealthSnapshot()
    }

    private func publishHealthSnapshot() {
        onHealthChanged?(healthSnapshot())
    }

    private func stagingDirectory(for sessionID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AirSend-macOS", isDirectory: true)
            .appendingPathComponent(".incoming-staging", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }
    func addUploadConnection(_ connection: NWConnection, sessionID: String) {
        self.activeConnections[ObjectIdentifier(connection)] = (sessionID, connection)
    }
    
    func removeUploadConnection(_ connection: NWConnection) {
        self.activeConnections.removeValue(forKey: ObjectIdentifier(connection))
    }

    func addUploadConnection(_ connection: PlainHTTPCompatConnection, sessionID: String) {
        self.activeCompatConnections[connection.socket] = (sessionID, connection)
    }

    func removeUploadConnection(_ connection: PlainHTTPCompatConnection) {
        self.activeCompatConnections.removeValue(forKey: connection.socket)
    }
    
    func createReceiverSession(
        id: String,
        transferID: UUID,
        files: [String: FileDto],
        tokens: [String: String],
        stagingDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        receiverSessions[id] = ReceiverSessionState(
            id: id,
            transferID: transferID,
            files: files,
            availableTokens: tokens,
            receivedBytesByFile: [:],
            completedFileIDs: [],
            stagingURLsByFile: [:],
            stagingDirectory: stagingDirectory,
            createdAt: Date(),
            lastActivityAt: Date()
        )
        scheduleReceiverSessionExpiry(sessionID: id, after: receiverSessionIdleTimeout)
    }

    private func claimUpload(sessionID: String, fileID: String, token: String) -> ReceiverUploadClaim? {
        guard var session = receiverSessions[sessionID],
              session.availableTokens[fileID] == token,
              let file = session.files[fileID],
              !session.completedFileIDs.contains(fileID) else {
            return nil
        }
        session.availableTokens.removeValue(forKey: fileID)
        session.lastActivityAt = Date()
        let safeFileID = fileID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let stagingURL = session.stagingDirectory.appendingPathComponent("\(safeFileID.isEmpty ? UUID().uuidString : safeFileID).part")
        session.stagingURLsByFile[fileID] = stagingURL
        receiverSessions[sessionID] = session
        return ReceiverUploadClaim(
            sessionID: sessionID,
            transferID: session.transferID,
            fileID: fileID,
            file: file,
            stagingURL: stagingURL
        )
    }

    func updateProgress(sessionID: String, fileID: String, receivedBytes: Int64) -> (received: Int64, total: Int64, transferID: UUID)? {
        guard var session = receiverSessions[sessionID], let file = session.files[fileID] else { return nil }
        let previous = session.receivedBytesByFile[fileID] ?? 0
        session.receivedBytesByFile[fileID] = min(file.size, max(previous, receivedBytes))
        session.lastActivityAt = Date()
        receiverSessions[sessionID] = session
        return (session.receivedBytes, session.totalSize, session.transferID)
    }

    private func completeUpload(sessionID: String, fileID: String) -> CompletedReceiverSession? {
        guard var session = receiverSessions[sessionID], session.files[fileID] != nil else { return nil }
        session.completedFileIDs.insert(fileID)
        receiverSessions[sessionID] = session
        guard session.completedFileIDs.count == session.files.count else { return nil }
        receiverSessions.removeValue(forKey: sessionID)
        receiverSessionExpiryTasks.removeValue(forKey: sessionID)?.cancel()
        return CompletedReceiverSession(
            id: session.id,
            transferID: session.transferID,
            files: session.files,
            stagingDirectory: session.stagingDirectory,
            stagingURLsByFile: session.stagingURLsByFile
        )
    }

    private func failReceiverSession(sessionID: String) -> ReceiverSessionState? {
        receiverSessionExpiryTasks.removeValue(forKey: sessionID)?.cancel()
        return receiverSessions.removeValue(forKey: sessionID)
    }

    private func performSessionCancellation(sessionID: String) -> ReceiverSessionState? {
        guard let session = receiverSessions.removeValue(forKey: sessionID) else { return nil }
        receiverSessionExpiryTasks.removeValue(forKey: sessionID)?.cancel()
        let connections = activeConnections.filter { $0.value.sessionID == sessionID }
        let compatConnections = activeCompatConnections.filter { $0.value.sessionID == sessionID }
        for key in connections.keys { activeConnections.removeValue(forKey: key) }
        for key in compatConnections.keys { activeCompatConnections.removeValue(forKey: key) }
        connections.values.forEach { $0.connection.cancel() }
        compatConnections.values.forEach { $0.connection.close() }
        return session
    }

    private func scheduleReceiverSessionExpiry(sessionID: String, after delay: TimeInterval) {
        receiverSessionExpiryTasks.removeValue(forKey: sessionID)?.cancel()
        let nanoseconds = UInt64(max(1, delay) * 1_000_000_000)
        receiverSessionExpiryTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.expireReceiverSessionIfIdle(sessionID: sessionID)
        }
    }

    private func expireReceiverSessionIfIdle(sessionID: String) async {
        guard let session = receiverSessions[sessionID] else {
            receiverSessionExpiryTasks.removeValue(forKey: sessionID)?.cancel()
            return
        }
        let idleDuration = Date().timeIntervalSince(session.lastActivityAt)
        if idleDuration < receiverSessionIdleTimeout {
            scheduleReceiverSessionExpiry(
                sessionID: sessionID,
                after: receiverSessionIdleTimeout - idleDuration
            )
            return
        }

        guard let expiredSession = performSessionCancellation(sessionID: sessionID) else { return }
        try? FileManager.default.removeItem(at: expiredSession.stagingDirectory)
        _ = try? await transferCoordinator.finishFailed(
            id: expiredSession.transferID,
            code: "receive_session_timeout",
            message: "Incoming transfer session expired after five minutes without activity",
            retryable: true
        )
        triggerTransferComplete(
            sessionID: sessionID,
            success: false,
            message: "Transfer timed out"
        )
    }
    
    func start(p12Data: Data? = nil) async throws {
        listener?.cancel()
        listener = nil
        plainCompatServer?.stop()
        plainCompatServer = nil
        listenerState = "starting"
        publishHealthSnapshot()

        guard let p12Data = p12Data else {
            self.isHTTPS = false
            let plainServer = PlainHTTPCompatServer(port: port)
            plainServer.onNewConnection = { [weak self] connection in
                logTransfer("🔌 [HTTPTransferServer] [Compat] New incoming connection from \(connection.remoteDescription)")
                Task.detached(priority: .userInitiated) { [weak self] in
                    await self?.processIncomingCompatRequest(connection)
                }
            }
            try plainServer.start()
            self.plainCompatServer = plainServer
            listenerState = "ready"
            publishHealthSnapshot()
            return
        }

        let parameters: NWParameters
        
        do {
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
                tcpOptions.keepaliveIdle = 60    // 🔋 60s 无数据才探测（原10s）
                tcpOptions.keepaliveInterval = 15 // 🔋 探测间隔15s（原5s）
                tcpOptions.keepaliveCount = 3     // 🔋 3次失败断开（原5次）
            }
            
            // CONCURRENCY: Allow reuse to coexist with UDP discovery on the same port
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            
            // parameters.serviceClass = .background
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                
                // QUEUE-PER-CONNECTION: Assign a unique, independent queue for each connection.
                // This ensures control channel (Cancel) handshakes are NOT blocked by data channel activity.
                let connectionQueue = DispatchQueue(label: "com.localsend.conn.\(UUID().uuidString.prefix(8))", qos: .userInteractive)
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
                    case .failed(let error):
                        let nsError = error as NSError
                        logTransfer("❌ [HTTPTransferServer] [T+\(Int(elapsedMs))ms] Connection Failed (\(connection.endpoint)): \(error.localizedDescription) (Code: \(nsError.code))")
                        if nsError.code == -9816 {
                            logTransfer("🚨 [HTTPTransferServer] Diagnostic: -9816 Peer Closed. Latency from Start: \(Int(elapsedMs))ms. If this is < 50ms, it's likely a certificate mismatch. If > 1000ms, it's a timeout/starvation.")
                        }
                        
                        connection.cancel()
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }

                // Install the state handler before starting the connection so we never miss a fast `.ready`.
                connection.start(queue: connectionQueue)

                // Start reading immediately after `start()`. Network.framework will continue the receive
                // once the connection really becomes usable, so we don't need to depend on a `.ready`
                // callback arriving before application data is read.
                Task { [weak self] in
                    await self?.processIncomingRequest(connection)
                }
            }
            
            listener.stateUpdateHandler = { [weak self] state in
                logTransfer("🌐 Server (NWListener) state: \(state)")
                Task { await self?.updateListenerState(String(describing: state)) }
                if case .failed(let error) = state {
                    logTransfer("❌ Server CRASHED: \(error)")
                }
            }
            
            listener.start(queue: self.listenerQueue)
            self.listener = listener
            publishHealthSnapshot()
        } catch {
            listener?.cancel()
            listener = nil
            listenerState = "failed: \(error.localizedDescription)"
            publishHealthSnapshot()
            throw error
        }
    }
    
    func stop() {
        logTransfer("🌐 Stopping server...")
        listener?.cancel()
        listener = nil
        plainCompatServer?.stop()
        plainCompatServer = nil
        listenerState = "stopped"
        publishHealthSnapshot()
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
            
            guard !accumulatedData.isEmpty else {
                connection.cancel()
                return
            }

            guard let header = headerData, let requestInfo = HTTPRequestParser.parseHeader(header) else {
                let bytesStr = accumulatedData.prefix(16).map { String(format: "%02hhx", $0) }.joined(separator: " ")
                logTransfer("⚠️ Malformed HTTP header. First bytes: [\(bytesStr)]. Probable protocol mismatch (e.g. TLS on HTTP port).")
                connection.cancel()
                return
            }
            
            let bodyPrefix = accumulatedData.subdata(in: bodyOffset..<accumulatedData.count)
            let rawContentLength = requestInfo.headers["content-length"]
            guard rawContentLength == nil || (Int(rawContentLength!) != nil && Int(rawContentLength!)! >= 0) else {
                connection.send(content: HTTPRawResponse(statusCode: 400, body: Data()).serialize(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            let contentLength = Int(rawContentLength ?? "0") ?? 0
            
            let connHeader = requestInfo.headers["connection"]?.lowercased()
            let shouldKeepAlive = (connHeader != "close")
            
            let isChunked = requestInfo.headers["transfer-encoding"]?.lowercased() == "chunked"
            
            // 2. For /upload path: stream body directly to disk
            if requestInfo.path == "/api/localsend/v2/upload" {
                logTransfer("📥 \(requestInfo.method) \(requestInfo.path) [streaming \(isChunked ? "chunked" : "\(contentLength) bytes")]")
                var response = await handleUploadStreaming(
                    requestInfo: requestInfo,
                    connection: connection,
                    bodyPrefix: bodyPrefix,
                    contentLength: contentLength,
                    isChunked: isChunked
                )
                response.shouldKeepAlive = shouldKeepAlive
                
                connection.send(content: response.serialize(), completion: .contentProcessed({ [self] error in
                    if shouldKeepAlive && error == nil {
                        Task { [weak self] in await self?.processIncomingRequest(connection) }
                    } else {
                        connection.cancel()
                    }
                }))
                return
            }

            guard isChunked || contentLength <= maximumControlBodyBytes,
                  bodyPrefix.count <= maximumControlBodyBytes else {
                connection.send(content: HTTPRawResponse(statusCode: 413, body: Data()).serialize(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            
            // 3. For all other paths: accumulate body in memory (small payloads)
            var body: Data
            var mutablePrefix = bodyPrefix
            if isChunked {
                body = try await receiveChunkedBody(
                    from: connection,
                    buffer: &mutablePrefix,
                    maximumLength: maximumControlBodyBytes
                )
            } else {
                body = Data(bodyPrefix.prefix(contentLength))
                if contentLength > 0 {
                    while body.count < contentLength {
                        let remaining = contentLength - body.count
                        let chunk = try await receiveChunk(from: connection, maxLength: min(remaining, 65536))
                        if chunk.isEmpty { break }
                        body.append(chunk)
                    }
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
            var response = await self.route(
                request: request,
                remoteIP: self.normalizedRemoteIP(from: connection.endpoint)
            )
            response.shouldKeepAlive = shouldKeepAlive

            // 5. Send Response
            connection.send(content: response.serialize(), completion: .contentProcessed({ [self] error in
                if let error = error {
                    logTransfer("❌ Response send error: \(error)")
                    connection.cancel()
                    return
                }
                
                if shouldKeepAlive {
                    logTransfer("🔄 Connection kept alive. Waiting for next request...")
                    Task { [weak self] in
                        await self?.processIncomingRequest(connection)
                    }
                } else {
                    connection.cancel()
                }
            }))
            
        } catch {
            // Check if it's a normal closure or an actual error
            let nsError = error as NSError
            if nsError.domain == "NWErrorDomain", nsError.code == 0 {
                // Connection closed normally by peer
                logTransfer("🔌 Connection closed by peer.")
            } else {
                logTransfer("❌ Connection error: \(error)")
            }
            connection.cancel()
        }
    }

    nonisolated private func processIncomingCompatRequest(_ connection: PlainHTTPCompatConnection) async {
        defer { connection.close() }

        do {
            var accumulatedData = Data()
            var headerData: Data?
            var bodyOffset = 0

            while true {
                let chunk = try receiveSocketChunk(from: connection)
                if chunk.isEmpty { break }
                accumulatedData.append(chunk)

                if let range = accumulatedData.range(of: "\r\n\r\n".data(using: .utf8)!) {
                    headerData = accumulatedData.subdata(in: 0..<range.upperBound)
                    bodyOffset = range.upperBound
                    break
                }

                if accumulatedData.count > 16384 {
                    break
                }
            }

            guard let header = headerData, let requestInfo = HTTPRequestParser.parseHeader(header) else {
                let bytesStr = accumulatedData.prefix(16).map { String(format: "%02hhx", $0) }.joined(separator: " ")
                logTransfer("⚠️ [Compat] Malformed HTTP header from \(connection.remoteDescription). First bytes: [\(bytesStr)]")
                return
            }

            let bodyPrefix = accumulatedData.subdata(in: bodyOffset..<accumulatedData.count)
            let rawContentLength = requestInfo.headers["content-length"]
            guard rawContentLength == nil || (Int(rawContentLength!) != nil && Int(rawContentLength!)! >= 0) else {
                try connection.sendAll(HTTPRawResponse(statusCode: 400, body: Data()).serialize())
                return
            }
            let contentLength = Int(rawContentLength ?? "0") ?? 0
            let isChunked = requestInfo.headers["transfer-encoding"]?.lowercased() == "chunked"
            let requestedKeepAlive = requestInfo.headers["connection"]?.lowercased() == "keep-alive"

            if requestInfo.path == "/api/localsend/v2/upload" {
                logTransfer("📥 [Compat] \(requestInfo.method) \(requestInfo.path) [streaming \(isChunked ? "chunked" : "\(contentLength) bytes")]")
                var response = await handleCompatUploadStreaming(
                    requestInfo: requestInfo,
                    connection: connection,
                    bodyPrefix: bodyPrefix,
                    contentLength: contentLength,
                    isChunked: isChunked
                )
                response.shouldKeepAlive = false
                try connection.sendAll(response.serialize())
                return
            }

            guard isChunked || contentLength <= maximumControlBodyBytes,
                  bodyPrefix.count <= maximumControlBodyBytes else {
                try connection.sendAll(HTTPRawResponse(statusCode: 413, body: Data()).serialize())
                return
            }

            var body: Data
            var mutablePrefix = bodyPrefix
            if isChunked {
                body = try receiveSocketChunkedBody(
                    from: connection,
                    buffer: &mutablePrefix,
                    maximumLength: maximumControlBodyBytes
                )
            } else {
                body = Data(bodyPrefix.prefix(contentLength))
                if contentLength > 0 {
                    while body.count < contentLength {
                        let remaining = contentLength - body.count
                        let chunk = try receiveSocketChunk(from: connection, maxLength: min(remaining, 65536))
                        if chunk.isEmpty { break }
                        body.append(chunk)
                    }
                }
            }

            let request = HTTPRawRequest(
                method: requestInfo.method,
                path: requestInfo.path,
                headers: requestInfo.headers,
                body: body,
                queryParams: requestInfo.queryParams
            )

            var response = await self.route(request: request, remoteIP: connection.remoteIP)
            response.shouldKeepAlive = false
            try connection.sendAll(response.serialize())

            if requestedKeepAlive {
                logTransfer("ℹ️ [Compat] Closing \(connection.remoteDescription) after one request. Keep-alive is intentionally disabled in compatibility mode.")
            }
        } catch {
            logTransfer("❌ [Compat] Connection error for \(connection.remoteDescription): \(error.localizedDescription)")
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
                
                continuation.resume(throwing: NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"]))
            }
        }
    }

    nonisolated private func receiveSocketChunk(from connection: PlainHTTPCompatConnection, maxLength: Int = 65536) throws -> Data {
        let content = try connection.receive(maxLength: maxLength)
        if !content.isEmpty {
            let preview = content.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            logTransfer("📥 [Compat] Received chunk from \(connection.remoteDescription): \(content.count) bytes. Preview: [\(preview)]")
        }
        return content
    }
    
    nonisolated private func readLine(from connection: NWConnection, buffer: inout Data) async throws -> String {
        while true {
            if let range = buffer.range(of: "\r\n".data(using: .utf8)!) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            let chunk = try await receiveChunk(from: connection)
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        return ""
    }

    nonisolated private func readSocketLine(from connection: PlainHTTPCompatConnection, buffer: inout Data) throws -> String {
        while true {
            if let range = buffer.range(of: "\r\n".data(using: .utf8)!) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            let chunk = try receiveSocketChunk(from: connection)
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        return ""
    }
    
    nonisolated private func receiveChunkedBody(
        from connection: NWConnection,
        buffer: inout Data,
        maximumLength: Int
    ) async throws -> Data {
        var body = Data()
        while true {
            let sizeLine = try await self.readLine(from: connection, buffer: &buffer)
            let trimmedSize = sizeLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedSize.isEmpty, let size = Int(trimmedSize, radix: 16), size >= 0 else {
                throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid chunk size"])
            }
            if size == 0 { 
                _ = try await self.readLine(from: connection, buffer: &buffer) // Final CRLF
                break 
            }
            guard size <= maximumLength - body.count else {
                throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Control request body is too large"])
            }
            
            var chunkData = Data()
            while chunkData.count < size {
                if !buffer.isEmpty {
                    let toTake = min(buffer.count, size - chunkData.count)
                    chunkData.append(buffer.subdata(in: 0..<toTake))
                    buffer.removeSubrange(0..<toTake)
                } else {
                    let next = try await self.receiveChunk(from: connection, maxLength: size - chunkData.count)
                    if next.isEmpty {
                        throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Truncated chunked body"])
                    }
                    buffer.append(next)
                }
            }
            body.append(chunkData)
            _ = try await self.readLine(from: connection, buffer: &buffer) // Trailing CRLF
        }
        return body
    }

    nonisolated private func receiveSocketChunkedBody(
        from connection: PlainHTTPCompatConnection,
        buffer: inout Data,
        maximumLength: Int
    ) throws -> Data {
        var body = Data()
        while true {
            let sizeLine = try readSocketLine(from: connection, buffer: &buffer)
            let trimmedSize = sizeLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedSize.isEmpty, let size = Int(trimmedSize, radix: 16), size >= 0 else {
                throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid chunk size"])
            }
            if size == 0 {
                _ = try readSocketLine(from: connection, buffer: &buffer)
                break
            }
            guard size <= maximumLength - body.count else {
                throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Control request body is too large"])
            }

            var chunkData = Data()
            while chunkData.count < size {
                if !buffer.isEmpty {
                    let toTake = min(buffer.count, size - chunkData.count)
                    chunkData.append(buffer.subdata(in: 0..<toTake))
                    buffer.removeSubrange(0..<toTake)
                } else {
                    let next = try receiveSocketChunk(from: connection, maxLength: size - chunkData.count)
                    if next.isEmpty {
                        throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Truncated chunked body"])
                    }
                    buffer.append(next)
                }
            }
            body.append(chunkData)
            _ = try readSocketLine(from: connection, buffer: &buffer)
        }
        return body
    }

    private func route(request: HTTPRawRequest, remoteIP: String) async -> HTTPRawResponse {
        logTransfer("📥 \(request.method) \(request.path)")
        
        switch request.path {
        case "/api/localsend/v2/info":
            return await handleInfo(request: request)
        case "/api/localsend/v2/register":
            return await handleRegister(request: request, remoteIP: remoteIP)
        case "/api/localsend/v2/prepare-upload":
            return await handlePrepareUpload(request: request)
        case "/api/localsend/v2/cancel":
            return await handleCancel(request: request)
        default:
            logTransfer("⚠️ [HTTPTransferServer] Unknown route: \(request.path)")
            return HTTPRawResponse(statusCode: 404, body: "Not Found".data(using: .utf8)!)
        }
    }
    
    // MARK: - Handlers
    
    private func handleInfo(request: HTTPRawRequest) async -> HTTPRawResponse {
        do {
            let responseDto = RegisterDto(
                alias: alias,
                version: AirSendAppMetadata.version,
                deviceModel: deviceModel,
                deviceType: deviceType.rawValue,
                fingerprint: fingerprint,
                macAddress: macAddress,
                port: Int(NetworkPorts.transferPort),
                protocolType: isHTTPS ? ProtocolType.https.rawValue : ProtocolType.http.rawValue,
                download: true
            )
            
            let data = try JSONEncoder().encode(responseDto)
            return HTTPRawResponse(statusCode: 200, body: data)
        } catch {
            return HTTPRawResponse(statusCode: 500, body: "Encoding Error".data(using: .utf8)!)
        }
    }
    
    private func handleRegister(request: HTTPRawRequest, remoteIP: String) async -> HTTPRawResponse {
        do {
            let dto = try JSONDecoder().decode(RegisterDto.self, from: request.body)

            if remoteIP != "unknown",
               !DiscoveryIdentity.fingerprintsMatch(dto.fingerprint, fingerprint) {
                let device = Device(
                    id: dto.fingerprint,
                    alias: dto.alias,
                    ip: remoteIP,
                    port: dto.port ?? Int(NetworkPorts.transferPort),
                    deviceModel: dto.deviceModel,
                    deviceType: dto.deviceType,
                    version: dto.version ?? "2.0",
                    https: dto.protocolType == ProtocolType.https.rawValue,
                    download: dto.download ?? false,
                    lastSeen: Date()
                )
                onDeviceRegistered?(device)
            }
            
            let responseDto = RegisterDto(
                alias: alias,
                version: AirSendAppMetadata.version,
                deviceModel: deviceModel,
                deviceType: deviceType.rawValue,
                fingerprint: fingerprint,
                macAddress: macAddress,
                port: Int(NetworkPorts.transferPort),
                protocolType: isHTTPS ? ProtocolType.https.rawValue : ProtocolType.http.rawValue,
                download: true
            )
            
            let data = try JSONEncoder().encode(responseDto)
            return HTTPRawResponse(statusCode: 200, body: data)
        } catch {
            return HTTPRawResponse(statusCode: 400, body: "Bad Request".data(using: .utf8)!)
        }
    }

    private func normalizedRemoteIP(from endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "unknown" }

        var ip = host.debugDescription
        if let activeRange = ip.range(of: "%") {
            ip = String(ip[..<activeRange.lowerBound])
        }
        if ip.hasPrefix("::ffff:") {
            ip = String(ip.dropFirst(7))
        }
        return ip
    }
    
    private func handlePrepareUpload(request: HTTPRawRequest) async -> HTTPRawResponse {
        do {
            let dto = try JSONDecoder().decode(PrepareUploadRequestDto.self, from: request.body)
            guard !dto.files.isEmpty, dto.files.count <= 512 else {
                return HTTPRawResponse(statusCode: 413, body: "Invalid file count".data(using: .utf8)!)
            }
            guard dto.files.values.allSatisfy({ $0.size >= 0 && $0.fileName.utf8.count <= 1_024 }) else {
                return HTTPRawResponse(statusCode: 413, body: "Invalid file metadata".data(using: .utf8)!)
            }
            let senderAlias = dto.info.alias
            let fileCount = dto.files.count
            let totalSize = dto.files.values.reduce(0) { $0 + $1.size }
            guard totalSize >= 0, totalSize <= 4 * 1_024 * 1_024 * 1_024 * 1_024 else {
                return HTTPRawResponse(statusCode: 413, body: "Transfer too large".data(using: .utf8)!)
            }
            let fileNames = dto.files.values.map(\.fileName).sorted()
            let transferID = UUID()
            let sessionId = transferID.uuidString
            let senderFingerprint = dto.info.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            let peer = PeerIdentity(
                id: dto.info.fingerprint.isEmpty ? "incoming-\(sessionId)" : dto.info.fingerprint,
                alias: senderAlias,
                fingerprint: senderFingerprint.isEmpty ? nil : senderFingerprint
            )
            let coreFiles = dto.files.values.map {
                TransferFileRecord(
                    id: $0.id,
                    name: $0.fileName,
                    mimeType: $0.fileType,
                    size: $0.size
                )
            }.sorted { $0.id < $1.id }
            await transferCoordinator.register(
                id: transferID,
                direction: .incoming,
                source: .remotePeer,
                peer: peer,
                files: coreFiles,
                status: .awaitingAcceptance,
                previewText: dto.files.count == 1 ? dto.files.values.first?.preview : nil
            )

            let transferRequest = TransferRequest(
                sessionId: sessionId,
                senderAlias: senderAlias,
                senderFingerprint: dto.info.fingerprint,
                fileCount: fileCount,
                fileNames: fileNames,
                totalSize: totalSize
            )

            logTransfer("🛑 Intercepting transfer request from \(senderAlias)...")
            let allowed = await onTransferRequest?(transferRequest) ?? false
            if !allowed {
                logTransfer("🚫 Transfer declined from \(senderAlias).")
                _ = try? await transferCoordinator.finishDeclined(id: transferID)
                return HTTPRawResponse(statusCode: 403, body: "Forbidden".data(using: .utf8)!)
            }
            logTransfer("✅ Transfer accepted from \(senderAlias).")

            var responseFiles: [String: String] = [:]
            for (fileId, _) in dto.files {
                responseFiles[fileId] = UUID().uuidString
            }
            let stagingDirectory = stagingDirectory(for: sessionId)
            do {
                try createReceiverSession(
                    id: sessionId,
                    transferID: transferID,
                    files: dto.files,
                    tokens: responseFiles,
                    stagingDirectory: stagingDirectory
                )
                _ = try await transferCoordinator.transition(id: transferID, to: .preparing)
            } catch {
                _ = try? await transferCoordinator.finishFailed(
                    id: transferID,
                    code: "receive_prepare_failed",
                    message: error.localizedDescription,
                    retryable: false
                )
                try? FileManager.default.removeItem(at: stagingDirectory)
                throw error
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
        contentLength: Int,
        isChunked: Bool
    ) async -> HTTPRawResponse {
        let query = requestInfo.queryParams
        guard let sessionId = query["sessionId"],
              let fileId = query["fileId"],
              let token = query["token"] else {
            return HTTPRawResponse(statusCode: 400, body: "Bad Request".data(using: .utf8)!)
        }

        guard let claim = await self.claimUpload(sessionID: sessionId, fileID: fileId, token: token) else {
            return HTTPRawResponse(statusCode: 403, body: "Forbidden".data(using: .utf8)!)
        }
        if !isChunked && Int64(contentLength) != claim.file.size {
            await self.failUploadSession(claim: claim, code: "size_mismatch", message: "Declared upload size does not match prepared file size")
            return HTTPRawResponse(statusCode: 400, body: "Size Mismatch".data(using: .utf8)!)
        }

        await self.addUploadConnection(connection, sessionID: sessionId)
        defer {
            Task { await self.removeUploadConnection(connection) }
        }

        let destinationUrl = claim.stagingURL
        do {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: destinationUrl)
            fileManager.createFile(atPath: destinationUrl.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: destinationUrl)
            defer { try? fileHandle.close() }

            var receivedBytes: Int64 = 0
            var mutableBuffer = bodyPrefix
            let bufferSize = 65_536
            var lastProgressUpdate = Date()
            var chunkStreamEndedNormally = false

            if isChunked {
                while true {
                    let sizeLine = try await readLine(from: connection, buffer: &mutableBuffer)
                    let hexStr = sizeLine.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
                    guard !hexStr.isEmpty, let size = Int(hexStr, radix: 16) else {
                        throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid chunk size"])
                    }
                    if size == 0 {
                        _ = try await readLine(from: connection, buffer: &mutableBuffer)
                        chunkStreamEndedNormally = true
                        break
                    }

                    var totalReadThisChunk = 0
                    while totalReadThisChunk < size {
                        let toTake = min(mutableBuffer.count, size - totalReadThisChunk)
                        if toTake > 0 {
                            let chunk = mutableBuffer.subdata(in: 0..<toTake)
                            try fileHandle.write(contentsOf: chunk)
                            mutableBuffer.removeSubrange(0..<toTake)
                            totalReadThisChunk += toTake
                            receivedBytes += Int64(toTake)
                            guard receivedBytes <= claim.file.size else {
                                throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload exceeded prepared file size"])
                            }
                            if Date().timeIntervalSince(lastProgressUpdate) >= 0.1 {
                                await self.reportUploadProgress(claim: claim, receivedBytes: receivedBytes, forceEvent: false)
                                lastProgressUpdate = Date()
                            }
                        } else {
                            let next = try await self.receiveChunk(from: connection, maxLength: min(size - totalReadThisChunk, bufferSize))
                            if next.isEmpty {
                                throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stream ended in chunk"])
                            }
                            mutableBuffer.append(next)
                        }
                    }
                    _ = try await readLine(from: connection, buffer: &mutableBuffer)
                }
            } else {
                if !mutableBuffer.isEmpty {
                    let allowedPrefixCount = min(mutableBuffer.count, contentLength)
                    let prefix = mutableBuffer.prefix(allowedPrefixCount)
                    try fileHandle.write(contentsOf: prefix)
                    receivedBytes += Int64(allowedPrefixCount)
                    mutableBuffer.removeAll()
                }

                while receivedBytes < Int64(contentLength) {
                    let remaining = Int64(contentLength) - receivedBytes
                    let chunk = try await receiveChunk(from: connection, maxLength: Int(min(remaining, Int64(bufferSize))))
                    if chunk.isEmpty { break }
                    try fileHandle.write(contentsOf: chunk)
                    receivedBytes += Int64(chunk.count)
                    if Date().timeIntervalSince(lastProgressUpdate) >= 0.1 {
                        await self.reportUploadProgress(claim: claim, receivedBytes: receivedBytes, forceEvent: false)
                        lastProgressUpdate = Date()
                    }
                }
            }

            guard receivedBytes == claim.file.size, !isChunked || chunkStreamEndedNormally else {
                throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transfer truncated"])
            }
            try fileHandle.synchronize()
            await self.reportUploadProgress(claim: claim, receivedBytes: receivedBytes, forceEvent: true)
            logTransfer("✅ File staged at \(destinationUrl.path) (\(receivedBytes) bytes)")

            return await self.finishStagedUpload(claim: claim)
        } catch {
            logTransfer("❌ [HTTPTransferServer] Upload Failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: destinationUrl)
            await self.failUploadSession(claim: claim, code: "receive_upload_failed", message: error.localizedDescription)
            return HTTPRawResponse(statusCode: 500, body: "Internal Server Error".data(using: .utf8)!)
        }
    }

    nonisolated private func handleCompatUploadStreaming(
        requestInfo: HTTPRequestParser.HeaderInfo,
        connection: PlainHTTPCompatConnection,
        bodyPrefix: Data,
        contentLength: Int,
        isChunked: Bool
    ) async -> HTTPRawResponse {
        let query = requestInfo.queryParams
        guard let sessionId = query["sessionId"],
              let fileId = query["fileId"],
              let token = query["token"] else {
            return HTTPRawResponse(statusCode: 400, body: "Bad Request".data(using: .utf8)!)
        }

        guard let claim = await self.claimUpload(sessionID: sessionId, fileID: fileId, token: token) else {
            return HTTPRawResponse(statusCode: 403, body: "Forbidden".data(using: .utf8)!)
        }
        if !isChunked && Int64(contentLength) != claim.file.size {
            await self.failUploadSession(claim: claim, code: "size_mismatch", message: "Declared upload size does not match prepared file size")
            return HTTPRawResponse(statusCode: 400, body: "Size Mismatch".data(using: .utf8)!)
        }

        await self.addUploadConnection(connection, sessionID: sessionId)
        defer {
            Task { await self.removeUploadConnection(connection) }
        }

        let destinationURL = claim.stagingURL
        do {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: destinationURL)
            fileManager.createFile(atPath: destinationURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: destinationURL)
            defer { try? fileHandle.close() }

            var receivedBytes: Int64 = 0
            var mutableBuffer = bodyPrefix
            let bufferSize = 65_536
            var lastProgressUpdate = Date()
            var chunkStreamEndedNormally = false

            if isChunked {
                while true {
                    let sizeLine = try readSocketLine(from: connection, buffer: &mutableBuffer)
                    let hexStr = sizeLine.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
                    guard !hexStr.isEmpty, let size = Int(hexStr, radix: 16) else {
                        throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid chunk size"])
                    }

                    if size == 0 {
                        _ = try readSocketLine(from: connection, buffer: &mutableBuffer)
                        chunkStreamEndedNormally = true
                        break
                    }

                    var totalReadThisChunk = 0
                    while totalReadThisChunk < size {
                        let toTake = min(mutableBuffer.count, size - totalReadThisChunk)
                        if toTake > 0 {
                            let chunk = mutableBuffer.subdata(in: 0..<toTake)
                            try fileHandle.write(contentsOf: chunk)
                            mutableBuffer.removeSubrange(0..<toTake)
                            totalReadThisChunk += toTake
                            receivedBytes += Int64(toTake)
                            guard receivedBytes <= claim.file.size else {
                                throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload exceeded prepared file size"])
                            }
                            if Date().timeIntervalSince(lastProgressUpdate) >= 0.1 {
                                await self.reportUploadProgress(claim: claim, receivedBytes: receivedBytes, forceEvent: false)
                                lastProgressUpdate = Date()
                            }
                        } else {
                            let next = try receiveSocketChunk(from: connection, maxLength: min(size - totalReadThisChunk, bufferSize))
                            if next.isEmpty {
                                throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stream ended in chunk"])
                            }
                            mutableBuffer.append(next)
                        }
                    }
                    _ = try readSocketLine(from: connection, buffer: &mutableBuffer)
                }
            } else {
                if !mutableBuffer.isEmpty {
                    let allowedPrefixCount = min(mutableBuffer.count, contentLength)
                    let prefix = mutableBuffer.prefix(allowedPrefixCount)
                    try fileHandle.write(contentsOf: prefix)
                    receivedBytes += Int64(allowedPrefixCount)
                    mutableBuffer.removeAll()
                }

                while receivedBytes < Int64(contentLength) {
                    let remaining = Int64(contentLength) - receivedBytes
                    let chunk = try receiveSocketChunk(from: connection, maxLength: Int(min(remaining, Int64(bufferSize))))
                    if chunk.isEmpty { break }

                    try fileHandle.write(contentsOf: chunk)
                    receivedBytes += Int64(chunk.count)
                    if Date().timeIntervalSince(lastProgressUpdate) >= 0.1 {
                        await self.reportUploadProgress(claim: claim, receivedBytes: receivedBytes, forceEvent: false)
                        lastProgressUpdate = Date()
                    }
                }
            }

            guard receivedBytes == claim.file.size, !isChunked || chunkStreamEndedNormally else {
                throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transfer truncated"])
            }
            try fileHandle.synchronize()
            await self.reportUploadProgress(claim: claim, receivedBytes: receivedBytes, forceEvent: true)
            logTransfer("✅ [Compat] File staged at \(destinationURL.path) (\(receivedBytes) bytes)")
            return await self.finishStagedUpload(claim: claim)
        } catch {
            logTransfer("❌ [Compat] Upload Failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: destinationURL)
            await self.failUploadSession(claim: claim, code: "receive_upload_failed", message: error.localizedDescription)
            return HTTPRawResponse(statusCode: 500, body: "Internal Server Error".data(using: .utf8)!)
        }
    }

    nonisolated private func reportUploadProgress(
        claim: ReceiverUploadClaim,
        receivedBytes: Int64,
        forceEvent: Bool
    ) async {
        guard let progress = await self.updateProgress(
            sessionID: claim.sessionID,
            fileID: claim.fileID,
            receivedBytes: receivedBytes
        ) else { return }
        _ = try? await self.transferCoordinator.updateFileProgress(
            transferID: progress.transferID,
            fileID: claim.file.id,
            transferredBytes: receivedBytes,
            forceEvent: forceEvent
        )
        let fraction = progress.total > 0
            ? min(1, Double(progress.received) / Double(progress.total))
            : 1
        await self.triggerProgress(sessionID: claim.sessionID, fraction)
    }

    nonisolated private func failUploadSession(
        claim: ReceiverUploadClaim,
        code: String,
        message: String
    ) async {
        guard let session = await self.failReceiverSession(sessionID: claim.sessionID) else { return }
        try? FileManager.default.removeItem(at: session.stagingDirectory)
        _ = try? await self.transferCoordinator.finishFailed(
            id: session.transferID,
            code: code,
            message: message,
            retryable: true
        )
        await self.triggerTransferComplete(sessionID: claim.sessionID, success: false, message: message)
    }

    nonisolated private func finishStagedUpload(claim: ReceiverUploadClaim) async -> HTTPRawResponse {
        guard let completedSession = await self.completeUpload(
            sessionID: claim.sessionID,
            fileID: claim.fileID
        ) else {
            return HTTPRawResponse(statusCode: 200, body: Data())
        }

        do {
            let savedPathsByFile = try await self.finalizeReceiverSession(completedSession)
            let previewPathsByFile = completedSession.files.reduce(into: [String: String]()) { result, entry in
                let mimeType = entry.value.fileType.lowercased()
                if (mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/")),
                   let path = savedPathsByFile[entry.key] {
                    result[entry.key] = path
                }
            }
            _ = try await self.transferCoordinator.finishCompleted(
                id: completedSession.transferID,
                savedPathsByFile: savedPathsByFile,
                previewPathsByFile: previewPathsByFile
            )
            await self.triggerTransferComplete(sessionID: completedSession.id, success: true, message: nil)
            return HTTPRawResponse(statusCode: 200, body: Data())
        } catch {
            try? FileManager.default.removeItem(at: completedSession.stagingDirectory)
            _ = try? await self.transferCoordinator.finishFailed(
                id: completedSession.transferID,
                code: "receive_save_failed",
                message: error.localizedDescription,
                retryable: false
            )
            await self.triggerTransferComplete(
                sessionID: completedSession.id,
                success: false,
                message: error.localizedDescription
            )
            return HTTPRawResponse(statusCode: 500, body: "Save Failed".data(using: .utf8)!)
        }
    }

    nonisolated private func finalizeReceiverSession(
        _ session: CompletedReceiverSession
    ) async throws -> [String: String] {
        var savedPathsByFile: [String: String] = [:]
        for fileID in session.files.keys.sorted() {
            guard let file = session.files[fileID],
                  let stagingURL = session.stagingURLsByFile[fileID] else {
                throw NSError(
                    domain: "HTTPTransferServer",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing staged file metadata"]
                )
            }

            if isClipboardPayload(file) {
                let data = try Data(contentsOf: stagingURL, options: .mappedIfSafe)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw NSError(
                        domain: "HTTPTransferServer",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Clipboard payload is not valid UTF-8"]
                    )
                }
                await self.triggerTextReceived(text)
                try FileManager.default.removeItem(at: stagingURL)
                continue
            }

            let baseDirectory = await self.getBaseDirectory(for: file)
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let destinationURL = try publishWithoutOverwrite(
                stagingURL: stagingURL,
                requestedName: file.fileName,
                baseDirectory: baseDirectory
            )
            savedPathsByFile[file.id] = destinationURL.path
        }

        try? FileManager.default.removeItem(at: session.stagingDirectory)
        return savedPathsByFile
    }

    nonisolated private func isClipboardPayload(_ file: FileDto) -> Bool {
        guard file.size > 0, file.size <= 1_000_000 else { return false }
        let mimeType = file.fileType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mimeType == "text/plain" else { return false }

        let fileName = (file.fileName as NSString).lastPathComponent.lowercased()
        if fileName == "clipboard.txt" { return true }
        guard fileName.hasSuffix(".txt") else { return false }
        let stem = String(fileName.dropLast(4))
        guard (10...13).contains(stem.utf8.count) else { return false }
        return stem.utf8.allSatisfy { (48...57).contains($0) }
    }

    nonisolated private func publishWithoutOverwrite(
        stagingURL: URL,
        requestedName: String,
        baseDirectory: URL
    ) throws -> URL {
        let lastComponent = (requestedName as NSString).lastPathComponent
        let safeName = lastComponent.isEmpty || lastComponent == "." || lastComponent == ".."
            ? "Received File"
            : lastComponent
        let nameURL = URL(fileURLWithPath: safeName)
        let pathExtension = nameURL.pathExtension
        let baseName = nameURL.deletingPathExtension().lastPathComponent

        var linkSourceURL = stagingURL
        var destinationVolumeCopy: URL?
        defer {
            if let destinationVolumeCopy {
                try? FileManager.default.removeItem(at: destinationVolumeCopy)
            }
        }

        for suffix in 0..<10_000 {
            let candidateName = suffix == 0 ? baseName : "\(baseName) (\(suffix))"
            var candidateURL = baseDirectory.appendingPathComponent(candidateName, isDirectory: false)
            if !pathExtension.isEmpty {
                candidateURL.appendPathExtension(pathExtension)
            }

            let result = linkSourceURL.path.withCString { sourcePath in
                candidateURL.path.withCString { destinationPath in
                    Darwin.link(sourcePath, destinationPath)
                }
            }
            if result == 0 {
                try FileManager.default.removeItem(at: stagingURL)
                synchronizeDirectory(baseDirectory)
                return candidateURL
            }
            if errno == EXDEV, destinationVolumeCopy == nil {
                let temporaryURL = baseDirectory.appendingPathComponent(
                    ".airsend-\(UUID().uuidString).partial",
                    isDirectory: false
                )
                let copyResult = stagingURL.path.withCString { sourcePath in
                    temporaryURL.path.withCString { destinationPath in
                        copyfile(sourcePath, destinationPath, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL))
                    }
                }
                guard copyResult == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if let handle = try? FileHandle(forWritingTo: temporaryURL) {
                    try? handle.synchronize()
                    try? handle.close()
                }
                destinationVolumeCopy = temporaryURL
                linkSourceURL = temporaryURL
                continue
            }
            if errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        throw NSError(
            domain: "HTTPTransferServer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Could not allocate a unique destination file name"]
        )
    }

    nonisolated private func synchronizeDirectory(_ directory: URL) {
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fsync(descriptor)
    }
    
    nonisolated private func handleCancel(request: HTTPRawRequest) async -> HTTPRawResponse {
        logTransfer("🛑 [HTTPTransferServer] Cancel request received from peer. Query: \(request.queryParams)")

        guard let sessionID = request.queryParams["sessionId"], !sessionID.isEmpty else {
            return HTTPRawResponse(statusCode: 400, body: "Missing sessionId".data(using: .utf8)!)
        }
        guard let session = await performSessionCancellation(sessionID: sessionID) else {
            return HTTPRawResponse(statusCode: 404, body: "Unknown session".data(using: .utf8)!)
        }

        try? FileManager.default.removeItem(at: session.stagingDirectory)
        _ = try? await transferCoordinator.finishCancelled(id: session.transferID)
        await triggerCancelReceived(sessionID: sessionID)
        await triggerTransferComplete(sessionID: sessionID, success: false, message: "Cancelled by peer")
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
    
    var shouldKeepAlive: Bool = false
    
    func serialize() -> Data {
        var str = "HTTP/1.1 \(statusCode) \(statusPhrase)\r\n"
        str += "Content-Length: \(body.count)\r\n"
        str += "Content-Type: application/json\r\n"
        str += "Server: HeadlessLocalSend-macOS\r\n"
        str += "Connection: \(shouldKeepAlive ? "keep-alive" : "close")\r\n"
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
        case 413: return "Payload Too Large"
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
            
            // RFC 7230: Header name is followed by a colon, optional whitespace, and the field value.
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        
        // Parse Query
        var query: [String: String] = [:]
        let pathComps = fullPath.components(separatedBy: "?")
        let path = pathComps[0]
        if pathComps.count > 1 {
            let queryItems = pathComps[1].components(separatedBy: "&")
            for item in queryItems {
                let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if kv.count == 2 {
                    let key = kv[0].removingPercentEncoding ?? kv[0]
                    let value = kv[1].removingPercentEncoding ?? kv[1]
                    query[key] = value
                }
            }
        }
        
        return HeaderInfo(method: method, path: path, queryParams: query, headers: headers)
    }
}
