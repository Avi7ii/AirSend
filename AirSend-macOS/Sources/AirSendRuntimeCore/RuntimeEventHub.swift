import Foundation

public enum RuntimeEventKind: String, Codable, Sendable {
    case transferChanged
    case transferCancellationRequested
    case configurationChanged
    case peersChanged
    case runtimeHealthChanged
}

public struct RuntimeEvent: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let kind: RuntimeEventKind
    public let transfer: TransferRecord?
    public let createdAt: Date

    public init(sequence: UInt64, kind: RuntimeEventKind, transfer: TransferRecord?, createdAt: Date) {
        self.sequence = sequence
        self.kind = kind
        self.transfer = transfer
        self.createdAt = createdAt
    }
}

public actor RuntimeEventHub {
    private var nextSequence: UInt64 = 1
    private var subscribers: [UUID: AsyncStream<RuntimeEvent>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<RuntimeEvent> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            subscribers[subscriberID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID) }
            }
        }
    }

    @discardableResult
    public func publish(kind: RuntimeEventKind, transfer: TransferRecord? = nil, at date: Date = Date()) -> RuntimeEvent {
        let event = RuntimeEvent(sequence: nextSequence, kind: kind, transfer: transfer, createdAt: date)
        nextSequence &+= 1
        for continuation in subscribers.values {
            continuation.yield(event)
        }
        return event
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
