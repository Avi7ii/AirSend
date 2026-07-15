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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if let control = superview as? NSControl {
            control.mouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let metadata = LocalFileDrag.metadataEvidence(from: sender.draggingPasteboard)
        guard metadata.canBeLocalFileDrag else {
            FileLogger.log("⛔️ [Drag] DropTargetView ignored non-file drag metadata. \(LocalFileDrag.debugSummary(from: sender.draggingPasteboard))")
            return []
        }

        let urls = LocalFileDrag.stageValidLocalFileURLs(from: sender.draggingPasteboard)
        let payloadState = urls.isEmpty ? "candidate with delayed URLs" : "\(urls.count) resolved file(s)"
        FileLogger.log("🔘 [Drag] draggingEntered DropTargetView (MenuBar button), \(payloadState). \(LocalFileDrag.debugSummary(from: sender.draggingPasteboard))")
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
        if !urls.isEmpty {
            return .copy
        }
        return LocalFileDrag.metadataEvidence(from: sender.draggingPasteboard).canBeLocalFileDrag ? .copy : []
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
