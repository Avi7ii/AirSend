import AirSendAutomationSupport
import Foundation

enum AutomationTestFailure: Error {
    case assertion(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw AutomationTestFailure.assertion(message) }
}

@main
struct AirSendAutomationSupportSelfTests {
    static func main() throws {
        try expect(ScreenshotNameClassifier.isLikelyScreenshotFilename("Screenshot 2026-07-15.png"), "English screenshot names should match")
        try expect(ScreenshotNameClassifier.isLikelyScreenshotFilename("屏幕快照 2026-07-15.png"), "Chinese screenshot names should match")
        try expect(ScreenshotNameClassifier.isLikelyScreenshotFilename("CleanShot 2026-07-15.png"), "CleanShot names should match")
        try expect(!ScreenshotNameClassifier.isLikelyScreenshotFilename("holiday-photo.png"), "Ordinary images must not match")

        let start = Date(timeIntervalSince1970: 100)
        var gate = RecentDeliveryGate(duplicateWindow: 2, capacity: 3)
        try expect(gate.shouldDeliver("text:a", now: start), "First delivery should pass")
        try expect(!gate.shouldDeliver("text:a", now: start.addingTimeInterval(1)), "Duplicate delivery should be suppressed")
        try expect(gate.shouldDeliver("text:a", now: start.addingTimeInterval(3)), "Expired duplicate should pass")
        _ = gate.shouldDeliver("text:b", now: start.addingTimeInterval(3))
        _ = gate.shouldDeliver("text:c", now: start.addingTimeInterval(3))
        _ = gate.shouldDeliver("text:d", now: start.addingTimeInterval(3))
        try expect(gate.entryCount == 3, "Delivery deduplication cache should remain bounded")
        print("AirSendAutomationSupportSelfTests passed")
    }
}
