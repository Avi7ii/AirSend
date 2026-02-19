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
        registerForDraggedTypes([.fileURL])
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        delegate?.didEnterDrag()
        return .copy
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        // Do not hide immediately. The window handles its own exit if mouse leaves it.
        // Actually, we need to coordinate. If mouse leaves button but enters window, keep open.
        // Simplified: The delegate (AppDelegate) should decide when to hide based on where the mouse is.
        // For now, let's keep the delegate call, but AppDelegate will need to be smarter.
        // OR: We just don't call exit here if we are moving to the window?
        // AppKit doesn't easily tell us "exited to window".
        
        // Strategy: Delegate will hide with a delay, cancellable if entered window.
        delegate?.didExitDrag()
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let pboard = sender.draggingPasteboard.propertyList(forType: NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")) as? [String] else {
            return false
        }
        
        let urls = pboard.map { URL(fileURLWithPath: $0) }
        delegate?.didPerformDrop(urls: urls)
        return true
    }
}
