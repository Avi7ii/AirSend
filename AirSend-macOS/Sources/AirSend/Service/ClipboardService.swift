import Cocoa

@MainActor
class ClipboardService {
    private var timer: Timer?
    private var lastChangeCount: Int
    private let pasteboard = NSPasteboard.general
    var onNewContent: ((String) -> Void)?
    var onNewImage: ((Data) -> Void)? // 🚀 新增图片回调
    
    init() {
        self.lastChangeCount = pasteboard.changeCount
    }
    
    func start() {
        // 🔋 3.0s 轮询（changeCount 单调递增，延长间隔只影响延迟不影响完整性）
        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        t.tolerance = 1.5 // 🔋 允许 macOS 合并唤醒
        timer = t
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    private func checkPasteboard() {
        if pasteboard.changeCount != lastChangeCount {
            lastChangeCount = pasteboard.changeCount
            
            // 1. 优先检测是否是图片（截图通常以 TIFF 格式存在于剪贴板）
            if let tiffData = pasteboard.data(forType: .tiff),
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                onNewImage?(pngData)
                return // 如果是图片，就拦截掉，不当作纯文本处理
            }
            
            // 2. 退避检测纯文本
            if let str = pasteboard.string(forType: .string) {
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
