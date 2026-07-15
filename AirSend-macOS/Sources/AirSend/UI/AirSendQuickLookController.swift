import AppKit
import QuickLookUI

struct AirSendQuickLookGroup {
    let id: String
    let urls: [URL]
    let fallbackText: String?
    let fallbackFileName: String
}

@MainActor
final class AirSendQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private struct PreparedGroup {
        let id: String
        let urls: [URL]
    }

    private var groups: [PreparedGroup] = []
    private var activeGroupIndex = 0
    private var previewURLs: [URL] = []
    private var temporaryPreviewDirectory: URL?
    private var eventMonitor: Any?
    private var selectionChanged: ((String) -> Void)?

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

        guard let selectedIndex = groups.firstIndex(where: { $0.id == selectedID }),
              let panel = QLPreviewPanel.shared() else {
            clearSession()
            NSSound.beep()
            return
        }

        activeGroupIndex = selectedIndex
        selectionChanged = onSelectionChanged
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

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        clearSession()
    }

    private func prepare(_ sourceGroups: [AirSendQuickLookGroup]) throws -> [PreparedGroup] {
        let fileManager = FileManager.default
        var prepared: [PreparedGroup] = []

        for (index, group) in sourceGroups.enumerated() {
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
            }

            if !urls.isEmpty {
                prepared.append(PreparedGroup(id: group.id, urls: urls))
            }
        }

        return prepared
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
