import AirSendRuntimeCore
import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.assertion(message) }
}

func sampleFile(id: String = "file-1", size: Int64 = 100) -> TransferFileRecord {
    TransferFileRecord(id: id, name: "sample.bin", mimeType: "application/octet-stream", size: size)
}

@main
struct AirSendRuntimeCoreSelfTests {
    static func main() async throws {
        try await testIndependentCancellation()
        try await testMonotonicProgress()
        try await testStateValidation()
        try await testOrderedEvents()
        try await testDirectionalRetention()
        try await testConfigurationRoundTripAndRecovery()
        try await testHistoryPersistenceAndPruning()
        try await testCompletionMetadataAndDeclineFailure()
        try testCapabilityContract()
        print("AirSendRuntimeCoreSelfTests passed")
    }

    private static func testIndependentCancellation() async throws {
        let coordinator = TransferCoordinator()
        let peer = PeerIdentity(id: "peer", alias: "Phone")
        let first = await coordinator.register(direction: .outgoing, source: .dropZone, peer: peer, files: [sampleFile(id: "a")])
        let second = await coordinator.register(direction: .outgoing, source: .clipboard, peer: peer, files: [sampleFile(id: "b")])
        let firstToken = try await coordinator.cancellationToken(for: first.id)
        let secondToken = try await coordinator.cancellationToken(for: second.id)

        _ = try await coordinator.requestCancellation(id: first.id)
        try expect(firstToken.isCancellationRequested, "first transfer should be cancelled")
        try expect(!secondToken.isCancellationRequested, "cancelling one transfer must not cancel another")
    }

    private static func testMonotonicProgress() async throws {
        let coordinator = TransferCoordinator()
        let transfer = await coordinator.register(
            direction: .outgoing,
            source: .filePicker,
            peer: PeerIdentity(id: "peer", alias: "Phone"),
            files: [sampleFile(size: 100)]
        )
        _ = try await coordinator.updateFileProgress(transferID: transfer.id, fileID: "file-1", transferredBytes: 70)
        let regressed = try await coordinator.updateFileProgress(transferID: transfer.id, fileID: "file-1", transferredBytes: 20)
        try expect(regressed.transferredBytes == 70, "progress must never move backwards")
        let bounded = try await coordinator.updateFileProgress(transferID: transfer.id, fileID: "file-1", transferredBytes: 500)
        try expect(bounded.transferredBytes == 100, "progress must not exceed file size")
    }

    private static func testStateValidation() async throws {
        let coordinator = TransferCoordinator()
        let transfer = await coordinator.register(
            direction: .incoming,
            source: .remotePeer,
            peer: PeerIdentity(id: "peer", alias: "Mac"),
            files: [sampleFile()],
            status: .awaitingAcceptance
        )
        do {
            _ = try await coordinator.transition(id: transfer.id, to: .completed)
            throw TestFailure.assertion("awaiting acceptance must not jump to completed")
        } catch let error as TransferCoordinatorError {
            try expect(error == .invalidTransition(from: .awaitingAcceptance, to: .completed), "unexpected transition error")
        }
    }

    private static func testOrderedEvents() async throws {
        let hub = RuntimeEventHub()
        let stream = await hub.stream()
        let collector = Task { () -> [RuntimeEvent] in
            var events: [RuntimeEvent] = []
            for await event in stream {
                events.append(event)
                if events.count == 2 { break }
            }
            return events
        }
        await Task.yield()
        await hub.publish(kind: .runtimeHealthChanged)
        await hub.publish(kind: .peersChanged)
        let events = await collector.value
        try expect(events.map(\.sequence) == [1, 2], "runtime events must be ordered")
    }

