import Foundation
import AirSendRuntimeCore

private enum CampusFallbackConstants {
    static let marker = 1
    static let chunkSize = 600
    static let windowSize = 24
    static let maxBytes = 1 * 1024 * 1024
    static let staleTransferTimeout: TimeInterval = 90
}

private struct CampusEnvelope: Codable {
    let campusFallback: Int
    let type: String
    let transferId: String
    let sessionNonce: String
    let senderId: String
    let targetId: String
    let senderAlias: String?
    let fileName: String?
    let fileType: String?
    let totalSize: Int?
    let chunkSize: Int?
    let totalChunks: Int?
    let windowSize: Int?
    let windowStart: Int?
    let count: Int?
    let index: Int?
    let payload: String?
    let missing: [Int]?
    let success: Bool?
    let message: String?

    static func base(type: String, transferId: String, sessionNonce: String, senderId: String, targetId: String) -> CampusEnvelope {
        CampusEnvelope(
            campusFallback: CampusFallbackConstants.marker,
            type: type,
            transferId: transferId,
            sessionNonce: sessionNonce,
            senderId: senderId,
            targetId: targetId,
            senderAlias: nil,
            fileName: nil,
            fileType: nil,
            totalSize: nil,
            chunkSize: nil,
            totalChunks: nil,
            windowSize: nil,
            windowStart: nil,
            count: nil,
            index: nil,
            payload: nil,
            missing: nil,
            success: nil,
            message: nil
        )
    }
}

private struct CampusMarkerProbe: Decodable {
    let campusFallback: Int?
}

private enum OutgoingWindowResult {
    case ack
    case nack([Int])
}

private struct CampusFailure: Error {
    let message: String
}

private struct OutgoingTransferState {
    let sessionNonce: String
    var accepted = false
    var expectedSourceIP: String?
    var windowResults: [Int: OutgoingWindowResult] = [:]
    var completion: Result<Void, CampusFailure>?
    var cancelled = false
    var lastActivityAt = Date()
}

private struct IncomingTransferState {
    let runtimeID: UUID
    let fileID: String
    let senderId: String
    let senderAlias: String
    let sessionNonce: String
    let sourceIP: String
    let fileName: String
    let fileType: String
    let totalSize: Int
    let totalChunks: Int
    var nextWindowStart: Int
    var assembled = Data()
    var windowChunks: [Int: Data] = [:]
    var lastActivityAt = Date()
}

