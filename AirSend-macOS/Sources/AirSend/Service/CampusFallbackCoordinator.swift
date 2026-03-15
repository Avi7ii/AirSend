import Foundation

private enum CampusFallbackConstants {
    static let marker = 1
    static let chunkSize = 600
    static let windowSize = 24
    static let maxBytes = 20 * 1024 * 1024
}

private struct CampusEnvelope: Codable {
    let campusFallback: Int
    let type: String
    let transferId: String
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

    static func base(type: String, transferId: String, senderId: String, targetId: String) -> CampusEnvelope {
        CampusEnvelope(
            campusFallback: CampusFallbackConstants.marker,
            type: type,
            transferId: transferId,
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
    var accepted = false
    var windowResults: [Int: OutgoingWindowResult] = [:]
    var completion: Result<Void, CampusFailure>?
}

private struct IncomingTransferState {
    let senderId: String
    let senderAlias: String
    let fileName: String
    let fileType: String
    let totalSize: Int
    let totalChunks: Int
    var nextWindowStart: Int
    var assembled = Data()
    var windowChunks: [Int: Data] = [:]
}

actor CampusFallbackCoordinator {
    private let alias = Host.current().localizedName ?? "AirSend"
    private let fingerprint: String

    private var packetSender: (@Sendable (Data) -> Void)?
    private var onTextReceived: (@Sendable (String) -> Void)?
    private var onTransferRequest: (@Sendable (TransferRequest) async -> Bool)?
    private var getSaveDirectory: (@Sendable () -> URL)?
    private var onProgress: (@Sendable (Double) -> Void)?
    private var onTransferComplete: (@Sendable (Bool, String?) -> Void)?

    private var outgoing: [String: OutgoingTransferState] = [:]
    private var incoming: [String: IncomingTransferState] = [:]

    init(fingerprint: String) {
        self.fingerprint = fingerprint
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

    func setGetSaveDirectory(_ callback: @escaping @Sendable () -> URL) {
        self.getSaveDirectory = callback
    }

    func setOnProgress(_ callback: @escaping @Sendable (Double) -> Void) {
        self.onProgress = callback
    }

    func setOnTransferComplete(_ callback: @escaping @Sendable (Bool, String?) -> Void) {
        self.onTransferComplete = callback
    }

    func sendText(_ text: String, to device: Device) async throws {
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode text"])
        }
        try await sendPayload(
            data,
            fileName: "clipboard.txt",
            fileType: "text/plain",
            to: device,
            onAccepted: nil,
            onProgress: nil
        )
    }

    func sendFile(
        data: Data,
        fileName: String,
        fileType: String,
        to device: Device,
        onAccepted: (@Sendable () -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await sendPayload(data, fileName: fileName, fileType: fileType, to: device, onAccepted: onAccepted, onProgress: onProgress)
    }

    func handlePacket(_ data: Data, sourceIP: String) async {
        guard let envelope = try? JSONDecoder().decode(CampusEnvelope.self, from: data),
              envelope.campusFallback == CampusFallbackConstants.marker else {
            return
        }

        FileLogger.log("📦 Campus packet rx type=\(envelope.type) transfer=\(envelope.transferId) from=\(envelope.senderId) to=\(envelope.targetId) via \(sourceIP)")

        do {
            switch envelope.type {
            case "prepare":
                try await handlePrepare(envelope)
            case "chunk":
                try await handleChunk(envelope)
            case "windowEnd":
                try await handleWindowEnd(envelope)
            case "finish":
                try await handleFinish(envelope)
            case "accept", "windowAck", "windowNack", "complete":
                handleOutgoingEvent(envelope)
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
        onAccepted: (@Sendable () -> Void)?,
        onProgress progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        guard !data.isEmpty else { return }
        guard data.count <= CampusFallbackConstants.maxBytes else {
            throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Campus fallback only supports files up to \(CampusFallbackConstants.maxBytes) bytes"])
        }

        let transferId = UUID().uuidString
        let totalChunks = Int(ceil(Double(data.count) / Double(CampusFallbackConstants.chunkSize)))
        outgoing[transferId] = OutgoingTransferState()

        let prepare = CampusEnvelope(
            campusFallback: CampusFallbackConstants.marker,
            type: "prepare",
            transferId: transferId,
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
            outgoing.removeValue(forKey: transferId)
            throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Campus fallback accept timed out"])
        }

        for windowStart in stride(from: 0, to: totalChunks, by: CampusFallbackConstants.windowSize) {
            let windowEnd = min(windowStart + CampusFallbackConstants.windowSize, totalChunks)
            var pending = Array(windowStart..<windowEnd)
            var attempts = 0

            while !pending.isEmpty {
                attempts += 1
                if attempts > 6 {
                    outgoing.removeValue(forKey: transferId)
                    throw NSError(domain: "CampusFallback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Campus fallback window \(windowStart) failed"])
                }

                for chunkIndex in pending {
                    let start = chunkIndex * CampusFallbackConstants.chunkSize
                    let end = min(start + CampusFallbackConstants.chunkSize, data.count)
                    let chunkEnvelope = CampusEnvelope(
                        campusFallback: CampusFallbackConstants.marker,
                        type: "chunk",
                        transferId: transferId,
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
                    try send(envelope: chunkEnvelope)
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }

                let endEnvelope = CampusEnvelope(
                    campusFallback: CampusFallbackConstants.marker,
                    type: "windowEnd",
                    transferId: transferId,
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

        try send(envelope: CampusEnvelope.base(type: "finish", transferId: transferId, senderId: fingerprint, targetId: device.id))
        try await awaitCompletion(transferId: transferId)
        outgoing.removeValue(forKey: transferId)
        progressHandler?(1.0)
    }

    private func handlePrepare(_ envelope: CampusEnvelope) async throws {
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

        let request = TransferRequest(
            sessionId: envelope.transferId,
            senderAlias: envelope.senderAlias ?? "Campus Sender",
            fileCount: 1,
            fileNames: [fileName],
            totalSize: Int64(totalSize)
        )

        if let onTransferRequest {
            let allowed = await onTransferRequest(request)
            if !allowed {
                let denied = CampusEnvelope(
                    campusFallback: CampusFallbackConstants.marker,
                    type: "complete",
                    transferId: envelope.transferId,
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
            senderId: envelope.senderId,
            senderAlias: envelope.senderAlias ?? "Campus Sender",
            fileName: fileName,
            fileType: fileType,
            totalSize: totalSize,
            totalChunks: totalChunks,
            nextWindowStart: 0,
            assembled: Data(capacity: totalSize),
            windowChunks: [:]
        )

        try send(envelope: CampusEnvelope.base(type: "accept", transferId: envelope.transferId, senderId: fingerprint, targetId: envelope.senderId))
    }

    private func handleChunk(_ envelope: CampusEnvelope) async throws {
        guard envelope.targetId == fingerprint,
              let index = envelope.index,
              let payload = envelope.payload,
              let chunkData = Data(base64Encoded: payload) else {
            return
        }
        guard var state = incoming[envelope.transferId] else { return }
        state.windowChunks[index] = state.windowChunks[index] ?? chunkData
        incoming[envelope.transferId] = state
    }

    private func handleWindowEnd(_ envelope: CampusEnvelope) async throws {
        guard envelope.targetId == fingerprint,
              let windowStart = envelope.windowStart,
              let count = envelope.count,
              var state = incoming[envelope.transferId] else {
            return
        }

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
        }

        incoming[envelope.transferId] = state

        let response = CampusEnvelope(
            campusFallback: CampusFallbackConstants.marker,
            type: missing.isEmpty ? "windowAck" : "windowNack",
            transferId: envelope.transferId,
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
        try send(envelope: response)
    }

    private func handleFinish(_ envelope: CampusEnvelope) async throws {
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
            try persistIncoming(state)
            onTransferComplete?(true, nil)
            complete = CampusEnvelope(
                campusFallback: CampusFallbackConstants.marker,
                type: "complete",
                transferId: envelope.transferId,
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
            onTransferComplete?(false, error.localizedDescription)
            complete = CampusEnvelope(
                campusFallback: CampusFallbackConstants.marker,
                type: "complete",
                transferId: envelope.transferId,
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

        try send(envelope: complete)
    }

    private func handleOutgoingEvent(_ envelope: CampusEnvelope) {
        guard envelope.targetId == fingerprint,
              var state = outgoing[envelope.transferId] else {
            return
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

    private func awaitPrepareAccept(transferId: String, prepare: CampusEnvelope) async throws -> Bool {
        for _ in 0..<4 {
            try send(envelope: prepare)
            let deadline = Date().addingTimeInterval(0.9)
            while Date() < deadline {
                if outgoing[transferId]?.accepted == true {
                    return true
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return false
    }

    private func awaitWindowResult(transferId: String, windowStart: Int) async throws -> OutgoingWindowResult {
        let deadline = Date().addingTimeInterval(1.6)
        while Date() < deadline {
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

    private func persistIncoming(_ state: IncomingTransferState) throws {
        let baseDir = getSaveDirectory?() ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

        if state.fileType == "text/plain",
           let text = String(data: state.assembled, encoding: .utf8) {
            onTextReceived?(text)
            if state.fileName == "clipboard.txt" {
                return
            }
        }

        let safeFileName = (state.fileName as NSString).lastPathComponent
        var destinationURL = baseDir.appendingPathComponent(safeFileName)
        let ext = destinationURL.pathExtension
        let nameWithoutExt = destinationURL.deletingPathExtension().lastPathComponent
        var counter = 1
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            let newName = "\(nameWithoutExt) (\(counter))"
            destinationURL = baseDir.appendingPathComponent(newName).appendingPathExtension(ext)
            counter += 1
        }

        try state.assembled.write(to: destinationURL)
    }
}
