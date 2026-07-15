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
        "events under one minute old should read just now"
    )
    try expect(
        AirSendRelativeTimeFormatter.label(since: now.addingTimeInterval(-42), now: now) == "just now",
        "recent events should not force per-second UI refreshes"
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
            == now.addingTimeInterval(56),
        "just now should refresh at the one-minute boundary"
    )
    try expect(
        AirSendRelativeTimeFormatter.nextLabelChangeDate(since: now.addingTimeInterval(-42), now: now)
            == now.addingTimeInterval(18),
        "recent labels should not refresh every second"
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

func testTransferFileClassificationMatchesAndroidTaxonomy() throws {
    let cases: [(name: String, mimeType: String, fileCount: Int, expected: AirSendTransferFileKind)] = [
        ("files", "", 2, .multiple),
        ("release.APK", "application/octet-stream", 1, .androidPackage),
        ("photo", " public.heic ", 1, .image),
        ("movie.MKV", "", 1, .video),
        ("song", "audio/flac", 1, .audio),
        ("report.pdf", "", 1, .pdf),
        ("source.tar", "application/octet-stream", 1, .archive),
        ("deck.key", "", 1, .presentation),
        ("table.csv", "text/plain", 1, .spreadsheet),
        ("letter.pages", "", 1, .wordProcessing),
        ("index.xhtml", "", 1, .html),
        ("README.md", "text/plain", 1, .markdown),
        ("payload.bin", "application/problem+json", 1, .structuredData),
        ("main.swift", "text/plain", 1, .code),
        ("notes.log", "application/octet-stream", 1, .text),
        ("book.epub", "application/octet-stream", 1, .document),
        ("payload.bin", "application/octet-stream", 1, .generic),
    ]

    for item in cases {
        let actual = AirSendTransferFileClassifier.classify(
            name: item.name,
            mimeType: item.mimeType,
            fileCount: item.fileCount
        )
        try expect(actual == item.expected, "\(item.name) should classify as \(item.expected), got \(actual)")
    }
}

let tests: [(String, () throws -> Void)] = [
    ("relativeActivityTimeLabels", testRelativeActivityTimeLabels),
    ("nextRelativeActivityRefreshDate", testNextRelativeActivityRefreshDate),
    ("connectionHealthUsesOnlyLiveState", testConnectionHealthUsesOnlyLiveState),
    ("transferFileClassificationMatchesAndroidTaxonomy", testTransferFileClassificationMatchesAndroidTaxonomy),
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
