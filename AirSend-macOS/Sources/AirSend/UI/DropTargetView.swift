import Cocoa

@MainActor
protocol DropTargetViewDelegate: AnyObject {
    func didEnterDrag()
    func didExitDrag()
    func didPerformDrop(urls: [URL])
}

class DropTargetView: NSView {
    weak var delegate: DropTargetViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(LocalFileDrag.acceptedTypes)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(LocalFileDrag.acceptedTypes)
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = LocalFileDrag.stageValidLocalFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            FileLogger.log("⛔️ [Drag] DropTargetView ignored non-local-file drag.")
            return []
        }
        FileLogger.log("🔘 [Drag] draggingEntered DropTargetView (MenuBar button)")
        delegate?.didEnterDrag()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        LocalFileDrag.stageValidLocalFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        FileLogger.log("🔘 [Drag] draggingExited DropTargetView (MenuBar button)")
        delegate?.didExitDrag()
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        FileLogger.log("🔘 [Drag] performDragOperation DropTargetView (MenuBar button) called")

        let urls = LocalFileDrag.stagedOrCurrentLocalFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            FileLogger.log("❌ [Drag] DropTargetView: performDragOperation failed - no local files found")
            return false
        }

        FileLogger.log("✅ [Drag] DropTargetView: \\(urls.count) local file(s) accepted")
        delegate?.didPerformDrop(urls: urls)
        return true
    }
}
