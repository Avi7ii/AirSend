import Cocoa
import AirSendAutomationSupport

@MainActor
class ClipboardService {
    private var timer: Timer?
    private var lastChangeCount: Int
    private let pasteboard = NSPasteboard.general
    private var suppressedChangeCounts: [Int] = []
    private var deliveryGate = RecentDeliveryGate(duplicateWindow: 2, capacity: 32)
    private(set) var listensForText = false
    private(set) var listensForImages = false
    var onNewContent: ((String) -> Void)?
    var onNewImage: ((Data) -> Void)?
    
    init() {
        self.lastChangeCount = pasteboard.changeCount
    }
    
    var isRunning: Bool { timer != nil }

    func start(listenForText: Bool, listenForImages: Bool) {
        stop()
        listensForText = listenForText
        listensForImages = listenForImages
        lastChangeCount = pasteboard.changeCount
        guard listenForText || listenForImages else { return }

        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboard()
            }
        }
        t.tolerance = 1.5
        timer = t
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        listensForText = false
        listensForImages = false
    }
    
    private func checkPasteboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if suppressedChangeCounts.contains(changeCount) {
            suppressedChangeCounts.removeAll { $0 == changeCount }
            return
        }

        if listensForImages,
           let tiffData = pasteboard.data(forType: .tiff),
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                let signature = "image:\(pngData.hashValue):\(pngData.count)"
                guard shouldDeliver(signature) else { return }
                onNewImage?(pngData)
                return
        }

        if listensForText,
           let str = pasteboard.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let signature = "text:\(str.hashValue):\(str.utf8.count)"
            guard shouldDeliver(signature) else { return }
            onNewContent?(str)
        }
    }
    
    // Helper to set clipboard content (when receiving)
    func setContent(_ content: String) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        let changeCount = pasteboard.changeCount
        suppressedChangeCounts.append(changeCount)
        if suppressedChangeCounts.count > 8 {
            suppressedChangeCounts.removeFirst(suppressedChangeCounts.count - 8)
        }
        lastChangeCount = changeCount
    }

    private func shouldDeliver(_ signature: String) -> Bool {
        deliveryGate.shouldDeliver(signature)
    }
}
