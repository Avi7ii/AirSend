import Cocoa

@MainActor
protocol DropTargetViewDelegate: AnyObject {
    func didEnterDrag(urls: [URL])
    func didExitDrag()
    func didPerformDrop(urls: [URL])
}

final class DropTargetView: NSView {
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
            FileLogger.log("⛔️ [Drag] DropTargetView ignored non-local-file drag. \(LocalFileDrag.debugSummary(from: sender.draggingPasteboard))")
            return []
        }

        FileLogger.log("🔘 [Drag] draggingEntered DropTargetView (MenuBar button) with \(urls.count) file(s). \(LocalFileDrag.debugSummary(from: sender.draggingPasteboard))")
        delegate?.didEnterDrag(urls: urls)
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = LocalFileDrag.stagedOrCurrentLocalFileURLs(from: sender.draggingPasteboard)
        FileLogger.log("🔘 [Drag] prepareForDragOperation DropTargetView with \(urls.count) file(s)")
        return !urls.isEmpty
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = LocalFileDrag.stagedOrCurrentLocalFileURLs(from: sender.draggingPasteboard)
        return urls.isEmpty ? [] : .copy
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

        FileLogger.log("✅ [Drag] DropTargetView: \(urls.count) local file(s) accepted")
        delegate?.didPerformDrop(urls: urls)
        return true
    }
}