    private static func testDirectionalRetention() async throws {
        let coordinator = TransferCoordinator(recentLimitPerDirection: 2)
        let peer = PeerIdentity(id: "peer", alias: "Phone")
        for index in 0..<3 {
            let transfer = await coordinator.register(
                direction: .outgoing,
                source: .filePicker,
                peer: peer,
                files: [sampleFile(id: "out-\(index)")],
                startedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            _ = try await coordinator.transition(id: transfer.id, to: .preparing)
            _ = try await coordinator.finishCompleted(id: transfer.id)
        }
        let incoming = await coordinator.register(
            direction: .incoming,
            source: .remotePeer,
            peer: peer,
            files: [sampleFile(id: "incoming")],
            status: .awaitingAcceptance
        )
        _ = try await coordinator.finishDeclined(id: incoming.id)

        let records = await coordinator.list()
        try expect(records.filter { $0.direction == .outgoing }.count == 2, "outgoing retention should be bounded")
        try expect(records.filter { $0.direction == .incoming }.count == 1, "incoming retention should be independent")
    }

    private static func testConfigurationRoundTripAndRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("airsend-config-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("runtime-config.json")
        let store = RuntimeConfigurationStore(fileURL: fileURL)
        var configuration = AirSendRuntimeConfiguration()
        configuration.preferredTargetID = "peer-1"
        configuration.receivePolicy = .trustedOnly
        configuration.trustedPeerFingerprints = ["AA:BB", "aabb"]
        try await store.save(configuration)
        let loaded = try await store.load()
        try expect(loaded.configuration.preferredTargetID == "peer-1", "configuration should round-trip")
        try expect(loaded.configuration.trustedPeerFingerprints == ["aabb"], "fingerprints should normalize and deduplicate")

        try Data("not-json".utf8).write(to: fileURL)
        let recovered = try await store.load()
        try expect(recovered.warning != nil, "invalid configuration should report recovery")
        try expect(recovered.recoveredFile != nil, "invalid configuration should be preserved")
    }

    private static func testHistoryPersistenceAndPruning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("airsend-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TransferHistoryStore(fileURL: directory.appendingPathComponent("history.sqlite3"), retentionLimitPerDirection: 2)
        let peer = PeerIdentity(id: "peer", alias: "Phone")

        let nonTerminal = TransferRecord(direction: .outgoing, source: .filePicker, peer: peer, files: [sampleFile()])
        do {
            try await store.persist(nonTerminal)
            throw TestFailure.assertion("non-terminal records must not be persisted")
        } catch TransferHistoryError.nonTerminalRecord {
        }

        for index in 0..<3 {
            var record = TransferRecord(
                direction: .outgoing,
                source: .filePicker,
                peer: peer,
                files: [sampleFile(id: "file-\(index)")],
                status: .completed,
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                endedAt: Date(timeIntervalSince1970: TimeInterval(index + 10))
            )
            record.files[0].status = .completed
            record.files[0].transferredBytes = record.files[0].size
            try await store.persist(record)
        }
        var incoming = TransferRecord(
            direction: .incoming,
            source: .remotePeer,
            peer: peer,
            files: [sampleFile(id: "incoming")],
            status: .declined,
            endedAt: Date()
        )
        incoming.failure = TransferFailure(code: "declined", message: "Declined", retryable: false)
        try await store.persist(incoming)

        let outgoingCount = try await store.count(direction: .outgoing)
        let incomingCount = try await store.count(direction: .incoming)
        try expect(outgoingCount == 2, "history should prune outgoing records")
        try expect(incomingCount == 1, "history should retain incoming independently")
        let loaded = try await store.list(limit: 10)
        try expect(loaded.count == 3, "history should decode stored records")
        try await store.clear(direction: .incoming)
        let clearedIncomingCount = try await store.count(direction: .incoming)
        try expect(clearedIncomingCount == 0, "directional history clear should work")
    }

    private static func testCompletionMetadataAndDeclineFailure() async throws {
        let coordinator = TransferCoordinator()
        let incoming = await coordinator.register(
            direction: .incoming,
            source: .remotePeer,
            peer: PeerIdentity(id: "phone", alias: "Phone"),
            files: [sampleFile(id: "photo", size: 10)],
            status: .awaitingAcceptance
        )
        _ = try await coordinator.transition(id: incoming.id, to: .preparing)
        let completed = try await coordinator.finishCompleted(
            id: incoming.id,
            savedPathsByFile: ["photo": "/tmp/photo.png"],
            previewPathsByFile: ["photo": "/tmp/photo.png"]
        )
        try expect(completed.files[0].savedPath == "/tmp/photo.png", "completion should retain saved paths")
        try expect(completed.files[0].previewPath == "/tmp/photo.png", "completion should retain preview paths")

        let declined = await coordinator.register(
            direction: .incoming,
            source: .remotePeer,
            peer: PeerIdentity(id: "unknown", alias: "Unknown"),
            files: [sampleFile()],
            status: .awaitingAcceptance
        )
        let terminal = try await coordinator.finishDeclined(
            id: declined.id,
            code: "untrusted_peer",
            message: "Peer is not trusted"
        )
        try expect(terminal.status == .declined, "declined transfer should be terminal")
        try expect(terminal.failure?.code == "untrusted_peer", "decline should retain a structured reason")
        try expect(terminal.failure?.retryable == false, "declined incoming transfer must not be retryable")
    }

    private static func testCapabilityContract() throws {
        let required = Set([
            "runtime_snapshot",
            "runtime_events",
            "peer_discovery",
            "manual_peers",
            "receive_policy",
            "send_text",
            "send_files",
            "active_transfers",
            "cancel_transfer",
            "retry_transfer",
            "accept_transfer",
            "decline_transfer",
            "directional_history",
            "destination_configuration",
            "runtime_restart",
        ])
        try expect(
            required.isSubset(of: AirSendRuntimeCapabilities.current),
            "runtime capability reporting must cover the Android semantic contract"
        )
    }
}
