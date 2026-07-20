import AppKit
import QuickLookUI

@MainActor
final class AirSendQuickLookAnchor {
    private weak var view: NSView?

    func attach(to view: NSView) {
        self.view = view
    }

    func detach(from view: NSView) {
        guard self.view === view else { return }
        self.view = nil
    }

    var sourceFrameOnScreen: NSRect {
        guard let source = popoverSource else { return .zero }
        return source.view.window?.convertToScreen(
            source.view.convert(source.rect, to: nil)
        ) ?? .zero
    }

    var popoverSource: (view: NSView, rect: NSRect)? {
        guard let view,
              let window = view.window,
              window.isVisible,
              !window.isMiniaturized,
              !view.isHidden else {
            return nil
        }

        let visibleRect = view.visibleRect.intersection(view.bounds)
        guard !visibleRect.isEmpty else { return nil }
        return (view, visibleRect)
    }
}

@MainActor
final class AirSendQuickLookAnchorRegistry {
    private var anchorsByID: [String: AirSendQuickLookAnchor] = [:]

    func anchor(for id: String) -> AirSendQuickLookAnchor {
        if let anchor = anchorsByID[id] { return anchor }
        let anchor = AirSendQuickLookAnchor()
        anchorsByID[id] = anchor
        return anchor
    }

    func anchors(for ids: [String]) -> [String: AirSendQuickLookAnchor] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, anchor(for: $0)) })
    }
}

struct AirSendQuickLookGroup {
    let id: String
    let urls: [URL]
    let fallbackText: String?
    let fallbackFileName: String
    let sourceAnchor: AirSendQuickLookAnchor?
}

@MainActor
final class AirSendQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate, NSPopoverDelegate {
    private struct PreparedGroup {
        let id: String
        let urls: [URL]
        let sourceAnchor: AirSendQuickLookAnchor?
        let compactText: String?
    }

    private var groups: [PreparedGroup] = []
    private var activeGroupIndex = 0
    private var previewURLs: [URL] = []
    private var temporaryPreviewDirectory: URL?
    private var eventMonitor: Any?
    private var selectionChanged: ((String) -> Void)?
    private var compactPopover: NSPopover?
    private var compactPreviewView: QLPreviewView?

    func show(
        groups sourceGroups: [AirSendQuickLookGroup],
        selectedID: String,
        onSelectionChanged: @escaping (String) -> Void
    ) {
        clearSession()

        do {
            groups = try prepare(sourceGroups)
        } catch {
            clearSession()
            NSSound.beep()
            return
        }

        guard let selectedIndex = groups.firstIndex(where: { $0.id == selectedID }) else {
            clearSession()
            NSSound.beep()
            return
        }

        activeGroupIndex = selectedIndex
        selectionChanged = onSelectionChanged
        if presentCompactActiveGroup() {
            return
        }

        guard let panel = QLPreviewPanel.shared() else {
            clearSession()
            NSSound.beep()
            return
        }
        panel.dataSource = self
        panel.delegate = self
        installEventMonitor(for: panel)
        presentActiveGroup(in: panel, notifySelection: false)
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        previewURLs[index] as NSURL
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        sourceFrameOnScreenFor item: (any QLPreviewItem)!
    ) -> NSRect {
        guard groups.indices.contains(activeGroupIndex) else { return .zero }
        return groups[activeGroupIndex].sourceAnchor?.sourceFrameOnScreen ?? .zero
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        transitionImageFor item: (any QLPreviewItem)!,
        contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        guard let url = item.previewItemURL else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        contentRect?.pointee = NSRect(origin: .zero, size: image.size)
        return image
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        clearSession()
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === compactPopover else { return }
        compactPreviewView?.close()
        compactPreviewView = nil
        compactPopover = nil
        clearPreparedSessionData()
    }

    private func prepare(_ sourceGroups: [AirSendQuickLookGroup]) throws -> [PreparedGroup] {
        let fileManager = FileManager.default
        var prepared: [PreparedGroup] = []

        for (index, group) in sourceGroups.enumerated() {
            var compactText = group.fallbackText.flatMap { $0.isEmpty ? nil : $0 }
            var urls = group.urls.reduce(into: [URL]()) { result, url in
                let standardizedURL = url.standardizedFileURL
                guard fileManager.fileExists(atPath: standardizedURL.path),
                      !result.contains(standardizedURL) else { return }
                result.append(standardizedURL)
            }

            if urls.isEmpty,
               let text = group.fallbackText,
               !text.isEmpty {
                let root = try temporaryRoot(fileManager: fileManager)
                let itemDirectory = root.appendingPathComponent(String(index), isDirectory: true)
                try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
                let leafName = safeLeafName(group.fallbackFileName)
                let destination = itemDirectory.appendingPathComponent(leafName, isDirectory: false)
                try text.write(to: destination, atomically: true, encoding: .utf8)
                urls = [destination]
                compactText = text
            }

            if !urls.isEmpty {
                prepared.append(
                    PreparedGroup(
                        id: group.id,
                        urls: urls,
                        sourceAnchor: group.sourceAnchor,
                        compactText: compactText
                    )
                )
            }
        }

        return prepared
    }

