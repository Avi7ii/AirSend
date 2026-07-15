import Foundation

public final class TransferCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancellationRequested: Bool {
        lock.withLock { cancelled }
    }

    fileprivate func requestCancellation() {
        lock.withLock { cancelled = true }
    }
}

public actor TransferCoordinator {
    public let events: RuntimeEventHub

    private var records: [UUID: TransferRecord] = [:]
    private var cancellationTokens: [UUID: TransferCancellationToken] = [:]
    private var lastProgressPublishAt: [UUID: ContinuousClock.Instant] = [:]
    private let recentLimitPerDirection: Int
    private let progressPublishInterval: Duration

    public init(
        events: RuntimeEventHub = RuntimeEventHub(),
        recentLimitPerDirection: Int = 30,
        progressPublishInterval: Duration = .milliseconds(100)
    ) {
        self.events = events
        self.recentLimitPerDirection = max(1, recentLimitPerDirection)
        self.progressPublishInterval = progressPublishInterval
    }

    @discardableResult
    public func register(
        id: UUID = UUID(),
        direction: TransferDirection,
        source: TransferSource,
        peer: PeerIdentity,
        files: [TransferFileRecord],
        status: TransferStatus = .queued,
        previewText: String? = nil,
        retrySpec: TransferRetrySpec? = nil,
        startedAt: Date = Date()
    ) async -> TransferRecord {
        let record = TransferRecord(
            id: id,
            direction: direction,
            source: source,
            peer: peer,
            files: files,
            status: status,
            startedAt: startedAt,
            previewText: previewText,
            retrySpec: retrySpec
        )
        records[id] = record
        cancellationTokens[id] = TransferCancellationToken()
        pruneTerminalRecordsIfNeeded(direction: direction)
        await events.publish(kind: .transferChanged, transfer: record)
        return record
    }

    public func record(id: UUID) -> TransferRecord? {
        records[id]
    }

    public func list() -> [TransferRecord] {
        records.values.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.startedAt > rhs.startedAt
        }
    }

    public func cancellationToken(for id: UUID) throws -> TransferCancellationToken {
        guard let token = cancellationTokens[id] else {
            throw TransferCoordinatorError.transferNotFound(id)
        }
        return token
    }

    @discardableResult
    public func transition(id: UUID, to nextStatus: TransferStatus, at date: Date = Date()) async throws -> TransferRecord {
        guard var record = records[id] else {
            throw TransferCoordinatorError.transferNotFound(id)
        }
        guard record.status.canTransition(to: nextStatus) else {
            throw TransferCoordinatorError.invalidTransition(from: record.status, to: nextStatus)
        }
        record.status = nextStatus
        if nextStatus.isTerminal {
            record.endedAt = date
            lastProgressPublishAt.removeValue(forKey: id)
        }
        applyFileStatuses(for: &record, transferStatus: nextStatus)
        records[id] = record
        if nextStatus.isTerminal {
            pruneTerminalRecordsIfNeeded(direction: record.direction)
        }
        await events.publish(kind: .transferChanged, transfer: record, at: date)
        return record
    }

    @discardableResult
    public func updateFileProgress(
        transferID: UUID,
        fileID: String,
        transferredBytes: Int64,
        at date: Date = Date(),
        forceEvent: Bool = false
    ) async throws -> TransferRecord {
        guard var record = records[transferID] else {
            throw TransferCoordinatorError.transferNotFound(transferID)
        }
        guard !record.status.isTerminal else {
            throw TransferCoordinatorError.terminalTransfer(transferID)
        }
        guard let fileIndex = record.files.firstIndex(where: { $0.id == fileID }) else {
            throw TransferCoordinatorError.fileNotFound(fileID)
        }

        let previousBytes = record.files[fileIndex].transferredBytes
        let boundedBytes = min(record.files[fileIndex].size, max(previousBytes, transferredBytes))
        record.files[fileIndex].transferredBytes = boundedBytes
        record.files[fileIndex].status = boundedBytes >= record.files[fileIndex].size ? .completed : .transferring
        if record.status == .queued || record.status == .preparing {
            record.status = .transferring
        }
        records[transferID] = record

        let now = ContinuousClock.now
        let shouldPublish: Bool
        if forceEvent || boundedBytes >= record.files[fileIndex].size {
            shouldPublish = true
        } else if let previousPublish = lastProgressPublishAt[transferID] {
            shouldPublish = previousPublish.duration(to: now) >= progressPublishInterval
        } else {
            shouldPublish = true
        }
        if shouldPublish {
            lastProgressPublishAt[transferID] = now
            await events.publish(kind: .transferChanged, transfer: record, at: date)
        }
        return record
    }

    @discardableResult
    public func requestCancellation(id: UUID, at date: Date = Date()) async throws -> Bool {
        guard let record = records[id], let token = cancellationTokens[id] else {
            throw TransferCoordinatorError.transferNotFound(id)
        }
        guard !record.status.isTerminal else { return false }
        token.requestCancellation()
        await events.publish(kind: .transferCancellationRequested, transfer: record, at: date)
        return true
    }

    @discardableResult
    public func finishCompleted(
        id: UUID,
        savedPathsByFile: [String: String] = [:],
        previewPathsByFile: [String: String] = [:],
        at date: Date = Date()
    ) async throws -> TransferRecord {
        guard var record = records[id] else {
            throw TransferCoordinatorError.transferNotFound(id)
        }
        for index in record.files.indices {
            record.files[index].transferredBytes = record.files[index].size
            record.files[index].status = .completed
            record.files[index].savedPath = savedPathsByFile[record.files[index].id]
            record.files[index].previewPath = previewPathsByFile[record.files[index].id]
        }
        records[id] = record
        return try await transition(id: id, to: .completed, at: date)
    }

    @discardableResult
    public func finishFailed(
        id: UUID,
        code: String,
        message: String,
        retryable: Bool,
        at date: Date = Date()
    ) async throws -> TransferRecord {
        guard var record = records[id] else {
            throw TransferCoordinatorError.transferNotFound(id)
        }
        record.failure = TransferFailure(code: code, message: message, retryable: retryable)
        records[id] = record
        return try await transition(id: id, to: .failed, at: date)
    }

    @discardableResult
    public func finishCancelled(id: UUID, at date: Date = Date()) async throws -> TransferRecord {
        try await transition(id: id, to: .cancelled, at: date)
    }

    @discardableResult
    public func finishDeclined(
        id: UUID,
        code: String = "declined",
        message: String = "Declined by recipient",
        at date: Date = Date()
    ) async throws -> TransferRecord {
        guard var record = records[id] else {
            throw TransferCoordinatorError.transferNotFound(id)
        }
        record.failure = TransferFailure(code: code, message: message, retryable: false)
        records[id] = record
        return try await transition(id: id, to: .declined, at: date)
    }

    public func remove(id: UUID) {
        records.removeValue(forKey: id)
        cancellationTokens.removeValue(forKey: id)
        lastProgressPublishAt.removeValue(forKey: id)
    }

    private func applyFileStatuses(for record: inout TransferRecord, transferStatus: TransferStatus) {
        let fileStatus: FileTransferStatus?
        switch transferStatus {
        case .transferring:
            fileStatus = .transferring
        case .completed:
            fileStatus = .completed
        case .failed:
            fileStatus = .failed
        case .cancelled:
            fileStatus = .cancelled
        default:
            fileStatus = nil
        }
        guard let fileStatus else { return }
        for index in record.files.indices where record.files[index].status != .completed {
            record.files[index].status = fileStatus
            if fileStatus == .completed {
                record.files[index].transferredBytes = record.files[index].size
            }
        }
    }

    private func pruneTerminalRecordsIfNeeded(direction: TransferDirection) {
        let terminal = records.values
            .filter { $0.direction == direction && $0.status.isTerminal }
            .sorted { $0.startedAt > $1.startedAt }
        guard terminal.count > recentLimitPerDirection else { return }
        for record in terminal.dropFirst(recentLimitPerDirection) {
            records.removeValue(forKey: record.id)
            cancellationTokens.removeValue(forKey: record.id)
            lastProgressPublishAt.removeValue(forKey: record.id)
        }
    }
}
