import AirSendDiscoverySupport
import Dispatch
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(description: message)
    }
}

func testSnapshotNormalizationAndReplacement() throws {
    let store = PreferredDiscoveryHostsStore(
        initialHosts: [" 192.168.1.20 ", "", "192.168.1.20", "10.0.0.8"]
    )

    try expect(
        store.snapshot() == ["192.168.1.20", "10.0.0.8"],
        "the snapshot should trim, remove empty values, and preserve first-seen order"
    )

    store.replace(with: ["172.16.0.4"])
    try expect(
        store.snapshot() == ["172.16.0.4"],
        "replacement should atomically discard the previous snapshot"
    )
}

func testConcurrentReadersNeverObserveATornSnapshot() {
    let first = (1...32).map { "10.0.0.\($0)" }
    let second = (1...32).map { "192.168.1.\($0)" }
    let store = PreferredDiscoveryHostsStore(initialHosts: first)

    DispatchQueue.concurrentPerform(iterations: 20_000) { iteration in
        if iteration.isMultiple(of: 4) {
            store.replace(with: iteration.isMultiple(of: 8) ? first : second)
        } else {
            let snapshot = store.snapshot()
            precondition(
                snapshot == first || snapshot == second,
                "a reader observed a partially replaced discovery-host snapshot"
            )
        }
    }
}

func testPreferredHostProbePowerPolicy() throws {
    try expect(PreferredHostProbePolicy.shouldProbe(for: .startup), "startup should recover remembered peers")
    try expect(PreferredHostProbePolicy.shouldProbe(for: .wake), "wake should recover remembered peers")
    try expect(PreferredHostProbePolicy.shouldProbe(for: .networkPathChange), "network changes should recover remembered peers")
    try expect(PreferredHostProbePolicy.shouldProbe(for: .manualRefresh), "manual refresh should probe remembered peers")
    try expect(PreferredHostProbePolicy.shouldProbe(for: .offlineRecovery), "an offline selected target should receive bounded recovery probes")
    try expect(!PreferredHostProbePolicy.shouldProbe(for: .menuOpen), "opening the menu must not start active host probes")
    try expect(!PreferredHostProbePolicy.shouldProbe(for: .periodicAnnouncement), "periodic UDP announcements must not start active host probes")
}

let tests: [(String, () throws -> Void)] = [
    ("snapshotNormalizationAndReplacement", testSnapshotNormalizationAndReplacement),
    ("concurrentReadersNeverObserveATornSnapshot", testConcurrentReadersNeverObserveATornSnapshot),
    ("preferredHostProbePowerPolicy", testPreferredHostProbePowerPolicy),
]

do {
    for (name, test) in tests {
        do {
            try test()
        } catch {
            throw TestFailure(description: "\(name): \(error)")
        }
    }
    print("AirSendDiscoverySupportSelfTests passed")
} catch {
    fputs("AirSendDiscoverySupportSelfTests failed: \(error)\n", stderr)
    exit(1)
}
