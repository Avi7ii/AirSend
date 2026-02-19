import Cocoa

@MainActor
class ClipboardService {
    private var timer: Timer?
    private var lastChangeCount: Int
    private let pasteboard = NSPasteboard.general
    var onNewContent: ((String) -> Void)?
    
    init() {
        self.lastChangeCount = pasteboard.changeCount
    }
    
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    private func checkPasteboard() {
        if pasteboard.changeCount != lastChangeCount {
            lastChangeCount = pasteboard.changeCount
            
            if let str = pasteboard.string(forType: .string) {
                // Determine if this change was caused by us (avoid loops)?
                // For now, just pass it up.
                onNewContent?(str)
            }
        }
    }
    
    // Helper to set clipboard content (when receiving)
    func setContent(_ content: String) {
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        lastChangeCount = pasteboard.changeCount // Update count to ignore this change
    }
}
