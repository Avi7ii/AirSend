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
    private var macAddress: String? { LocalNetworkIdentity.primaryHardwareAddress() }
    
    
    private var listener: NWListener?
    private var plainCompatServer: PlainHTTPCompatServer?
    private var port: UInt16
    private var isHTTPS: Bool = false
    
    // Dedicated queue for the listener and general management
    private let listenerQueue = DispatchQueue(label: "com.localsend.server.listener", qos: .userInteractive)
    
    // Session state
    private var currentSessionId: String?
    private var fileTokens: [String: String] = [:] // fileId -> token
    private var filesToReceive: [String: FileDto] = [:] // fileId -> FileDto
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:] // Connection pool for concurrent transfers
    private var activeCompatConnections: [Int32: PlainHTTPCompatConnection] = [:]

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

    init(port: UInt16 = NetworkPorts.transferPort, fingerprint: String) {
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
    
    func addUploadConnection(_ connection: NWConnection) {
        self.activeConnections[ObjectIdentifier(connection)] = connection
    }
    
    func removeUploadConnection(_ connection: NWConnection) {
        self.activeConnections.removeValue(forKey: ObjectIdentifier(connection))
    }

    func addUploadConnection(_ connection: PlainHTTPCompatConnection) {
        self.activeCompatConnections[connection.socket] = connection
    }

    func removeUploadConnection(_ connection: PlainHTTPCompatConnection) {
        self.activeCompatConnections.removeValue(forKey: connection.socket)
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
        
        let conns = self.activeConnections.values
        let compatConns = self.activeCompatConnections.values
        self.activeConnections.removeAll()
        self.activeCompatConnections.removeAll()
        conns.forEach { $0.cancel() }
        compatConns.forEach { $0.close() }
        
        return wasActive
    }
    
    func start(p12Data: Data? = nil) async throws {
        listener?.cancel()
        listener = nil
        plainCompatServer?.stop()
        plainCompatServer = nil

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
            
            listener.stateUpdateHandler = { state in
                logTransfer("🌐 Server (NWListener) state: \(state)")
                if case .failed(let error) = state {
                    logTransfer("❌ Server CRASHED: \(error)")
                }
            }
            
            listener.start(queue: self.listenerQueue)
            self.listener = listener
        } catch {
            listener?.cancel()
            listener = nil
            throw error
        }
    }
    
    func stop() {
        logTransfer("🌐 Stopping server...")
        listener?.cancel()
        listener = nil
        plainCompatServer?.stop()
        plainCompatServer = nil
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
                
                connection.send(content: response.serialize(), completion: .contentProcessed({ error in
                    if shouldKeepAlive && error == nil {
                        Task { [weak self] in await self?.processIncomingRequest(connection) }
                    } else {
                        connection.cancel()
                    }
                }))
                return
            }
            
            // 3. For all other paths: accumulate body in memory (small payloads)
            var body: Data
            var mutablePrefix = bodyPrefix
            if isChunked {
                body = try await receiveChunkedBody(from: connection, buffer: &mutablePrefix)
            } else {
                body = bodyPrefix
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
            connection.send(content: response.serialize(), completion: .contentProcessed({ error in
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
            let contentLength = Int(requestInfo.headers["content-length"] ?? "0") ?? 0
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

            var body: Data
            var mutablePrefix = bodyPrefix
            if isChunked {
                body = try receiveSocketChunkedBody(from: connection, buffer: &mutablePrefix)
            } else {
                body = bodyPrefix
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
    
    nonisolated private func receiveChunkedBody(from connection: NWConnection, buffer: inout Data) async throws -> Data {
        var body = Data()
        while true {
            let sizeLine = try await self.readLine(from: connection, buffer: &buffer)
            let trimmedSize = sizeLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedSize.isEmpty, let size = Int(trimmedSize, radix: 16) else { break }
            if size == 0 { 
                _ = try await self.readLine(from: connection, buffer: &buffer) // Final CRLF
                break 
            }
            
            var chunkData = Data()
            while chunkData.count < size {
                if !buffer.isEmpty {
                    let toTake = min(buffer.count, size - chunkData.count)
                    chunkData.append(buffer.subdata(in: 0..<toTake))
                    buffer.removeSubrange(0..<toTake)
                } else {
                    let next = try await self.receiveChunk(from: connection, maxLength: size - chunkData.count)
                    if next.isEmpty { break }
                    buffer.append(next)
                }
            }
            body.append(chunkData)
            _ = try await self.readLine(from: connection, buffer: &buffer) // Trailing CRLF
        }
        return body
    }

    nonisolated private func receiveSocketChunkedBody(from connection: PlainHTTPCompatConnection, buffer: inout Data) throws -> Data {
        var body = Data()
        while true {
            let sizeLine = try readSocketLine(from: connection, buffer: &buffer)
            let trimmedSize = sizeLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedSize.isEmpty, let size = Int(trimmedSize, radix: 16) else { break }
            if size == 0 {
                _ = try readSocketLine(from: connection, buffer: &buffer)
                break
            }

            var chunkData = Data()
            while chunkData.count < size {
                if !buffer.isEmpty {
                    let toTake = min(buffer.count, size - chunkData.count)
                    chunkData.append(buffer.subdata(in: 0..<toTake))
                    buffer.removeSubrange(0..<toTake)
                } else {
                    let next = try receiveSocketChunk(from: connection, maxLength: size - chunkData.count)
                    if next.isEmpty { break }
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
                version: "3.0.1",
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

            if remoteIP != "unknown" {
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
                version: "3.0.1",
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
        contentLength: Int,
        isChunked: Bool
    ) async -> HTTPRawResponse {
        let query = requestInfo.queryParams
        guard let sessionId = query["sessionId"],
              let fileId = query["fileId"],
              let token = query["token"] else {
            return HTTPRawResponse(statusCode: 400, body: "Bad Request".data(using: .utf8)!)
        }
        
        let sessionState = await self.getSessionState()
        
        if sessionId != sessionState.id || sessionState.tokens[fileId] != token {
            return HTTPRawResponse(statusCode: 403, body: "Forbidden".data(using: .utf8)!)
        }
        
        guard let fileDto = sessionState.files[fileId] else {
            return HTTPRawResponse(statusCode: 404, body: "Not Found".data(using: .utf8)!)
        }
        
        // Store active connection for cancellation
        await self.addUploadConnection(connection)
        
        defer { 
            Task { await self.removeUploadConnection(connection) }
        }

        // --- PATH LOGIC START ---
        
        // 1. Get Base Directory (Custom or Downloads)
        let baseDir = await self.getBaseDirectory()
        let safeFileName = (fileDto.fileName as NSString).lastPathComponent
        var destinationUrl = baseDir.appendingPathComponent(safeFileName)
        
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
            var mutableBuffer = bodyPrefix
            let bufferSize = 65536 
            var lastProgressUpdate = Date()
            var lastReportedProgress: Double = 0
            
            var chunkStreamEndedNormally = false
            
            if isChunked {
                while true {
                    let sizeLine = try await readLine(from: connection, buffer: &mutableBuffer)
                    let hexStr = sizeLine.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
                    guard !hexStr.isEmpty, let size = Int(hexStr, radix: 16) else { break }
                    
                    if size == 0 { 
                        _ = try await readLine(from: connection, buffer: &mutableBuffer) // Final CRLF
                        chunkStreamEndedNormally = true
                        break 
                    }
                    
                    var totalReadThisChunk = 0
                    while totalReadThisChunk < size {
                        let toTake = min(mutableBuffer.count, size - totalReadThisChunk)
                        if toTake > 0 {
                            let chunk = mutableBuffer.subdata(in: 0..<toTake)
                            try await Task.detached(priority: .medium) { try fileHandle.write(contentsOf: chunk) }.value
                            mutableBuffer.removeSubrange(0..<toTake)
                            totalReadThisChunk += toTake
                            receivedBytes += toTake
                            let progressInfo = await self.updateIncrementProgress(bytes: Int64(toTake))
                            if progressInfo.total > 0 {
                                let progress = Double(progressInfo.received) / Double(progressInfo.total)
                                let timeSinceLast = Date().timeIntervalSince(lastProgressUpdate)
                                if timeSinceLast > 0.1 || (progress - lastReportedProgress) > 0.01 || progress >= 1.0 {
                                    await self.triggerProgress(progress)
                                    lastProgressUpdate = Date(); lastReportedProgress = progress
                                }
                            }
                        } else {
                            let next = try await self.receiveChunk(from: connection, maxLength: min(size - totalReadThisChunk, bufferSize))
                            if next.isEmpty { throw NSError(domain: "HTTPTransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stream ended in chunk"]) }
                            mutableBuffer.append(next)
                        }
                    }
                    _ = try await readLine(from: connection, buffer: &mutableBuffer) // Skip trailing CRLF
                }
            } else {
                // Write initial bodyPrefix first
                if !mutableBuffer.isEmpty {
                    let prefixCount = mutableBuffer.count
                    try fileHandle.write(contentsOf: mutableBuffer)
                    receivedBytes += prefixCount
                    _ = await self.updateIncrementProgress(bytes: Int64(prefixCount))
                    mutableBuffer.removeAll()
                }
                
                while receivedBytes < contentLength {
                    let remaining = contentLength - receivedBytes
                    let chunk = try await receiveChunk(from: connection, maxLength: min(remaining, bufferSize))
                    if chunk.isEmpty { break }
                    
                    try await Task.detached(priority: .medium) { try fileHandle.write(contentsOf: chunk) }.value
                    receivedBytes += chunk.count
                    let progressInfo = await self.updateIncrementProgress(bytes: Int64(chunk.count))
                    
                    if progressInfo.total > 0 {
                        let progress = Double(progressInfo.received) / Double(progressInfo.total)
                        let timeSinceLast = Date().timeIntervalSince(lastProgressUpdate)
                        if timeSinceLast > 0.1 || (progress - lastReportedProgress) > 0.01 || progress >= 1.0 {
                            await self.triggerProgress(progress)
                            lastProgressUpdate = Date(); lastReportedProgress = progress
                        }
                    }
                }
            }
            
            logTransfer("✅ File saved to \(destinationUrl.path) (\(receivedBytes) bytes, streamed)")
            
            // Check if it's a text file for clipboard handling
            let isText = fileDto.fileName.hasSuffix(".txt") || fileDto.fileType == "text/plain"
            if isText, receivedBytes < 1_000_000 {
                if let textContent = try? String(contentsOf: destinationUrl, encoding: .utf8) {
                    // 1. 把文本打入 Mac 系统剪贴板
                    await self.triggerTextReceived(textContent)
                    
                    // ==========================================
                    // 🚀 核心改造：阅后即焚，实现绝对的无痕流转
                    // ==========================================
                    if fileDto.fileName == "clipboard.txt" {
                        do {
                            try FileManager.default.removeItem(at: destinationUrl)
                            logTransfer("🧹 [AirSend 中枢] 剪贴板临时文件 \(fileDto.fileName) 已被抹除，无痕同步完成")
                        } catch {
                            logTransfer("⚠️ 抹除临时文件失败: \(error)")
                        }
                    }
                }
            }
            
            // Report Final Progress (100%) ensures UI hits 100% even for small files
            let finalProgress = await self.getSessionSizeInfo()
            if finalProgress.total > 0 {
                await self.triggerProgress(1.0)
            }
            
            // Check for Session Completion
            let counts = await self.incrementFileCount()
            
            // CRITICAL FIX: Verify we received the full file
            if (!isChunked && receivedBytes < contentLength) || (isChunked && !chunkStreamEndedNormally) {
                logTransfer("❌ [HTTPTransferServer] File incomplete or chunk stream aborted! Expected \(contentLength), got \(receivedBytes). Transfer truncated.")
                await self.triggerTransferComplete(success: false, message: "Transfer truncated")
                return HTTPRawResponse(statusCode: 400, body: Data())
            }
            
            if counts.current >= counts.expected {
                await self.triggerTransferComplete(success: true, message: nil as String?)
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

        let sessionState = await self.getSessionState()
        if sessionId != sessionState.id || sessionState.tokens[fileId] != token {
            return HTTPRawResponse(statusCode: 403, body: "Forbidden".data(using: .utf8)!)
        }

        guard let fileDto = sessionState.files[fileId] else {
            return HTTPRawResponse(statusCode: 404, body: "Not Found".data(using: .utf8)!)
        }

        await self.addUploadConnection(connection)
        defer {
            Task { await self.removeUploadConnection(connection) }
        }

        let baseDir = await self.getBaseDirectory()
        let safeFileName = (fileDto.fileName as NSString).lastPathComponent
        var destinationUrl = baseDir.appendingPathComponent(safeFileName)

        var counter = 1
        let ext = destinationUrl.pathExtension
        let nameWithoutExt = destinationUrl.deletingPathExtension().lastPathComponent

        while FileManager.default.fileExists(atPath: destinationUrl.path) {
            let newName = "\(nameWithoutExt) (\(counter))"
            destinationUrl = baseDir.appendingPathComponent(newName).appendingPathExtension(ext)
            counter += 1
        }

        do {
            let fileManager = FileManager.default
            fileManager.createFile(atPath: destinationUrl.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: destinationUrl)
            defer { try? fileHandle.close() }

            var receivedBytes = 0
            var mutableBuffer = bodyPrefix
            let bufferSize = 65536
            var lastProgressUpdate = Date()
            var lastReportedProgress: Double = 0
            var chunkStreamEndedNormally = false

            if isChunked {
                while true {
                    let sizeLine = try readSocketLine(from: connection, buffer: &mutableBuffer)
                    let hexStr = sizeLine.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
                    guard !hexStr.isEmpty, let size = Int(hexStr, radix: 16) else { break }

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
                            receivedBytes += toTake
                            let progressInfo = await self.updateIncrementProgress(bytes: Int64(toTake))
                            if progressInfo.total > 0 {
                                let progress = Double(progressInfo.received) / Double(progressInfo.total)
                                let timeSinceLast = Date().timeIntervalSince(lastProgressUpdate)
                                if timeSinceLast > 0.1 || (progress - lastReportedProgress) > 0.01 || progress >= 1.0 {
                                    await self.triggerProgress(progress)
                                    lastProgressUpdate = Date()
                                    lastReportedProgress = progress
                                }
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
                    let prefixCount = mutableBuffer.count
                    try fileHandle.write(contentsOf: mutableBuffer)
                    receivedBytes += prefixCount
                    _ = await self.updateIncrementProgress(bytes: Int64(prefixCount))
                    mutableBuffer.removeAll()
                }

                while receivedBytes < contentLength {
                    let remaining = contentLength - receivedBytes
                    let chunk = try receiveSocketChunk(from: connection, maxLength: min(remaining, bufferSize))
                    if chunk.isEmpty { break }

                    try fileHandle.write(contentsOf: chunk)
                    receivedBytes += chunk.count
                    let progressInfo = await self.updateIncrementProgress(bytes: Int64(chunk.count))
                    if progressInfo.total > 0 {
                        let progress = Double(progressInfo.received) / Double(progressInfo.total)
                        let timeSinceLast = Date().timeIntervalSince(lastProgressUpdate)
                        if timeSinceLast > 0.1 || (progress - lastReportedProgress) > 0.01 || progress >= 1.0 {
                            await self.triggerProgress(progress)
                            lastProgressUpdate = Date()
                            lastReportedProgress = progress
                        }
                    }
                }
            }

            logTransfer("✅ [Compat] File saved to \(destinationUrl.path) (\(receivedBytes) bytes, streamed)")

            let isText = fileDto.fileName.hasSuffix(".txt") || fileDto.fileType == "text/plain"
            if isText, receivedBytes < 1_000_000, let textContent = try? String(contentsOf: destinationUrl, encoding: .utf8) {
                await self.triggerTextReceived(textContent)
                if fileDto.fileName == "clipboard.txt" {
                    do {
                        try FileManager.default.removeItem(at: destinationUrl)
                        logTransfer("🧹 [AirSend 中枢] 剪贴板临时文件 \(fileDto.fileName) 已被抹除，无痕同步完成")
                    } catch {
                        logTransfer("⚠️ 抹除临时文件失败: \(error)")
                    }
                }
            }

            let finalProgress = await self.getSessionSizeInfo()
            if finalProgress.total > 0 {
                await self.triggerProgress(1.0)
            }

            let counts = await self.incrementFileCount()
            if (!isChunked && receivedBytes < contentLength) || (isChunked && !chunkStreamEndedNormally) {
                logTransfer("❌ [Compat] File incomplete or chunk stream aborted! Expected \(contentLength), got \(receivedBytes). Transfer truncated.")
                await self.triggerTransferComplete(success: false, message: "Transfer truncated")
                return HTTPRawResponse(statusCode: 400, body: Data())
            }

            if counts.current >= counts.expected {
                await self.triggerTransferComplete(success: true, message: nil as String?)
            }

            return HTTPRawResponse(statusCode: 200, body: Data())
        } catch {
            logTransfer("❌ [Compat] Upload Failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: destinationUrl)

            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(ETIMEDOUT) || nsError.code == Int(ECONNRESET)) {
                logTransfer("🚨 [Compat] Socket timeout/reset detected. Assuming peer cancelled silently.")
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
