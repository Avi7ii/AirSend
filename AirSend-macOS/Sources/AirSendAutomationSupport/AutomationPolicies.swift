import Foundation

public enum ScreenshotNameClassifier {
    private static let prefixes = [
        "screenshot",
        "screen shot",
        "screen capture",
        "截屏",
        "屏幕快照",
        "cleanshot",
    ]

    public static func isLikelyScreenshotFilename(_ filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        return prefixes.contains { stem.hasPrefix($0) }
    }
}

public struct RecentDeliveryGate: Sendable {
    private var deliveredAt: [String: Date] = [:]
    private let duplicateWindow: TimeInterval
    private let capacity: Int

    public init(duplicateWindow: TimeInterval = 2, capacity: Int = 32) {
        self.duplicateWindow = max(0, duplicateWindow)
        self.capacity = max(1, capacity)
    }

    public var entryCount: Int { deliveredAt.count }

    public mutating func shouldDeliver(_ signature: String, now: Date = Date()) -> Bool {
        prune(now: now)
        if let previous = deliveredAt[signature], now.timeIntervalSince(previous) < duplicateWindow {
            return false
        }
        deliveredAt[signature] = now
        if deliveredAt.count > capacity {
            let newest = deliveredAt.sorted { $0.value > $1.value }.prefix(capacity)
            deliveredAt = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        return true
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-duplicateWindow)
        deliveredAt = deliveredAt.filter { $0.value >= cutoff }
    }
}
