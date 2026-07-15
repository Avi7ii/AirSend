import Foundation

public enum TransferDirection: String, Codable, Sendable, CaseIterable {
    case outgoing
    case incoming
}

public enum TransferSource: String, Codable, Sendable, CaseIterable {
    case filePicker
    case dropZone
    case clipboard
    case clipboardImage
    case screenshot
    case shareExtension
    case remotePeer
}

public enum TransferStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case awaitingAcceptance
    case preparing
    case transferring
    case paused
    case completed
    case failed
    case cancelled
    case declined

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .declined:
            true
        default:
            false
        }
    }

    public func canTransition(to next: TransferStatus) -> Bool {
        guard self != next else { return true }
        switch self {
        case .queued:
            return [.awaitingAcceptance, .preparing, .cancelled, .failed].contains(next)
        case .awaitingAcceptance:
            return [.preparing, .declined, .cancelled, .failed].contains(next)
        case .preparing:
            return [.transferring, .completed, .cancelled, .failed].contains(next)
        case .transferring:
            return [.paused, .completed, .cancelled, .failed].contains(next)
        case .paused:
            return [.transferring, .cancelled, .failed].contains(next)
        case .completed, .failed, .cancelled, .declined:
            return false
        }
    }
}

public enum FileTransferStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case transferring
    case completed
    case failed
    case cancelled
}

public struct PeerIdentity: Codable, Hashable, Sendable {
    public var id: String
    public var alias: String
    public var fingerprint: String?
    public var address: String?

    public init(id: String, alias: String, fingerprint: String? = nil, address: String? = nil) {
        self.id = id
        self.alias = alias
        self.fingerprint = fingerprint
        self.address = address
    }
}

public struct TransferFileRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var mimeType: String
    public var size: Int64
    public var transferredBytes: Int64
    public var status: FileTransferStatus
    public var sourcePath: String?
    public var savedPath: String?
    public var previewPath: String?

    public init(
        id: String,
        name: String,
        mimeType: String,
        size: Int64,
        transferredBytes: Int64 = 0,
        status: FileTransferStatus = .queued,
        sourcePath: String? = nil,
        savedPath: String? = nil,
        previewPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = max(0, size)
        self.transferredBytes = min(max(0, transferredBytes), max(0, size))
        self.status = status
        self.sourcePath = sourcePath
        self.savedPath = savedPath
        self.previewPath = previewPath
    }
}

public struct TransferFailure: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public struct TransferRetrySpec: Codable, Hashable, Sendable {
    public var targetID: String
    public var source: TransferSource
    public var sourcePaths: [String]
    public var textPayload: String?

    public init(targetID: String, source: TransferSource, sourcePaths: [String] = [], textPayload: String? = nil) {
        self.targetID = targetID
        self.source = source
        self.sourcePaths = sourcePaths
        self.textPayload = textPayload
    }
}

public struct TransferRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var direction: TransferDirection
    public var source: TransferSource
    public var peer: PeerIdentity
    public var files: [TransferFileRecord]
    public var status: TransferStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var previewText: String?
    public var failure: TransferFailure?
    public var retrySpec: TransferRetrySpec?

    public init(
        id: UUID = UUID(),
        direction: TransferDirection,
        source: TransferSource,
        peer: PeerIdentity,
        files: [TransferFileRecord],
        status: TransferStatus = .queued,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        previewText: String? = nil,
        failure: TransferFailure? = nil,
        retrySpec: TransferRetrySpec? = nil
    ) {
        self.id = id
        self.direction = direction
        self.source = source
        self.peer = peer
        self.files = files
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.previewText = previewText
        self.failure = failure
        self.retrySpec = retrySpec
    }

    public var totalBytes: Int64 {
        files.reduce(0) { $0 + max(0, $1.size) }
    }

    public var transferredBytes: Int64 {
        min(totalBytes, files.reduce(0) { $0 + max(0, $1.transferredBytes) })
    }

    public var progress: Double {
        guard totalBytes > 0 else { return status == .completed ? 1 : 0 }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    public var isRetryable: Bool {
        failure?.retryable == true && retrySpec != nil
    }
}

public enum TransferCoordinatorError: Error, Equatable, Sendable {
    case transferNotFound(UUID)
    case fileNotFound(String)
    case invalidTransition(from: TransferStatus, to: TransferStatus)
    case terminalTransfer(UUID)
}
