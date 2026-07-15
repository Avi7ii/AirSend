import AirSendConsoleSupport
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(description: message)
    }
}

func testRelativeActivityTimeLabels() throws {
    let now = Date(timeIntervalSince1970: 1_000)

    try expect(
        AirSendRelativeTimeFormatter.label(since: now.addingTimeInterval(-4), now: now) == "just now",
        "events under six seconds old should read just now"
    )
    try expect(
        AirSendRelativeTimeFormatter.label(since: now.addingTimeInterval(-42), now: now) == "42s ago",
        "events under one minute should show seconds"
    )
    try expect(
        AirSendRelativeTimeFormatter.label(since: now.addingTimeInterval(-125), now: now) == "2m ago",
        "events under one hour should show minutes"
    )
    try expect(
        AirSendRelativeTimeFormatter.label(since: now.addingTimeInterval(-7_200), now: now) == "2h ago",
        "events under one day should show hours"
    )
}

func testNextRelativeActivityRefreshDate() throws {
    let now = Date(timeIntervalSince1970: 1_000)

    try expect(
        AirSendRelativeTimeFormatter.nextLabelChangeDate(since: now.addingTimeInterval(-4), now: now)
            == now.addingTimeInterval(2),
        "just now should refresh when it leaves the just-now range"
    )
    try expect(
        AirSendRelativeTimeFormatter.nextLabelChangeDate(since: now.addingTimeInterval(-42), now: now)
            == now.addingTimeInterval(1),
        "second labels should refresh at the next second boundary"
    )
    try expect(
        AirSendRelativeTimeFormatter.nextLabelChangeDate(since: now.addingTimeInterval(-125), now: now)
            == now.addingTimeInterval(55),
        "minute labels should refresh at the next minute boundary"
    )
    try expect(
        AirSendRelativeTimeFormatter.nextLabelChangeDate(
            for: [
                now.addingTimeInterval(-125),
                now.addingTimeInterval(-7_200),
            ],
            now: now
        ) == now.addingTimeInterval(55),
        "a group of activity timestamps should refresh at the earliest label change"
    )
}

func testConnectionHealthUsesOnlyLiveState() throws {
    try expect(
        AirSendLiveConnectionHealthPolicy.evaluate(
            networkAvailable: false,
            receiverReady: true,
            activeTransferCount: 0,
            visibleDeviceCount: 1
        ) == .networkUnavailable,
        "an unavailable network should be the current health state"
    )
    try expect(
        AirSendLiveConnectionHealthPolicy.evaluate(
            networkAvailable: true,
            receiverReady: false,
            activeTransferCount: 0,
            visibleDeviceCount: 1
        ) == .receiverStopped,
        "a stopped receiver should be the current health state"
    )
    try expect(
        AirSendLiveConnectionHealthPolicy.evaluate(
            networkAvailable: true,
            receiverReady: true,
            activeTransferCount: 2,
            visibleDeviceCount: 0
        ) == .transferring(activeCount: 2),
        "active transfers should be reflected immediately"
    )
    try expect(
        AirSendLiveConnectionHealthPolicy.evaluate(
            networkAvailable: true,
            receiverReady: true,
            activeTransferCount: 0,
            visibleDeviceCount: 0
        ) == .ready(visibleDeviceCount: 0),
        "past failures must not keep a healthy idle runtime in warning state"
    )
}

let tests: [(String, () throws -> Void)] = [
    ("relativeActivityTimeLabels", testRelativeActivityTimeLabels),
    ("nextRelativeActivityRefreshDate", testNextRelativeActivityRefreshDate),
    ("connectionHealthUsesOnlyLiveState", testConnectionHealthUsesOnlyLiveState),
]

do {
    for (name, test) in tests {
        do {
            try test()
        } catch {
            throw TestFailure(description: "\(name): \(error)")
        }
    }
    print("AirSendConsoleSupportSelfTests passed")
} catch {
    fputs("AirSendConsoleSupportSelfTests failed: \(error)\n", stderr)
    exit(1)
}