actor CampusFallbackCoordinator {
    nonisolated static var maximumPayloadBytes: Int { CampusFallbackConstants.maxBytes }

    private let alias = Host.current().localizedName ?? "AirSend"
    private let fingerprint: String
    private let transferCoordinator: TransferCoordinator

    private var packetSender: (@Sendable (Data) -> Void)?
    private var onTextReceived: (@Sendable (String) -> Void)?
    private var onTransferRequest: (@Sendable (TransferRequest) async -> Bool)?
    private var getSaveDirectory: (@Sendable (String, String) -> URL)?
    private var onProgress: (@Sendable (Double) -> Void)?
    private var onTransferComplete: (@Sendable (Bool, String?) -> Void)?

    private var outgoing: [String: OutgoingTransferState] = [:]
    private var incoming: [String: IncomingTransferState] = [:]

    init(fingerprint: String, transferCoordinator: TransferCoordinator) {
        self.fingerprint = fingerprint
        self.transferCoordinator = transferCoordinator
    }

    nonisolated static func looksLikeCampusPacket(_ data: Data) -> Bool {
        guard let probe = try? JSONDecoder().decode(CampusMarkerProbe.self, from: data) else {
            return false
        }
        return probe.campusFallback == CampusFallbackConstants.marker
    }

    func setPacketSender(_ callback: @escaping @Sendable (Data) -> Void) {
        self.packetSender = callback
    }

    func setOnTextReceived(_ callback: @escaping @Sendable (String) -> Void) {
        self.onTextReceived = callback
    }

    func setOnTransferRequest(_ callback: @escaping @Sendable (TransferRequest) async -> Bool) {
        self.onTransferRequest = callback
    }

    func setGetSaveDirectory(_ callback: @escaping @Sendable (String, String) -> URL) {
        self.getSaveDirectory = callback
    }

    func setOnProgress(_ callback: @escaping @Sendable (Double) -> Void) {
        self.onProgress = callback
    }

    func setOnTransferComplete(_ callback: @escaping @Sendable (Bool, String?) -> Void) {
        self.onTransferComplete = callback
    }

    func sendText(_ text: String, to device: Device, transferID: String? = nil) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode text"])
        }
        try await sendPayload(
            data,
            fileName: "clipboard.txt",
            fileType: "text/plain",
            to: device,
            transferID: transferID,
            onAccepted: nil,
            onProgress: nil
        )
    }

    func sendFile(
        data: Data,
        fileName: String,
        fileType: String,
        to device: Device,
        transferID: String? = nil,
        onAccepted: (@Sendable () -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await sendPayload(
            data,
            fileName: fileName,
            fileType: fileType,
            to: device,
            transferID: transferID,
            onAccepted: onAccepted,
            onProgress: onProgress
        )
    }

    func cancelOutgoingTransfer(_ transferID: String) {
        guard var state = outgoing[transferID] else { return }
        state.cancelled = true
        if state.completion == nil {
            state.completion = .failure(CampusFailure(message: "Campus transfer cancelled"))
        }
        state.lastActivityAt = Date()
        outgoing[transferID] = state
    }

    func cancelAllOutgoingTransfers() {
        let transferIds = Array(outgoing.keys)
        guard !transferIds.isEmpty else { return }

        for transferId in transferIds {
            guard var state = outgoing[transferId] else { continue }
            state.cancelled = true
            if state.completion == nil {
                state.completion = .failure(CampusFailure(message: "Campus transfer cancelled"))
            }
            state.lastActivityAt = Date()
            outgoing[transferId] = state
        }

        FileLogger.log("🛑 Campus fallback cancelled \(transferIds.count) outgoing transfer(s)")
    }

    func cancelIncomingTransfer(_ runtimeID: UUID) async -> Bool {
        guard let entry = incoming.first(where: { $0.value.runtimeID == runtimeID }) else {
            return false
        }
        let transferID = entry.key
        let state = entry.value
        incoming.removeValue(forKey: transferID)
        _ = try? await transferCoordinator.finishCancelled(id: runtimeID)
        let response = CampusEnvelope(
            campusFallback: CampusFallbackConstants.marker,
            type: "complete",
            transferId: transferID,
            sessionNonce: state.sessionNonce,
            senderId: fingerprint,
            targetId: state.senderId,
            senderAlias: nil,
            fileName: nil,
            fileType: nil,
            totalSize: nil,
            chunkSize: nil,
            totalChunks: nil,
            windowSize: nil,
            windowStart: nil,
            count: nil,
            index: nil,
            payload: nil,
            missing: nil,
            success: false,
            message: "Cancelled"
        )
        try? await sendRepeated(envelope: response)
        onTransferComplete?(false, "Cancelled")
        return true
    }

    func handlePacket(_ data: Data, sourceIP: String) async {
        await pruneStaleTransfers()

        guard let envelope = try? JSONDecoder().decode(CampusEnvelope.self, from: data),
              envelope.campusFallback == CampusFallbackConstants.marker else {
            return
        }

        FileLogger.log("📦 Campus packet rx type=\(envelope.type) transfer=\(envelope.transferId) from=\(envelope.senderId) to=\(envelope.targetId) via \(sourceIP)")

        do {
            switch envelope.type {
            case "prepare":
                try await handlePrepare(envelope, sourceIP: sourceIP)
            case "chunk":
                try await handleChunk(envelope, sourceIP: sourceIP)
            case "windowEnd":
                try await handleWindowEnd(envelope, sourceIP: sourceIP)
            case "finish":
                try await handleFinish(envelope, sourceIP: sourceIP)
            case "accept", "windowAck", "windowNack", "complete":
                handleOutgoingEvent(envelope, sourceIP: sourceIP)
            default:
                break
            }
        } catch {
            FileLogger.log("❌ Campus fallback packet handling failed from \(sourceIP): \(error.localizedDescription)")
        }
    }

    private func sendPayload(
        _ data: Data,
        fileName: String,
        fileType: String,
        to device: Device,
        transferID requestedTransferID: String?,
        onAccepted: (@Sendable () -> Void)?,
        onProgress progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        await pruneStaleTransfers()

        guard !data.isEmpty else { return }
        guard data.count <= CampusFallbackConstants.maxBytes else {
            throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Campus fallback only supports files up to \(CampusFallbackConstants.maxBytes) bytes"])
        }

        let transferId = requestedTransferID ?? UUID().uuidString
        let sessionNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let totalChunks = Int(ceil(Double(data.count) / Double(CampusFallbackConstants.chunkSize)))
        outgoing[transferId] = OutgoingTransferState(sessionNonce: sessionNonce)
        defer { outgoing.removeValue(forKey: transferId) }

        let prepare = CampusEnvelope(
            campusFallback: CampusFallbackConstants.marker,
            type: "prepare",
            transferId: transferId,
            sessionNonce: sessionNonce,
            senderId: fingerprint,
            targetId: device.id,
            senderAlias: alias,
            fileName: fileName,
            fileType: fileType,
            totalSize: data.count,
            chunkSize: CampusFallbackConstants.chunkSize,
            totalChunks: totalChunks,
            windowSize: CampusFallbackConstants.windowSize,
            windowStart: nil,
            count: nil,
            index: nil,
            payload: nil,
            missing: nil,
            success: nil,
            message: nil
        )

        let accepted = try await awaitPrepareAccept(transferId: transferId, prepare: prepare)
        if accepted {
            onAccepted?()
        } else {
            throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Campus fallback accept timed out"])
        }

        for windowStart in stride(from: 0, to: totalChunks, by: CampusFallbackConstants.windowSize) {
            _ = try ensureOutgoingActive(transferId)
            let windowEnd = min(windowStart + CampusFallbackConstants.windowSize, totalChunks)
            var pending = Array(windowStart..<windowEnd)
            var attempts = 0

            while !pending.isEmpty {
                _ = try ensureOutgoingActive(transferId)
                attempts += 1
                if attempts > 6 {
                    throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Campus fallback window \(windowStart) failed"])
                }

                for chunkIndex in pending {
                    _ = try ensureOutgoingActive(transferId)
                    let start = chunkIndex * CampusFallbackConstants.chunkSize
                    let end = min(start + CampusFallbackConstants.chunkSize, data.count)
                    let chunkEnvelope = CampusEnvelope(
                        campusFallback: CampusFallbackConstants.marker,
                        type: "chunk",
                        transferId: transferId,
                        sessionNonce: sessionNonce,
                        senderId: fingerprint,
                        targetId: device.id,
                        senderAlias: nil,
                        fileName: nil,
                        fileType: nil,
                        totalSize: nil,
                        chunkSize: nil,
                        totalChunks: nil,
                        windowSize: nil,
                        windowStart: windowStart,
                        count: nil,
                        index: chunkIndex,
                        payload: data[start..<end].base64EncodedString(),
                        missing: nil,
                        success: nil,
                        message: nil
                    )
                    touchOutgoing(transferId)
                    try send(envelope: chunkEnvelope)
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }

                let endEnvelope = CampusEnvelope(
                    campusFallback: CampusFallbackConstants.marker,
                    type: "windowEnd",
                    transferId: transferId,
                    sessionNonce: sessionNonce,
                    senderId: fingerprint,
                    targetId: device.id,
                    senderAlias: nil,
                    fileName: nil,
                    fileType: nil,
                    totalSize: nil,
                    chunkSize: nil,
                    totalChunks: nil,
                    windowSize: nil,
                    windowStart: windowStart,
                    count: windowEnd - windowStart,
                    index: nil,
                    payload: nil,
                    missing: nil,
                    success: nil,
                    message: nil
                )
                touchOutgoing(transferId)
                try send(envelope: endEnvelope)

                switch try await awaitWindowResult(transferId: transferId, windowStart: windowStart) {
                case .ack:
                    pending.removeAll()
                    let sentBytes = min(windowEnd * CampusFallbackConstants.chunkSize, data.count)
                    progressHandler?(Double(sentBytes) / Double(data.count))
                case .nack(let missing):
                    pending = missing
                }
            }
        }

        _ = try ensureOutgoingActive(transferId)
        touchOutgoing(transferId)
        try send(envelope: CampusEnvelope.base(type: "finish", transferId: transferId, sessionNonce: sessionNonce, senderId: fingerprint, targetId: device.id))
        try await awaitCompletion(transferId: transferId)
        progressHandler?(1.0)
    }

    private func handlePrepare(_ envelope: CampusEnvelope, sourceIP: String) async throws {
        guard envelope.targetId == fingerprint else { return }
        guard let fileName = envelope.fileName,
              let fileType = envelope.fileType,
              let totalSize = envelope.totalSize,
              let totalChunks = envelope.totalChunks,
              totalSize > 0,
              totalChunks > 0,
              totalSize <= CampusFallbackConstants.maxBytes else {
            return
        }

        if let existing = incoming[envelope.transferId],
           existing.sourceIP == sourceIP,
           existing.sessionNonce == envelope.sessionNonce,
           existing.senderId == envelope.senderId {
            var refreshed = existing
            refreshed.lastActivityAt = Date()
            incoming[envelope.transferId] = refreshed
            try await sendRepeated(
                envelope: CampusEnvelope.base(
                    type: "accept",
                    transferId: envelope.transferId,
                    sessionNonce: envelope.sessionNonce,
                    senderId: fingerprint,
                    targetId: envelope.senderId
                )
            )
            return
        }

        let request = TransferRequest(
            sessionId: envelope.transferId,
            senderAlias: envelope.senderAlias ?? "Campus Sender",
            senderFingerprint: envelope.senderId,
            fileCount: 1,
            fileNames: [fileName],
            totalSize: Int64(totalSize)
        )

        let runtimeID = UUID(uuidString: envelope.transferId) ?? UUID()
        let fileID = "campus-file"
        await transferCoordinator.register(
            id: runtimeID,
            direction: .incoming,
            source: .remotePeer,
            peer: PeerIdentity(
                id: envelope.senderId,
                alias: envelope.senderAlias ?? "Campus Sender",
                fingerprint: envelope.senderId,
                address: sourceIP
            ),
            files: [
                TransferFileRecord(
                    id: fileID,
                    name: fileName,
                    mimeType: fileType,
                    size: Int64(totalSize)
                )
            ],
            status: .awaitingAcceptance,
            previewText: fileName == "clipboard.txt" && fileType == "text/plain" ? "Clipboard text" : nil
        )

        if let onTransferRequest {
            let allowed = await onTransferRequest(request)
            if !allowed {
                _ = try? await transferCoordinator.finishDeclined(id: runtimeID)
                let denied = CampusEnvelope(
                    campusFallback: CampusFallbackConstants.marker,
                    type: "complete",
                    transferId: envelope.transferId,
                    sessionNonce: envelope.sessionNonce,
                    senderId: fingerprint,
                    targetId: envelope.senderId,
                    senderAlias: nil,
                    fileName: nil,
                    fileType: nil,
                    totalSize: nil,
                    chunkSize: nil,
                    totalChunks: nil,
                    windowSize: nil,
                    windowStart: nil,
                    count: nil,
                    index: nil,
                    payload: nil,
                    missing: nil,
                    success: false,
                    message: "Declined"
                )
                try send(envelope: denied)
                return
            }
        }

        incoming[envelope.transferId] = IncomingTransferState(
            runtimeID: runtimeID,
            fileID: fileID,
            senderId: envelope.senderId,
            senderAlias: envelope.senderAlias ?? "Campus Sender",
            sessionNonce: envelope.sessionNonce,
            sourceIP: sourceIP,
            fileName: fileName,
            fileType: fileType,
            totalSize: totalSize,
            totalChunks: totalChunks,
            nextWindowStart: 0,
            assembled: Data(capacity: totalSize),
            windowChunks: [:]
        )
        _ = try? await transferCoordinator.transition(id: runtimeID, to: .preparing)

        try await sendRepeated(
            envelope: CampusEnvelope.base(
                type: "accept",
                transferId: envelope.transferId,
                sessionNonce: envelope.sessionNonce,
                senderId: fingerprint,
                targetId: envelope.senderId
            )
        )
    }

    private func handleChunk(_ envelope: CampusEnvelope, sourceIP: String) async throws {
        guard envelope.targetId == fingerprint,
              let index = envelope.index,
              let payload = envelope.payload,
              let chunkData = Data(base64Encoded: payload) else {
            return
        }
        guard var state = incoming[envelope.transferId] else { return }
        guard state.sourceIP == sourceIP, state.sessionNonce == envelope.sessionNonce else { return }
        guard index >= 0, index < state.totalChunks else { return }
        state.windowChunks[index] = state.windowChunks[index] ?? chunkData
        state.lastActivityAt = Date()
        incoming[envelope.transferId] = state
    }

    private func handleWindowEnd(_ envelope: CampusEnvelope, sourceIP: String) async throws {
        guard envelope.targetId == fingerprint,
              let windowStart = envelope.windowStart,
              let count = envelope.count,
              var state = incoming[envelope.transferId] else {
            return
        }
        guard state.sourceIP == sourceIP, state.sessionNonce == envelope.sessionNonce else { return }

        let windowEnd = min(windowStart + count, state.totalChunks)
        var missing: [Int] = []
        for index in windowStart..<windowEnd where state.windowChunks[index] == nil {
            missing.append(index)
        }

        if missing.isEmpty && state.nextWindowStart == windowStart {
            for index in windowStart..<windowEnd {
                if let chunk = state.windowChunks.removeValue(forKey: index) {
                    state.assembled.append(chunk)
                }
            }
            state.nextWindowStart = windowEnd
            onProgress?(Double(state.assembled.count) / Double(state.totalSize))
            _ = try? await transferCoordinator.updateFileProgress(
                transferID: state.runtimeID,
                fileID: state.fileID,
                transferredBytes: Int64(state.assembled.count),
                forceEvent: state.assembled.count == state.totalSize
            )
        }

        state.lastActivityAt = Date()
        incoming[envelope.transferId] = state

        let response = CampusEnvelope(
            campusFallback: CampusFallbackConstants.marker,
            type: missing.isEmpty ? "windowAck" : "windowNack",
            transferId: envelope.transferId,
            sessionNonce: state.sessionNonce,
            senderId: fingerprint,
            targetId: state.senderId,
            senderAlias: nil,
            fileName: nil,
            fileType: nil,
            totalSize: nil,
            chunkSize: nil,
            totalChunks: nil,
            windowSize: nil,
            windowStart: windowStart,
            count: nil,
            index: nil,
            payload: nil,
            missing: missing.isEmpty ? nil : missing,
            success: nil,
            message: nil
        )
        try await sendRepeated(envelope: response)
    }

    private func handleFinish(_ envelope: CampusEnvelope, sourceIP: String) async throws {
        guard let currentState = incoming[envelope.transferId],
              currentState.sourceIP == sourceIP,
              currentState.sessionNonce == envelope.sessionNonce else {
            return
        }
        guard envelope.targetId == fingerprint,
              let state = incoming.removeValue(forKey: envelope.transferId) else {
            return
        }

        let complete: CampusEnvelope
        do {
            guard state.assembled.count == state.totalSize,
                  state.nextWindowStart == state.totalChunks else {
                throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transfer incomplete"])
            }
            let result = try persistIncoming(state)
            _ = try await transferCoordinator.finishCompleted(
                id: state.runtimeID,
                savedPathsByFile: result.savedPath.map { [state.fileID: $0] } ?? [:],
                previewPathsByFile: result.previewPath.map { [state.fileID: $0] } ?? [:]
            )
            onTransferComplete?(true, nil)
            complete = CampusEnvelope(
                campusFallback: CampusFallbackConstants.marker,
                type: "complete",
                transferId: envelope.transferId,
                sessionNonce: state.sessionNonce,
                senderId: fingerprint,
                targetId: state.senderId,
                senderAlias: nil,
                fileName: nil,
                fileType: nil,
                totalSize: nil,
                chunkSize: nil,
                totalChunks: nil,
                windowSize: nil,
                windowStart: nil,
                count: nil,
                index: nil,
                payload: nil,
                missing: nil,
                success: true,
                message: nil
            )
        } catch {
            _ = try? await transferCoordinator.finishFailed(
                id: state.runtimeID,
                code: "campus_receive_failed",
                message: error.localizedDescription,
                retryable: false
            )
            onTransferComplete?(false, error.localizedDescription)
            complete = CampusEnvelope(
                campusFallback: CampusFallbackConstants.marker,
                type: "complete",
                transferId: envelope.transferId,
                sessionNonce: state.sessionNonce,
                senderId: fingerprint,
                targetId: state.senderId,
                senderAlias: nil,
                fileName: nil,
                fileType: nil,
                totalSize: nil,
                chunkSize: nil,
                totalChunks: nil,
                windowSize: nil,
                windowStart: nil,
                count: nil,
                index: nil,
                payload: nil,
                missing: nil,
                success: false,
                message: error.localizedDescription
            )
        }

        try await sendRepeated(envelope: complete)
    }

    private func handleOutgoingEvent(_ envelope: CampusEnvelope, sourceIP: String) {
        guard envelope.targetId == fingerprint,
              var state = outgoing[envelope.transferId] else {
            return
        }
        guard state.sessionNonce == envelope.sessionNonce else { return }

        if let expectedSourceIP = state.expectedSourceIP {
            guard expectedSourceIP == sourceIP else { return }
        } else {
            guard envelope.type == "accept" else { return }
            state.expectedSourceIP = sourceIP
        }

        switch envelope.type {
        case "accept":
            state.accepted = true
        case "windowAck":
            if let windowStart = envelope.windowStart {
                state.windowResults[windowStart] = .ack
            }
        case "windowNack":
            if let windowStart = envelope.windowStart {
                if case .ack = state.windowResults[windowStart] {
                    break
                }
                state.windowResults[windowStart] = .nack(envelope.missing ?? [])
            }
        case "complete":
            if case .success = state.completion {
                break
            }
            if envelope.success == true {
                state.completion = Result<Void, CampusFailure>.success(())
            } else if state.completion == nil {
                state.completion = Result<Void, CampusFailure>.failure(
                    CampusFailure(message: envelope.message ?? "Campus transfer failed")
                )
            }
        default:
            break
        }

        state.lastActivityAt = Date()
        outgoing[envelope.transferId] = state
    }

    private func send(envelope: CampusEnvelope) throws {
        guard let packetSender else {
            throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Campus packet sender is not configured"])
        }
        let data = try JSONEncoder().encode(envelope)
        FileLogger.log("📤 Campus packet tx type=\(envelope.type) transfer=\(envelope.transferId) from=\(envelope.senderId) to=\(envelope.targetId)")
        packetSender(data)
    }

    private func sendRepeated(envelope: CampusEnvelope, attempts: Int = 3, delayNanoseconds: UInt64 = 120_000_000) async throws {
        for attempt in 0..<attempts {
            try send(envelope: envelope)
            if attempt + 1 < attempts {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
    }

    private func awaitPrepareAccept(transferId: String, prepare: CampusEnvelope) async throws -> Bool {
        for _ in 0..<6 {
            _ = try ensureOutgoingActive(transferId)
            touchOutgoing(transferId)
            try send(envelope: prepare)
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                await pruneStaleTransfers()
                let state = try ensureOutgoingActive(transferId)
                if state.accepted {
                    return true
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return false
    }

    private func awaitWindowResult(transferId: String, windowStart: Int) async throws -> OutgoingWindowResult {
        let deadline = Date().addingTimeInterval(3.5)
        while Date() < deadline {
            await pruneStaleTransfers()
            _ = try ensureOutgoingActive(transferId)
            if let result = outgoing[transferId]?.windowResults.removeValue(forKey: windowStart) {
                return result
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for campus window \(windowStart)"])
    }

    private func awaitCompletion(transferId: String) async throws {
        let deadline = Date().addingTimeInterval(6.0)
        while Date() < deadline {
            await pruneStaleTransfers()
            _ = try ensureOutgoingActive(transferId)
            if let result = outgoing[transferId]?.completion {
                switch result {
                case .success:
                    return
                case .failure(let failure):
                    throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: failure.message])
                }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for campus completion"])
    }

    private func persistIncoming(_ state: IncomingTransferState) throws -> (savedPath: String?, previewPath: String?) {
        if state.fileName == "clipboard.txt", state.fileType == "text/plain" {
            guard let text = String(data: state.assembled, encoding: .utf8) else {
                throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Clipboard text is not valid UTF-8"])
            }
            onTextReceived?(text)
            return (nil, nil)
        }

        let baseDir = getSaveDirectory?(state.fileName, state.fileType)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let safeFileName = (state.fileName as NSString).lastPathComponent
        guard !safeFileName.isEmpty, safeFileName != ".", safeFileName != ".." else {
            throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid file name"])
        }
        var destinationURL = baseDir.appendingPathComponent(safeFileName)
        let ext = destinationURL.pathExtension
        let nameWithoutExt = destinationURL.deletingPathExtension().lastPathComponent
        var counter = 1
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            let newName = "\(nameWithoutExt) (\(counter))"
            destinationURL = baseDir.appendingPathComponent(newName).appendingPathExtension(ext)
            counter += 1
        }

        try state.assembled.write(to: destinationURL, options: .atomic)
        let mimeType = state.fileType.lowercased()
        let previewPath = mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/") ? destinationURL.path : nil
        return (destinationURL.path, previewPath)
    }

    private func touchOutgoing(_ transferId: String) {
        guard var state = outgoing[transferId] else { return }
        state.lastActivityAt = Date()
        outgoing[transferId] = state
    }

    private func pruneStaleTransfers(now: Date = Date()) async {
        let staleIncoming = incoming.compactMap { transferId, state in
            now.timeIntervalSince(state.lastActivityAt) > CampusFallbackConstants.staleTransferTimeout ? transferId : nil
        }
        for transferId in staleIncoming {
            if let state = incoming.removeValue(forKey: transferId) {
                _ = try? await transferCoordinator.finishFailed(
                    id: state.runtimeID,
                    code: "campus_receive_timeout",
                    message: "Campus fallback transfer timed out",
                    retryable: false
                )
            }
        }

        let staleOutgoing = outgoing.compactMap { transferId, state in
            now.timeIntervalSince(state.lastActivityAt) > CampusFallbackConstants.staleTransferTimeout ? transferId : nil
        }
        for transferId in staleOutgoing {
            outgoing.removeValue(forKey: transferId)
        }

        if !staleIncoming.isEmpty || !staleOutgoing.isEmpty {
            FileLogger.log("🧹 Campus fallback pruned stale transfers incoming=\(staleIncoming.count) outgoing=\(staleOutgoing.count)")
        }
    }

    private func ensureOutgoingActive(_ transferId: String) throws -> OutgoingTransferState {
        guard let state = outgoing[transferId] else {
            throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Campus fallback state expired"])
        }
        if state.cancelled {
            outgoing.removeValue(forKey: transferId)
            throw CancellationError()
        }
        return state
    }
}
