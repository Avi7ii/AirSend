import AirSendRuntimeCore
import Foundation
import UniformTypeIdentifiers

actor FileSender {
    private struct SendContext: Sendable {
        let files: [String: FileDto]
        let fileURLs: [String: URL]
        let historySourceURLs: [String: URL]
        let temporaryURLs: [URL]
        let securityScopedURLs: [URL]
        let source: TransferSource
        let previewText: String?
        let retrySpec: TransferRetrySpec?
    }

    private struct RemoteSession: Sendable {
        let sessionID: String
        let device: Device
        let scheme: String
    }

    private struct ActiveTransfer {
        var sessions: [ObjectIdentifier: URLSession] = [:]
        var campusTransferIDs: Set<String> = []
        var remoteSession: RemoteSession?
        var accepted = false
        var cancelled = false
        let startedAt: Date
    }

    private struct HTTPResult: Sendable {
        let statusCode: Int
        let body: Data
    }

    private enum SenderError: LocalizedError, Sendable {
        case invalidURL
        case noFiles
        case declined(Int)
        case unexpectedStatus(Int, String)
        case malformedResponse(String)
        case fallbackTooLarge(Int64)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The peer address is invalid"
            case .noFiles:
                return "No readable files were selected"
            case .declined:
                return "The receiver declined the transfer"
            case let .unexpectedStatus(status, body):
                return body.isEmpty ? "The receiver returned HTTP \(status)" : "HTTP \(status): \(body)"
            case let .malformedResponse(message):
                return message
            case let .fallbackTooLarge(size):
                return "The direct connection failed and the \(size)-byte payload is too large for campus fallback"
            }
        }
    }

    private let alias = Host.current().localizedName ?? "AirSend"
    private let deviceModel = "macOS"
    private let deviceType = DeviceType.desktop
    private let myFingerprint: String
    private let localProtocol: ProtocolType
    private let campusFallback: CampusFallbackCoordinator?
    private let transferCoordinator: TransferCoordinator
    private let artifactStore: TransferArtifactStore?
    private let appVersion: String

    private var activeTransfers: [UUID: ActiveTransfer] = [:]
    private var activeTransferOrder: [UUID] = []

    private var onProgress: (@Sendable (Double) -> Void)?
    private var onAccepted: (@Sendable () -> Void)?
    private var onCancelled: (@Sendable () -> Void)?

    init(
        fingerprint: String,
        localProtocol: ProtocolType = .https,
        campusFallback: CampusFallbackCoordinator? = nil,
        transferCoordinator: TransferCoordinator = TransferCoordinator(),
        artifactStore: TransferArtifactStore? = nil
    ) {
        self.myFingerprint = fingerprint
        self.localProtocol = localProtocol
        self.campusFallback = campusFallback
        self.transferCoordinator = transferCoordinator
        self.artifactStore = artifactStore
        self.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "5.0.1"
    }

    func setOnProgress(_ callback: @escaping @Sendable (Double) -> Void) {
        onProgress = callback
    }

    func setOnAccepted(_ callback: @escaping @Sendable () -> Void) {
        onAccepted = callback
    }

    func setOnCancelled(_ callback: @escaping @Sendable () -> Void) {
        onCancelled = callback
    }

    @discardableResult
    func sendFiles(
        _ urls: [URL],
        to device: Device,
        source: TransferSource = .filePicker
    ) async throws -> UUID {
        let context = try await prepareFileContext(urls: urls, source: source)
        return try await send(context: context, to: device)
    }

    @discardableResult
    func sendData(
        _ data: Data,
        fileName: String,
        mimeType: String,
        previewText: String?,
        source: TransferSource,
        to device: Device
    ) async throws -> UUID {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("airsend-payload-\(UUID().uuidString)", isDirectory: false)
        try data.write(to: temporaryURL, options: .atomic)
        let fileID = UUID().uuidString
        let dto = FileDto(
            id: fileID,
            fileName: fileName,
            size: Int64(data.count),
            fileType: mimeType,
            sha256: nil,
            preview: previewText
        )
        let retrySpec = source == .clipboard
            ? TransferRetrySpec(targetID: device.id, source: source, textPayload: previewText)
            : nil
        let context = SendContext(
            files: [fileID: dto],
            fileURLs: [fileID: temporaryURL],
            historySourceURLs: [fileID: temporaryURL],
            temporaryURLs: [temporaryURL],
            securityScopedURLs: [],
            source: source,
            previewText: previewText,
            retrySpec: retrySpec
        )
        return try await send(context: context, to: device)
    }

    func retry(_ record: TransferRecord, to device: Device) async throws -> UUID {
        guard let retrySpec = record.retrySpec else {
            throw SenderError.malformedResponse("This transfer no longer has a retryable source")
        }
        if let text = retrySpec.textPayload {
            return try await sendData(
                Data(text.utf8),
                fileName: "clipboard.txt",
                mimeType: "text/plain",
                previewText: text,
                source: retrySpec.source,
                to: device
            )
        }
        let urls = retrySpec.sourcePaths.map { URL(fileURLWithPath: $0) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SenderError.malformedResponse("One or more original files are no longer available")
        }
        return try await sendFiles(urls, to: device, source: retrySpec.source)
    }

    func cancelCurrentTransfer() async {
        guard let transferID = activeTransferOrder.last else { return }
        await cancelTransfer(transferID)
    }

    func cancelTransfer(_ transferID: UUID) async {
        guard var active = activeTransfers[transferID] else { return }
        active.cancelled = true
        activeTransfers[transferID] = active
        _ = try? await transferCoordinator.requestCancellation(id: transferID)
        active.sessions.values.forEach { $0.invalidateAndCancel() }
        if let campusFallback {
            for campusID in active.campusTransferIDs {
                await campusFallback.cancelOutgoingTransfer(campusID)
            }
        }
        if let remoteSession = active.remoteSession {
            Task { [weak self] in
                await self?.sendRemoteCancellation(remoteSession)
            }
        }
        onCancelled?()
    }

    private func send(context: SendContext, to device: Device) async throws -> UUID {
        guard !context.files.isEmpty else { throw SenderError.noFiles }
        let transferID = UUID()
        let historySourcePaths = await historySourcePaths(for: context, transferID: transferID)
        let coreFiles = context.files.values.map {
            TransferFileRecord(
                id: $0.id,
                name: $0.fileName,
                mimeType: $0.fileType,
                size: $0.size,
                sourcePath: historySourcePaths[$0.id]
            )
        }.sorted { $0.id < $1.id }
        await transferCoordinator.register(
            id: transferID,
            direction: .outgoing,
            source: context.source,
            peer: PeerIdentity(
                id: device.id,
                alias: device.alias,
                fingerprint: device.id,
                address: "\(device.ip):\(device.port)"
            ),
            files: coreFiles,
            status: .queued,
            previewText: context.previewText,
            retrySpec: context.retrySpec.map {
                TransferRetrySpec(
                    targetID: device.id,
                    source: $0.source,
                    sourcePaths: $0.sourcePaths,
                    textPayload: $0.textPayload
                )
            }
        )
        activeTransfers[transferID] = ActiveTransfer(startedAt: Date())
        activeTransferOrder.append(transferID)
        _ = try? await transferCoordinator.transition(id: transferID, to: .awaitingAcceptance)

        defer {
            for url in context.temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
            context.securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            cleanupTransfer(transferID)
        }

        do {
            do {
                try await performDirectTransfer(
                    transferID: transferID,
                    context: context,
                    device: device
                )
            } catch {
                guard !isCancellation(error, transferID: transferID) else { throw CancellationError() }
                guard !isDecline(error), !isCertificateFailure(error), let campusFallback else { throw error }
                logTransfer("⚠️ Direct transfer to \(device.alias) failed; trying bounded campus fallback: \(error.localizedDescription)")
                if let remoteSession = activeTransfers[transferID]?.remoteSession {
                    await sendRemoteCancellation(remoteSession)
                }
                try await performCampusFallback(
                    transferID: transferID,
                    context: context,
                    device: device,
                    campusFallback: campusFallback
                )
            }

            _ = try await transferCoordinator.finishCompleted(id: transferID)
            return transferID
        } catch {
            if isCancellation(error, transferID: transferID) {
                _ = try? await transferCoordinator.finishCancelled(id: transferID)
                throw CancellationError()
            }
            if isDecline(error) {
                _ = try? await transferCoordinator.finishDeclined(id: transferID)
            } else {
                _ = try? await transferCoordinator.finishFailed(
                    id: transferID,
                    code: failureCode(for: error),
                    message: error.localizedDescription,
                    retryable: isRetryable(error)
                )
            }
            throw error
        }
    }

    private func historySourcePaths(
        for context: SendContext,
        transferID: UUID
    ) async -> [String: String] {
        var paths = context.historySourceURLs.mapValues(\.path)
        guard let artifactStore else { return paths }

        let temporaryPaths = Set(context.temporaryURLs.map { $0.standardizedFileURL.path })
        let candidates = context.historySourceURLs.compactMap { fileID, url -> TransferArtifactCandidate? in
            guard temporaryPaths.contains(url.standardizedFileURL.path),
                  let file = context.files[fileID] else { return nil }
            return TransferArtifactCandidate(
                fileID: fileID,
                fileName: file.fileName,
                sourceURL: url
            )
        }
        guard !candidates.isEmpty else { return paths }

        do {
            let preservedPaths = try await artifactStore.preserve(
                transferID: transferID,
                candidates: candidates
            )
            paths.merge(preservedPaths) { _, preserved in preserved }
        } catch {
            logTransfer("⚠️ Could not preserve transfer preview: \(error.localizedDescription)")
        }
        return paths
    }

    private func performDirectTransfer(
        transferID: UUID,
        context: SendContext,
        device: Device
    ) async throws {
        let scheme = device.https ? "https" : "http"
        let requestDTO = PrepareUploadRequestDto(
            info: RegisterDto(
                alias: alias,
                version: appVersion,
                deviceModel: deviceModel,
                deviceType: deviceType.rawValue,
                fingerprint: myFingerprint,
                macAddress: LocalNetworkIdentity.primaryHardwareAddress(),
                port: Int(NetworkPorts.transferPort),
                protocolType: localProtocol.rawValue,
                download: true
            ),
            files: context.files
        )
        let body = try JSONEncoder().encode(requestDTO)
        let prepareURL = try endpointURL(device: device, scheme: scheme, path: "/api/localsend/v2/prepare-upload")
        var request = URLRequest(url: prepareURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LocalSend/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let result = try await performWithOneRetry(
            transferID: transferID,
            request: request,
            device: device,
            timeout: 30
        )
        if result.statusCode == 403 { throw SenderError.declined(result.statusCode) }
        guard result.statusCode == 200 || result.statusCode == 204 else {
            throw SenderError.unexpectedStatus(
                result.statusCode,
                String(data: result.body, encoding: .utf8) ?? ""
            )
        }

        await markAccepted(transferID)
        if result.statusCode == 204 { return }

        let response: PrepareUploadResponseDto
        do {
            response = try JSONDecoder().decode(PrepareUploadResponseDto.self, from: result.body)
        } catch {
            throw SenderError.malformedResponse("The receiver returned an invalid prepare response")
        }
        guard Set(response.files.keys) == Set(context.files.keys) else {
            throw SenderError.malformedResponse("The receiver did not return an upload token for every file")
        }
        setRemoteSession(
            RemoteSession(sessionID: response.sessionId, device: device, scheme: scheme),
            transferID: transferID
        )

        let entries = response.files.sorted { $0.key < $1.key }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = entries.makeIterator()
            for _ in 0..<min(3, entries.count) {
                if let entry = iterator.next() {
                    group.addTask { try await self.upload(entry, transferID: transferID, context: context, device: device, scheme: scheme, sessionID: response.sessionId) }
                }
            }
            while try await group.next() != nil {
                if let entry = iterator.next() {
                    group.addTask { try await self.upload(entry, transferID: transferID, context: context, device: device, scheme: scheme, sessionID: response.sessionId) }
                }
            }
        }
    }

    private func upload(
        _ entry: (key: String, value: String),
        transferID: UUID,
        context: SendContext,
        device: Device,
        scheme: String,
        sessionID: String
    ) async throws {
        guard let file = context.files[entry.key], let fileURL = context.fileURLs[entry.key] else {
            throw SenderError.malformedResponse("A prepared file is no longer available")
        }
        try checkCancellation(transferID)
        var components = URLComponents(
            url: try endpointURL(device: device, scheme: scheme, path: "/api/localsend/v2/upload"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionID),
            URLQueryItem(name: "fileId", value: entry.key),
            URLQueryItem(name: "token", value: entry.value),
        ]
        guard let uploadURL = components.url else { throw SenderError.invalidURL }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = max(180, Double(file.size) / 1_000_000)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("LocalSend/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let result = try await performUpload(
            transferID: transferID,
            fileID: file.id,
            size: file.size,
            request: request,
            fileURL: fileURL,
            device: device
        )
        guard 200..<300 ~= result.statusCode else {
            throw SenderError.unexpectedStatus(
                result.statusCode,
                String(data: result.body, encoding: .utf8) ?? ""
            )
        }
        await reportProgress(transferID: transferID, fileID: file.id, bytes: file.size, force: true)
    }

    private func performCampusFallback(
        transferID: UUID,
        context: SendContext,
        device: Device,
        campusFallback: CampusFallbackCoordinator
    ) async throws {
        for fileID in context.files.keys.sorted() {
            try checkCancellation(transferID)
            guard let file = context.files[fileID], let fileURL = context.fileURLs[fileID] else { continue }
            guard file.size <= Int64(CampusFallbackCoordinator.maximumPayloadBytes) else {
                throw SenderError.fallbackTooLarge(file.size)
            }
            let campusID = "\(transferID.uuidString)-\(fileID)"
            addCampusTransferID(campusID, to: transferID)
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            try await campusFallback.sendFile(
                data: data,
                fileName: file.fileName,
                fileType: file.fileType,
                to: device,
                transferID: campusID,
                onAccepted: { [weak self] in
                    Task { await self?.markAccepted(transferID) }
                },
                onProgress: { [weak self] progress in
                    Task {
                        await self?.reportProgress(
                            transferID: transferID,
                            fileID: file.id,
                            bytes: Int64(Double(file.size) * progress),
                            force: false
                        )
                    }
                }
            )
            await markAccepted(transferID)
            await reportProgress(transferID: transferID, fileID: file.id, bytes: file.size, force: true)
        }
    }

    private func performWithOneRetry(
        transferID: UUID,
        request: URLRequest,
        device: Device,
        timeout: TimeInterval
    ) async throws -> HTTPResult {
        var lastError: Error?
        for attempt in 1...2 {
            try checkCancellation(transferID)
            do {
                return try await performRequest(
                    transferID: transferID,
                    request: request,
                    device: device,
                    timeout: timeout
                )
            } catch {
                lastError = error
                guard attempt == 1, isRetryable(error), !isCertificateFailure(error) else { throw error }
                try await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        throw lastError ?? SenderError.malformedResponse("The request failed")
    }

    private func performRequest(
        transferID: UUID,
        request: URLRequest,
        device: Device,
        timeout: TimeInterval
    ) async throws -> HTTPResult {
        let delegate = SessionDelegate(
            expectedFingerprint: device.https ? device.id : nil,
            host: device.ip
        )
        let session = makeSession(delegate: delegate, timeout: timeout)
        try register(session: session, transferID: transferID)
        defer {
            unregister(session: session, transferID: transferID)
            session.finishTasksAndInvalidate()
        }
        let (data, response) = try await session.data(for: request)
        return HTTPResult(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }

    private func performUpload(
        transferID: UUID,
        fileID: String,
        size: Int64,
        request: URLRequest,
        fileURL: URL,
        device: Device
    ) async throws -> HTTPResult {
        let delegate = SessionDelegate(
            expectedFingerprint: device.https ? device.id : nil,
            host: device.ip,
            onProgress: { [weak self] _, sent, _ in
                Task {
                    await self?.reportProgress(
                        transferID: transferID,
                        fileID: fileID,
                        bytes: min(size, sent),
                        force: false
                    )
                }
            }
        )
        let session = makeSession(delegate: delegate, timeout: request.timeoutInterval)
        try register(session: session, transferID: transferID)
        defer {
            unregister(session: session, transferID: transferID)
            session.finishTasksAndInvalidate()
        }
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        return HTTPResult(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }

    private func makeSession(delegate: SessionDelegate, timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.httpShouldUsePipelining = false
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func endpointURL(device: Device, scheme: String, path: String) throws -> URL {
        let host = device.ip.contains(":") && !device.ip.hasPrefix("[") ? "[\(device.ip)]" : device.ip
        guard let url = URL(string: "\(scheme)://\(host):\(device.port)\(path)") else {
            throw SenderError.invalidURL
        }
        return url
    }

    private func markAccepted(_ transferID: UUID) async {
        guard var active = activeTransfers[transferID], !active.accepted else { return }
        active.accepted = true
        activeTransfers[transferID] = active
        if let record = await transferCoordinator.record(id: transferID), record.status == .awaitingAcceptance {
            _ = try? await transferCoordinator.transition(id: transferID, to: .preparing)
        }
        onAccepted?()
    }

    private func reportProgress(
        transferID: UUID,
        fileID: String,
        bytes: Int64,
        force: Bool
    ) async {
        guard activeTransfers[transferID] != nil else { return }
        if let record = try? await transferCoordinator.updateFileProgress(
            transferID: transferID,
            fileID: fileID,
            transferredBytes: bytes,
            forceEvent: force
        ) {
            onProgress?(record.progress)
        }
    }

    private func register(session: URLSession, transferID: UUID) throws {
        try checkCancellation(transferID)
        guard var active = activeTransfers[transferID] else { throw CancellationError() }
        active.sessions[ObjectIdentifier(session)] = session
        activeTransfers[transferID] = active
    }

    private func unregister(session: URLSession, transferID: UUID) {
        guard var active = activeTransfers[transferID] else { return }
        active.sessions.removeValue(forKey: ObjectIdentifier(session))
        activeTransfers[transferID] = active
    }

    private func addCampusTransferID(_ campusID: String, to transferID: UUID) {
        guard var active = activeTransfers[transferID] else { return }
        active.campusTransferIDs.insert(campusID)
        activeTransfers[transferID] = active
    }

    private func setRemoteSession(_ remoteSession: RemoteSession, transferID: UUID) {
        guard var active = activeTransfers[transferID] else { return }
        active.remoteSession = remoteSession
        activeTransfers[transferID] = active
    }

    private func cleanupTransfer(_ transferID: UUID) {
        activeTransfers.removeValue(forKey: transferID)
        activeTransferOrder.removeAll { $0 == transferID }
    }

    private func checkCancellation(_ transferID: UUID) throws {
        guard let active = activeTransfers[transferID], !active.cancelled else { throw CancellationError() }
    }

    private func isCancellation(_ error: Error, transferID: UUID) -> Bool {
        error is CancellationError
            || (error as NSError).code == NSURLErrorCancelled
            || activeTransfers[transferID]?.cancelled == true
            || activeTransfers[transferID] == nil
    }

    private func isDecline(_ error: Error) -> Bool {
        if case SenderError.declined = error { return true }
        return false
    }

    private func isCertificateFailure(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return [
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorClientCertificateRejected,
        ].contains(code)
    }

    private func isRetryable(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            if case SenderError.fallbackTooLarge = error { return true }
            return false
        }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotFindHost,
        ].contains(nsError.code)
    }

    private func failureCode(for error: Error) -> String {
        if isCertificateFailure(error) { return "certificate_mismatch" }
        if isRetryable(error) { return "network_unavailable" }
        if case SenderError.malformedResponse = error { return "invalid_peer_response" }
        return "send_failed"
    }

    private func sendRemoteCancellation(_ remote: RemoteSession) async {
        do {
            var components = URLComponents(
                url: try endpointURL(device: remote.device, scheme: remote.scheme, path: "/api/localsend/v2/cancel"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "sessionId", value: remote.sessionID)]
            guard let url = components.url else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 4
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            let delegate = SessionDelegate(
                expectedFingerprint: remote.device.https ? remote.device.id : nil,
                host: remote.device.ip
            )
            let session = makeSession(delegate: delegate, timeout: 4)
            defer { session.finishTasksAndInvalidate() }
            _ = try await session.data(for: request)
        } catch {
            logTransfer("⚠️ Could not notify peer about cancellation: \(error.localizedDescription)")
        }
    }

    private func prepareFileContext(urls: [URL], source: TransferSource) async throws -> SendContext {
        guard !urls.isEmpty, urls.count <= 512 else { throw SenderError.noFiles }
        var files: [String: FileDto] = [:]
        var fileURLs: [String: URL] = [:]
        var historySourceURLs: [String: URL] = [:]
        var temporaryURLs: [URL] = []
        var securityScopedURLs: [URL] = []

        do {
            for sourceURL in urls {
                if sourceURL.startAccessingSecurityScopedResource() {
                    securityScopedURLs.append(sourceURL)
                }
                let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
                let finalURL: URL
                if values.isDirectory == true {
                    finalURL = try await Self.archiveDirectory(sourceURL)
                    temporaryURLs.append(finalURL)
                } else {
                    finalURL = sourceURL
                }

                let finalValues = try finalURL.resourceValues(forKeys: [.fileSizeKey, .nameKey, .contentTypeKey])
                let fileID = UUID().uuidString
                let fileName = finalValues.name ?? finalURL.lastPathComponent
                let mimeType = finalURL.pathExtension.lowercased() == "zip"
                    ? "application/zip"
                    : (finalValues.contentType?.preferredMIMEType ?? "application/octet-stream")
                let file = FileDto(
                    id: fileID,
                    fileName: fileName,
                    size: Int64(finalValues.fileSize ?? 0),
                    fileType: mimeType,
                    sha256: nil,
                    preview: nil
                )
                files[fileID] = file
                fileURLs[fileID] = finalURL
                historySourceURLs[fileID] = sourceURL
            }
        } catch {
            temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }

        let retrySpec = TransferRetrySpec(
            targetID: "",
            source: source,
            sourcePaths: urls.map(\.path)
        )
        return SendContext(
            files: files,
            fileURLs: fileURLs,
            historySourceURLs: historySourceURLs,
            temporaryURLs: temporaryURLs,
            securityScopedURLs: securityScopedURLs,
            source: source,
            previewText: nil,
            retrySpec: retrySpec
        )
    }

    nonisolated private static func archiveDirectory(_ sourceURL: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sourceURL.lastPathComponent)-\(UUID().uuidString).zip")
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", sourceURL.path, destination.path]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "Directory archive failed"
                throw SenderError.malformedResponse(message)
            }
            return destination
        }.value
    }
}
