import Cocoa

@MainActor
protocol DropTargetViewDelegate: AnyObject {
    func didEnterDrag()
    func didExitDrag()
    func didPerformDrop(urls: [URL])
}

class DropTargetView: NSView {
    weak var delegate: DropTargetViewDelegate?

    // 注册所有可能的文件类型：现代 fileURL、旧版 NSFilenamesPboardType、通用 URL
    private static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        NSPasteboard.PasteboardType("NSFilenamesPboardType")
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedTypes)
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileLogger.log("🔘 [Drag] draggingEntered DropTargetView (MenuBar button)")
        delegate?.didEnterDrag()
        return .copy
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        FileLogger.log("🔘 [Drag] draggingExited DropTargetView (MenuBar button)")
        delegate?.didExitDrag()
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        FileLogger.log("🔘 [Drag] performDragOperation DropTargetView (MenuBar button) called")
        
        // 优先使用现代 API 读取文件 URL
        if let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            FileLogger.log("✅ [Drag] DropTargetView: \\(urls.count) file(s) via new API")
            delegate?.didPerformDrop(urls: urls)
            return true
        }
        
        // 兜底：旧版 NSFilenamesPboardType
        if let paths = sender.draggingPasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], !paths.isEmpty {
            FileLogger.log("✅ [Drag] DropTargetView: \\(paths.count) file(s) via NSFilenamesPboardType fallback")
            let urls = paths.map { URL(fileURLWithPath: $0) }
            delegate?.didPerformDrop(urls: urls)
            return true
        }
        
        FileLogger.log("❌ [Drag] DropTargetView: performDragOperation failed - no URLs found")
        return false
    }
}
