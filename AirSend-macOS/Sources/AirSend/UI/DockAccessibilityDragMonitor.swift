import AppKit
import ApplicationServices
import Foundation

final class DockAccessibilityDragMonitor: @unchecked Sendable {
    private static let dragBeganNotification = "AXDraggingSourceDragBegan"
    private static let dragEndedNotification = "AXDraggingSourceDragEnded"

    enum Event: Sendable {
        case began([URL])
        case ended
    }

    typealias Handler = @MainActor (Event) -> Void

    private let candidateMaxAge: TimeInterval = 5
    private var observer: AXObserver?
    private var dockApplicationElement: AXUIElement?
    private var handler: Handler?
    private var currentFolderURL: URL?
    private var candidateURLs: [URL] = []
    private var candidateDate: Date?

    @MainActor
    func start(handler: @escaping Handler) -> Bool {
        guard observer == nil else { return true }
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.dock"
              ).first else {
            return false
        }

        var observer: AXObserver?
        guard AXObserverCreate(
            dock.processIdentifier,
            dockAccessibilityObserverCallback,
            &observer
        ) == .success,
        let observer else {
            return false
        }

        let applicationElement = AXUIElementCreateApplication(dock.processIdentifier)
        let notifications = [
            kAXSelectedChildrenChangedNotification,
            Self.dragBeganNotification,
            Self.dragEndedNotification,
        ]
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        for notification in notifications {
            guard AXObserverAddNotification(
                observer,
                applicationElement,
                notification as CFString,
                userInfo
            ) == .success else {
                return false
            }
        }

        self.handler = handler
        self.observer = observer
        dockApplicationElement = applicationElement
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        return true
    }

    @MainActor
    func stop() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        dockApplicationElement = nil
        handler = nil
        clearSelection()
    }

    fileprivate nonisolated func receive(element: AXUIElement, notification: String) {
        if notification == kAXSelectedChildrenChangedNotification {
            captureSelectedDockItem(from: element)
            return
        }

        if notification == Self.dragBeganNotification {
            let urls = freshCandidateURLs()
            Task { @MainActor [weak self] in
                self?.handler?(.began(urls))
            }
            return
        }

        if notification == Self.dragEndedNotification {
            Task { @MainActor [weak self] in
                self?.handler?(.ended)
            }
            clearCandidate(preserveFolder: true)
        }
    }

    private func captureSelectedDockItem(from element: AXUIElement) {
        guard let selectedElements = elementsAttribute(kAXSelectedChildrenAttribute, from: element),
              !selectedElements.isEmpty else {
            return
        }

        for selectedElement in selectedElements {
            let role = stringAttribute(kAXRoleAttribute, from: selectedElement)
            let subrole = stringAttribute(kAXSubroleAttribute, from: selectedElement)

            if role == kAXDockItemRole,
               subrole == kAXFolderDockItemSubrole,
               let folderURL = urlAttribute(kAXURLAttribute, from: selectedElement),
               folderURL.isFileURL,
               FileManager.default.fileExists(atPath: folderURL.path) {
                let standardized = folderURL.standardizedFileURL
                currentFolderURL = standardized
                candidateURLs = [standardized]
                candidateDate = Date()
                continue
            }

            if role == kAXImageRole,
               let fileName = stringAttribute(kAXTitleAttribute, from: selectedElement)
                   ?? stringAttribute(kAXDescriptionAttribute, from: selectedElement),
               let folderURL = containingFolderURL(of: selectedElement) ?? currentFolderURL,
               let fileURL = validatedChild(named: fileName, in: folderURL) {
                currentFolderURL = folderURL
                candidateURLs = [fileURL]
                candidateDate = Date()
                continue
            }

            if role == kAXDockItemRole {
                clearSelection()
            }
        }
    }

    private func validatedChild(named fileName: String, in folderURL: URL) -> URL? {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/") else {
            return nil
        }

        let childURL = folderURL.appendingPathComponent(fileName).standardizedFileURL
        let folderPath = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        guard childURL.path.hasPrefix(folderPath),
              FileManager.default.fileExists(atPath: childURL.path) else {
            return nil
        }
        return childURL
    }

    private func containingFolderURL(of element: AXUIElement) -> URL? {
        var currentElement: AXUIElement? = element
        for _ in 0..<6 {
            guard let node = currentElement else { break }
            if stringAttribute(kAXRoleAttribute, from: node) == kAXDockItemRole,
               stringAttribute(kAXSubroleAttribute, from: node) == kAXFolderDockItemSubrole,
               let folderURL = urlAttribute(kAXURLAttribute, from: node),
               folderURL.isFileURL,
               FileManager.default.fileExists(atPath: folderURL.path) {
                return folderURL.standardizedFileURL
            }
            currentElement = elementAttribute(kAXParentAttribute, from: node)
        }
        return nil
    }

    private func freshCandidateURLs() -> [URL] {
        guard let candidateDate,
              Date().timeIntervalSince(candidateDate) <= candidateMaxAge else {
            clearCandidate(preserveFolder: true)
            return []
        }
        let existing = candidateURLs.filter {
            $0.isFileURL && FileManager.default.fileExists(atPath: $0.path)
        }
        if existing.isEmpty {
            clearCandidate(preserveFolder: true)
        }
        return existing
    }

    private func clearSelection() {
        clearCandidate(preserveFolder: false)
    }

    private func clearCandidate(preserveFolder: Bool) {
        if !preserveFolder {
            currentFolderURL = nil
        }
        candidateURLs = []
        candidateDate = nil
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private func urlAttribute(_ attribute: String, from element: AXUIElement) -> URL? {
        if let url = copyAttribute(attribute, from: element) as? URL {
            return url
        }
        if let rawValue = copyAttribute(attribute, from: element) as? String {
            return URL(string: rawValue)
        }
        return nil
    }

    private func elementsAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement]? {
        copyAttribute(attribute, from: element) as? [AXUIElement]
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }
}

private func dockAccessibilityObserverCallback(
    observer _: AXObserver,
    element: AXUIElement,
    notification: CFString,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let monitor = Unmanaged<DockAccessibilityDragMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    monitor.receive(element: element, notification: notification as String)
}