    private func presentCompactActiveGroup() -> Bool {
        guard groups.indices.contains(activeGroupIndex) else { return false }
        let group = groups[activeGroupIndex]
        guard let text = group.compactText,
              let url = group.urls.first,
              let source = group.sourceAnchor?.popoverSource,
              let previewView = QLPreviewView(frame: .zero, style: .compact) else {
            return false
        }

        let contentSize = compactContentSize(for: text)
        previewView.frame = NSRect(origin: .zero, size: contentSize)
        previewView.autostarts = true
        previewView.shouldCloseWithWindow = true
        previewView.previewItem = url as NSURL

        let viewController = NSViewController()
        viewController.view = previewView

        let popover = NSPopover()
        popover.animates = true
        popover.behavior = .transient
        popover.contentSize = contentSize
        popover.contentViewController = viewController
        popover.delegate = self

        compactPreviewView = previewView
        compactPopover = popover
        installCompactEventMonitor()
        popover.show(
            relativeTo: source.rect,
            of: source.view,
            preferredEdge: .maxX
        )
        return popover.isShown
    }

    private func compactContentSize(for text: String) -> NSSize {
        let font = NSFont.systemFont(ofSize: 13)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let longestLineWidth = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { NSAttributedString(string: String($0), attributes: attributes).size().width }
            .max() ?? 0
        let width = min(max(300, ceil(longestLineWidth) + 52), 560)
        let measuredText = NSAttributedString(string: text, attributes: attributes)
        let measuredBounds = measuredText.boundingRect(
            with: NSSize(width: width - 36, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = min(max(120, ceil(measuredBounds.height) + 48), 400)
        return NSSize(width: width, height: height)
    }

    private func presentActiveGroup(in panel: QLPreviewPanel, notifySelection: Bool) {
        guard groups.indices.contains(activeGroupIndex) else { return }
        let group = groups[activeGroupIndex]
        previewURLs = group.urls
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        if notifySelection {
            selectionChanged?(group.id)
        }
    }

    private func installEventMonitor(for panel: QLPreviewPanel) {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, panel.isKeyWindow else { return event }
            return self.handleNavigationEvent(event, panel: panel) ? nil : event
        }
    }

    private func installCompactEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.compactPopover?.isShown == true else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            guard modifiers.isEmpty else { return event }

            switch event.keyCode {
            case 49, 53:
                guard !event.isARepeat else { return nil }
                self.clearSession()
                return nil
            default:
                return event
            }
        }
    }

    private func handleNavigationEvent(_ event: NSEvent, panel: QLPreviewPanel) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case 126:
            guard !event.isARepeat else { return true }
            moveGroup(by: -1, panel: panel)
            return true
        case 125:
            guard !event.isARepeat else { return true }
            moveGroup(by: 1, panel: panel)
            return true
        default:
            return false
        }
    }

    private func moveGroup(by offset: Int, panel: QLPreviewPanel) {
        let nextIndex = min(max(activeGroupIndex + offset, 0), groups.count - 1)
        guard nextIndex != activeGroupIndex else { return }
        activeGroupIndex = nextIndex
        presentActiveGroup(in: panel, notifySelection: true)
    }

    private func temporaryRoot(fileManager: FileManager) throws -> URL {
        if let temporaryPreviewDirectory { return temporaryPreviewDirectory }
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AirSend-QuickLook-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryPreviewDirectory = directory
        return directory
    }

    private func safeLeafName(_ value: String) -> String {
        let leaf = (value as NSString).lastPathComponent
        return leaf.isEmpty || leaf == "." || leaf == ".." ? "clipboard.txt" : leaf
    }

    private func clearSession() {
        if let compactPopover {
            compactPopover.delegate = nil
            compactPopover.close()
            self.compactPopover = nil
        }
        compactPreviewView?.close()
        compactPreviewView = nil
        clearPreparedSessionData()
    }

    private func clearPreparedSessionData() {
        removeEventMonitor()
        groups = []
        activeGroupIndex = 0
        previewURLs = []
        selectionChanged = nil
        if let temporaryPreviewDirectory {
            try? FileManager.default.removeItem(at: temporaryPreviewDirectory)
            self.temporaryPreviewDirectory = nil
        }
    }

    private func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }
}
