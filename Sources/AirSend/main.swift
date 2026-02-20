// The Swift Programming Language
// https://docs.swift.org/swift-book

import Cocoa
import ServiceManagement
import IOKit.pwr_mgt

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, DropTargetViewDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    
    // Persistent Fingerprint
    // Persistent Fingerprint (Will be overwritten by real cert fingerprint)
    var fingerprint: String = UUID().uuidString
    
    lazy var discoveryService = UDPDiscoveryService(fingerprint: fingerprint, protocolType: .https)
    lazy var transferServer = HTTPTransferServer(fingerprint: fingerprint)
    lazy var clipboardSender = ClipboardSender(fingerprint: fingerprint)
    lazy var fileSender = FileSender(fingerprint: fingerprint)
    let clipboardService = ClipboardService()
    
    // UI Components
    var dropZoneWindow: DropZoneWindow!
    private var hasStartedTransfer = false
    private var isMinimizedToMenu = false
    private var currentTransferProgress: Double = 0
    private var currentTransferTarget: String = ""
    private var transferProgressMenuItem: NSMenuItem?
    private var menuScanTimer: Timer?
    
    // Wakelock & Launch at Login
    private var wakelockAssertionID: IOPMAssertionID = 0
    private var isLaunchAtLoginEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService().status == SMAppService.Status.enabled
            }
            return false
        }
    }
    
    // Auto Update Preference
    private var isAutoUpdateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "auto_update_enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "auto_update_enabled")
            updateMenu()
        }
    }
    
    var devices: [String: Device] = [:] {
        didSet {
            saveDevices()
        }
    }
    
    // Persistent historical devices
    var historyDeviceIds: Set<String> {
        get {
            let array = UserDefaults.standard.stringArray(forKey: "history_device_ids") ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "history_device_ids")
        }
    }

    // Selection state: "broadcast" or device ID
    var selectedDeviceId: String = {
        UserDefaults.standard.string(forKey: "selected_device_id") ?? "broadcast"
    }() {
        didSet {
            print("🚨 App: selectedDeviceId changed to [\(selectedDeviceId)]")
            UserDefaults.standard.set(selectedDeviceId, forKey: "selected_device_id")
            if selectedDeviceId != "broadcast" {
                var current = historyDeviceIds
                current.insert(selectedDeviceId)
                historyDeviceIds = current
            }
            updateMenu()
            updateWindowStatus()
        }
    }
    
    // Track connection state
    var connectingDeviceId: String? = nil {
        didSet {
            let idString = connectingDeviceId ?? "nil"
            print("🚨 App: connectingDeviceId changed to [\(idString)]")
            updateMenu()
        }
    }

    func updateWindowStatus() {
        // PROTECTION: Don't overwrite during active transfer, success, or error states
        if dropZoneWindow.isShowingSuccess || dropZoneWindow.isShowingError || dropZoneWindow.isPerformingDrop {
            return
        }
        
        if selectedDeviceId == "broadcast" {
            dropZoneWindow.setStatusText("Broadcast to All")
        } else if let device = devices[selectedDeviceId] {
            dropZoneWindow.setStatusText("Send to \(device.alias)")
        } else {
            // Selected device is offline/missing
            dropZoneWindow.setStatusText("Target Offline (Select another)")
        }
    }


    private func updateStatusItemIcon(showDot: Bool) {
        guard let button = statusItem.button else { return }
        let baseImage = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "LocalSend")
        
        if !showDot {
            button.image = baseImage
            return
        }
        
        // Create an image with a dot
        let dotSize: CGFloat = 8
        let imageSize: CGFloat = 18
        let newImage = NSImage(size: NSSize(width: imageSize, height: imageSize), flipped: false) { rect in
            baseImage?.draw(in: rect)
            
            // Draw a white dot in the bottom-right corner (standard indicator location)
            let dotRect = NSRect(x: rect.width - dotSize - 1, y: 1, width: dotSize, height: dotSize)
            NSColor.white.setFill()
            let path = NSBezierPath(ovalIn: dotRect)
            path.fill()
            
            return true
        }
        newImage.isTemplate = true // Allows it to follow system theme
        button.image = newImage
    }

    func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: "saved_devices")
        }
    }
    
    func loadDevices() {
        if let data = UserDefaults.standard.data(forKey: "saved_devices"),
           let saved = try? JSONDecoder().decode([String: Device].self, from: data) {
            
            // Sanitize IPs (remove ::ffff:)
            var cleanedDevices: [String: Device] = [:]
            for (id, device) in saved {
                var ip = device.ip
                if ip.hasPrefix("::ffff:") {
                    ip = String(ip.dropFirst(7))
                }
                
                let cleanedDevice = Device(
                    id: device.id,
                    alias: device.alias,
                    ip: ip,
                    port: device.port,
                    deviceModel: device.deviceModel,
                    deviceType: device.deviceType,
                    version: device.version,
                    https: device.https,
                    download: device.download,
                    lastSeen: device.lastSeen
                )
                cleanedDevices[id] = cleanedDevice
            }
            self.devices = cleanedDevices
        }
    }

    @objc func clearDeviceHistory() {
        print("🚨 App: Clearing device history...")
        self.devices.removeAll()
        self.historyDeviceIds.removeAll()
        self.selectedDeviceId = "broadcast"
        
        UserDefaults.standard.removeObject(forKey: "saved_devices")
        UserDefaults.standard.removeObject(forKey: "history_device_ids")
        UserDefaults.standard.set("broadcast", forKey: "selected_device_id")
        
        updateMenu()
        updateWindowStatus()
    }

    // Drag Detection
    var lastDragCount: Int = 0
    var dragMonitorTimer: Timer?
    var isDragging: Bool = false
    var isDragInsideWindow: Bool = false // State Priority
    private var dropTimeoutWorkItem: DispatchWorkItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // Use a system symbol for the icon
            button.image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "LocalSend")
            
            // Setup Drag & Drop
            let dropView = DropTargetView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.delegate = self
            button.addSubview(dropView)
        }
        
        // Initialize Drop Zone Window
        dropZoneWindow = DropZoneWindow()
        dropZoneWindow.onDrop = { [weak self] urls in
            self?.didPerformDrop(urls: urls)
        }
        dropZoneWindow.onDragEnter = { [weak self] in
            self?.isDragInsideWindow = true // Enter: Lock visibility
            self?.hideWorkItem?.cancel()
            self?.hideWorkItem = nil
        }
        dropZoneWindow.onDragExit = { [weak self] in
            self?.isDragInsideWindow = false // Exit: Unlock visibility
            // Rely on checkDragState to handle hiding based on Safe Zone
        }
        dropZoneWindow.onClickDuringTransfer = { [weak self] in
            guard let self = self else { return }
            logTransfer("📲 Minimizing transfer to menu bar")
            self.isMinimizedToMenu = true
            self.dropZoneWindow.hide()
            self.updateStatusItemIcon(showDot: true) // Show dot indicator
            self.updateMenu() // Refresh menu to include progress row
        }
        
        loadDevices()
        setupMenu()
        updateWindowStatus()
        
        // Initialize Security & Start Services
        Task { @MainActor in
            do {
                // 1. Setup Certificate (Still needed for Fingerprint identity)
                let certManager = CertificateManager.shared
                try await certManager.setup()
                let realFingerprint = try await certManager.getFingerprint()
                
                logTransfer("🔐 Security Initialized. Fingerprint: \(realFingerprint)")
                
                // 2. Re-init all services with real fingerprint
                // Stop old ones if they were lazily initialized
                await self.transferServer.stop()
                self.discoveryService.stop()
                
                // Give OS more time to release ports (especially 53317 and Multicast)
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                
                self.fingerprint = realFingerprint
                
                // 3. Setup Services
                // Preference: HTTPS for official compatibility
                let targetProtocol = ProtocolType.https 
                logTransfer("🌐 Restoring HTTPS Mode for full protocol compatibility.")
                
                self.transferServer = HTTPTransferServer(fingerprint: realFingerprint)
                self.discoveryService = UDPDiscoveryService(fingerprint: realFingerprint, protocolType: targetProtocol)
                self.fileSender = FileSender(fingerprint: realFingerprint, localProtocol: targetProtocol)
                self.clipboardSender = ClipboardSender(fingerprint: realFingerprint, localProtocol: targetProtocol)
                
                // 4. Start Discovery FIRST
                startDiscovery()
                
                // Give UDP a moment to bind before TCP kicks in
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                
                // 5. Start Transfer Server
                await startTransferServer()
                
                startClipboardService()
                startDragMonitoring()
            } catch {
                logTransfer("❌ Initialization Failed: \(error)")
                startDiscovery() 
                await startTransferServer()
                startClipboardService()
                startDragMonitoring()
            }
        }
    }
    
    func startDragMonitoring() {
        lastDragCount = NSPasteboard(name: .drag).changeCount
        
        // Check every 0.1s for drag activity and mouse position
        dragMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDragState()
            }
        }
    }
    
    func checkDragState() {
        let currentCount = NSPasteboard(name: .drag).changeCount
        if currentCount != lastDragCount {
            // Drag started
            lastDragCount = currentCount
            isDragging = true
        }
        
        // If we think we are dragging, check if mouse is up (drag ended)
        if isDragging {
            let pressedButtons = NSEvent.pressedMouseButtons
            if pressedButtons == 0 {
                // Drag ended (mouse released)
                let mouseLoc = NSEvent.mouseLocation
                let windowFrame = dropZoneWindow.frame
                let isMouseInWindow = NSMouseInRect(mouseLoc, windowFrame, false)

                if isMouseInWindow {
                    // Start a short timeout. If system fails to trigger performDragOperation
                    // within 0.5s, we force hide to prevent "stuck" window.
                    dropTimeoutWorkItem?.cancel()
                    let item = DispatchWorkItem { [weak self] in
                        Task { @MainActor in
                            guard let self = self else { return }
                            if !self.dropZoneWindow.isShowingSuccess && !self.dropZoneWindow.isPerformingDrop {
                                print("🚨 App: Drop timeout reached, force hiding.")
                                self.dropZoneWindow.hide()
                            }
                        }
                    }
                    self.dropTimeoutWorkItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
                    
                    isDragging = false
                    return
                }

                isDragging = false
                dropZoneWindow.hide()
                return
            }
            
            // Unified Logic:
            // 1. STATE PRIORITY: If we are INSIDE the window (via DragEnter/Exit events), force SHOW.
            if isDragInsideWindow {
                if dropZoneWindow.alphaValue < 1 {
                    updateWindowStatus()
                    dropZoneWindow.show(under: statusItem)
                }
                // NOTE: We used to 'return' here, which blocked the scaling logic below!
                // We must continue to check mouse location to drive 'isIconExpanded'.
            }

            // 2. Proximity & Safe Zone Logic (Centralized Control)
            if let button = statusItem.button, let window = button.window {
                let mouseLoc = NSEvent.mouseLocation
                let windowFrame = dropZoneWindow.frame
                
                // Condition A: Mathematically INSIDE the window rectangle
                let isMouseInWindow = NSMouseInRect(mouseLoc, windowFrame, false)
                
                // Condition B: Icon Proximity
                let buttonFrame = window.frame
                let buttonCenter = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
                let distance = hypot(mouseLoc.x - buttonCenter.x, mouseLoc.y - buttonCenter.y)
                let isNearIcon = distance < 80
                
                // Condition C: Safe Zone Hysteresis (120px buffer)
                let isInSafeZone: Bool
                if dropZoneWindow.alphaValue > 0 {
                    let safeZone = windowFrame.insetBy(dx: -120, dy: -120)
                    isInSafeZone = safeZone.contains(mouseLoc)
                } else {
                    isInSafeZone = false
                }
                
                // --- EXECUTION OF LOGIC ---
                
                // 1. Icon State: Only expand if INSIDE the literal window
                // If showing success, we don't change expansion state
                if !dropZoneWindow.isShowingSuccess {
                    dropZoneWindow.isIconExpanded = isMouseInWindow
                    dropZoneWindow.isBorderHighlighted = isMouseInWindow // Also highlight border only when inside
                }
                
                // 2. Visibility Policy
                // CRITICAL: Window should stay visible if:
                // - Mouse is inside/near icon
                // - We are currently performing a drop (transferring/requesting)
                // - We are showing success pulse
                // - We are showing an error message
                // BUT NOT if user has intentionally minimized to menu bar
                let shouldStayVisible = !isMinimizedToMenu && (
                    isMouseInWindow || isNearIcon || isInSafeZone || 
                    dropZoneWindow.isShowingSuccess || dropZoneWindow.isShowingError || dropZoneWindow.isPerformingDrop
                )
                if shouldStayVisible {
                    if dropZoneWindow.alphaValue < 1 {
                        updateWindowStatus()
                        dropZoneWindow.show(under: statusItem)
                    }
                } else {
                    // Departure: Final Fade Out
                    if dropZoneWindow.alphaValue > 0 {
                         dropZoneWindow.hide()
                    }
                }
            }
        }
    }
    
    // MARK: - DropTargetViewDelegate
    private var hideWorkItem: DispatchWorkItem?

    func didEnterDrag() {
        // Cancel any pending hide
        hideWorkItem?.cancel()
        hideWorkItem = nil
        
        if !dropZoneWindow.isPerformingDrop && !dropZoneWindow.isShowingSuccess {
            updateWindowStatus()
        }
        dropZoneWindow.show(under: statusItem)
    }
    
    func didExitDrag() {
        // No-op: Visibility is handled by checkDragState
    }
    
    private func scheduleHide(delay: TimeInterval = 0.2) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            // Don't hide if showing success OR performing drop
            if self?.dropZoneWindow.isShowingSuccess == false && self?.dropZoneWindow.isPerformingDrop == false {
                self?.dropZoneWindow.hide()
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    
    func didPerformDrop(urls: [URL]) {
        isDragInsideWindow = false
        
        let targets: [Device]
        if selectedDeviceId == "broadcast" {
            targets = Array(devices.values)
        } else if let selected = devices[selectedDeviceId] {
            targets = [selected]
        } else {
            targets = []
        }
        
        guard !targets.isEmpty else {
            print("No devices to send to.")
            dropZoneWindow.hide()
            return
        }

        // 1. Initial Phase: Requesting
        dropZoneWindow.setStatusText("Requesting...")
        enableWakelock()
        dropZoneWindow.isPerformingDrop = true
        self.hasStartedTransfer = false
        
        Task {
            let app = self
            
            // 5s Grace period timer: if no response in 5s, hide to background
            let autoHideTask = Task {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        // If still requesting and haven't started actual sending
                        if !app.hasStartedTransfer && app.dropZoneWindow.isPerformingDrop {
                            logTransfer("⏱️ Grace period expired: Hiding to background...")
                            app.dropZoneWindow.hide()
                            app.updateStatusItemIcon(showDot: true) // Show dot when in background
                        }
                    }
                }
            }

            // Safety net: Timeout for the entire handshake+transfer lifecycle
            // Will be cancelled once transfer actually starts (onAccepted)
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        if self.dropZoneWindow.isPerformingDrop && !self.dropZoneWindow.isShowingSuccess {
                            logTransfer("🚨 App: Transfer timeout, closing.")
                            self.dropZoneWindow.isPerformingDrop = false
                            self.dropZoneWindow.hide()
                        }
                    }
                }
            }
            
            await fileSender.setOnCancelled {
                logTransfer("🛑 [App] fileSender.onCancelled callback triggered (Async).")
                DispatchQueue.main.async {
                    app.disableWakelock()
                    logTransfer("🛑 [App] fileSender.onCancelled handling on MainActor. PerformingDrop: \(app.dropZoneWindow.isPerformingDrop), ShowingSuccess: \(app.dropZoneWindow.isShowingSuccess)")
                    if app.dropZoneWindow.isPerformingDrop && !app.dropZoneWindow.isShowingSuccess {
                        logTransfer("🚨 [App] Showing Cancelled error on DropZoneWindow.")
                        app.dropZoneWindow.showError(message: "Cancelled")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            app.dropZoneWindow.hide()
                        }
                    } else {
                         logTransfer("⚠️ [App] Ignored cancellation because window state doesn't match dropping state.")
                    }
                }
            }

            // A. Prepare Phase callbacks
            await fileSender.setOnAccepted {
                autoHideTask.cancel() // Cancel the 5s timer immediately on acceptance
                timeoutTask.cancel()  // Cancel the 120s safety net — transfer is active now
                Task { @MainActor in
                    // Transition to Sending phase immediately when accepted
                    guard !app.dropZoneWindow.isShowingSuccess else { return }
                    
                    app.hasStartedTransfer = true
                    app.isMinimizedToMenu = false
                    app.currentTransferProgress = 0
                    app.dropZoneWindow.resetFromSuccess() // Clear "Requesting" state
                    let targetName = targets.first?.alias ?? "device"
                    app.currentTransferTarget = targetName
                    app.dropZoneWindow.setStatusText("Sending to \(targetName)...")
                    app.dropZoneWindow.isPerformingDrop = true 
                    
                    // Only show window if it was NOT hidden by the 5s timer 
                    // (User said "挂后台", so we respect the background state if it already went there)
                    if app.dropZoneWindow.alphaValue > 0.1 {
                        app.dropZoneWindow.show(under: app.statusItem)
                    } else {
                        logTransfer("📲 Transfer started in background mode.")
                    }
                }
            }

            await fileSender.setOnProgress { (progress: Double) in
                Task { @MainActor in
                    app.currentTransferProgress = progress
                    if !app.dropZoneWindow.isShowingSuccess {
                        app.dropZoneWindow.setProgress(progress)
                    }
                    // Update menu progress view if minimized
                    if app.isMinimizedToMenu, let menuItem = app.transferProgressMenuItem,
                       let progressView = menuItem.view as? TransferProgressMenuView {
                        progressView.progress = progress
                    }
                }
            }

            var allSuccessful = true
            var lastErrorMsg = ""
            
            // B. Perform actual send
            for device in targets {
                do {
                    logTransfer("App: Initiating send to \(device.alias)...")
                    try await self.fileSender.sendFiles(urls, to: device)
                } catch {
                    logTransfer("App: Error sending to \(device.alias): \(error)")
                    lastErrorMsg = error.localizedDescription
                    allSuccessful = false
                }
            }
            
            timeoutTask.cancel()
            
            // C. Completion Phase
            DispatchQueue.main.async {
                app.disableWakelock()
            }
            await MainActor.run {
                if allSuccessful {
                    logTransfer("✅ Final Success: Showing popup.")
                    app.isMinimizedToMenu = false
                    dropZoneWindow.setStatusText("Sent!")
                    dropZoneWindow.showSuccess()
                    
                    // CRITICAL: Always show success popup, even if it was "hung in background"
                    app.dropZoneWindow.show(under: app.statusItem)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.dropZoneWindow.hide()
                    }
                } else {
                    let msg: String
                    let errLower = lastErrorMsg.lowercased()
                    
                    // If transfer was already in progress and connection dropped,
                    // it means the peer cancelled — not "device offline"
                    if errLower.contains("cancel") || errLower.contains("closed") || errLower.contains("reset") {
                        msg = "Cancelled"
                    } else if (errLower.contains("connection") || errLower.contains("1005") || errLower.contains("1001")) && app.hasStartedTransfer {
                        msg = "Cancelled"  // Connection lost/timeout mid-transfer = peer cancelled
                    } else if errLower.contains("cancel") || errLower.contains("999") {
                        msg = "Cancelled"
                    } else if errLower.contains("connect") {
                        msg = "Device Offline"
                    } else if errLower.contains("timeout") {
                        msg = "Request Timeout"
                    } else if errLower.contains("declined") || errLower.contains("403") {
                        msg = "Declined by Peer"
                    } else {
                        msg = "Transfer Failed"
                    }
                    
                    app.isMinimizedToMenu = false
                    dropZoneWindow.showError(message: msg)
                    
                    // Always show error popup, even if minimized to menu
                    app.dropZoneWindow.show(under: app.statusItem)
                    
                    // Keep error visible for 3 seconds
                    logTransfer("🚨 UI: Showing error status: \(msg)")
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        // Double check if we are still showing an error (not overwritten by a new drop)
                        if self.dropZoneWindow.isShowingError { 
                            self.dropZoneWindow.hide()
                        }
                    }
                }
                app.hasStartedTransfer = false // Reset after error mapping logic
            }
        }
    }
    
    func startClipboardService() {
        // Stop automatic sending on clipboard change as per user request.
        // We still start the service so that lastChangeCount is maintained,
        // which helps in setContent() to avoid race conditions if we ever
        // re-enable monitoring.
        clipboardService.onNewContent = nil
        clipboardService.start()
    }
    
    func startTransferServer() async {
        // Setup Reverse Discovery Callback
        await transferServer.setOnDeviceRegistered { [weak self] device in
            DispatchQueue.main.async {
                self?.devices[device.id] = device
                self?.updateMenu()
            }
        }

        await transferServer.setOnTextReceived { [weak self] text in
            DispatchQueue.main.async {
                print("Received text from remote, updating clipboard...")
                self?.clipboardService.setContent(text)
            }
        }
        
        await transferServer.setOnCancelReceived { [weak self] in
            guard let self = self else { return }
            logTransfer("🛑 [App] HTTPTransferServer.onCancelReceived triggered.")
            Task {
                await self.fileSender.cancelCurrentTransfer()
            }
        }
        
        await transferServer.setOnTransferRequest { [weak self] request in
            logTransfer("📥 [App] Incoming transfer request from \(request.senderAlias) (\(request.fileCount) files, \(request.totalSize) bytes)")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.enableWakelock()
                self.hasStartedTransfer = true
                self.dropZoneWindow.resetFromSuccess()
                self.dropZoneWindow.setStatusText("Receiving from \(request.senderAlias)...")
                self.dropZoneWindow.isPerformingDrop = true
                self.dropZoneWindow.setProgress(0)
                self.dropZoneWindow.show(under: self.statusItem)
            }
            return true // Auto-accept
        }
        
        await transferServer.setOnProgress { [weak self] progress in
            DispatchQueue.main.async {
                self?.dropZoneWindow.setProgress(progress)
            }
        }
        
        await transferServer.setOnTransferComplete { [weak self] (success, errorMsg) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.disableWakelock()
                logTransfer("🏁 [App] Incoming transfer complete. Success: \(success), Error: \(errorMsg ?? "nil")")
                
                if success {
                    self.dropZoneWindow.setStatusText("Saved!")
                    self.dropZoneWindow.showSuccess()
                    self.dropZoneWindow.show(under: self.statusItem)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.dropZoneWindow.hide()
                    }
                } else {
                    let msg: String
                    let errLower = (errorMsg ?? "").lowercased()
                    if errLower.contains("cancel") || errLower.contains("truncated") {
                        msg = "Cancelled"
                    } else {
                        msg = "Failed"
                    }
                    self.dropZoneWindow.showError(message: msg)
                    self.dropZoneWindow.show(under: self.statusItem)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                         if self.dropZoneWindow.isShowingError {
                             self.dropZoneWindow.hide()
                         }
                    }
                }
                self.hasStartedTransfer = false
            }
        }
        
        do {
            if discoveryService.protocolType == .https {
                logTransfer("🌐 Fetching certificate for HTTPS Server...")
                let p12Data = try await CertificateManager.shared.getP12Data()
                try await transferServer.start(p12Data: p12Data)
            } else {
                logTransfer("🌐 Starting Server in HTTP mode...")
                try await transferServer.start()
            }
        } catch {
            logTransfer("❌ CRITICAL: Failed to start Transfer Server: \(error)")
            logTransfer("❌ Current Mode: \(discoveryService.protocolType). NO FALLBACK allowed to prevent protocol mismatch.")
            // Do NOT try to start in plain mode here. If it fails, we want it to fail loudly.
        }
    }
    
    func startDiscovery() {
        discoveryService.onDeviceFound = { [weak self] device in
            DispatchQueue.main.async {
                self?.devices[device.id] = device
                self?.updateMenu()
            }
        }
        
        discoveryService.start()
        
        // Send announcement every 5 seconds
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.discoveryService.sendAnnouncement()
            }
        }
    }
    
    func setupMenu() {
        let menu: NSMenu
        if let existing = statusItem.menu {
            menu = existing
            menu.removeAllItems()
        } else {
            menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            statusItem.menu = menu
        }
        
        // 1. Core Action
        menu.addItem(NSMenuItem(title: "Send Clipboard", action: #selector(sendClipboard), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        
        // 2. KNOWN DEVICES
        let knownDevices = devices.values.filter { historyDeviceIds.contains($0.id) || selectedDeviceId == $0.id }
            .sorted(by: { $0.alias < $1.alias })
            
        if !knownDevices.isEmpty {
            let headerItem = NSMenuItem()
            headerItem.view = MenuSectionHeaderView(title: "KNOWN DEVICES")
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            
            for device in knownDevices {
                addDeviceItem(to: menu, device: device, canForget: true)
            }
            menu.addItem(NSMenuItem.separator())
        }
        
        // 3. OTHER DEVICES
        let otherDevices = devices.values.filter { !historyDeviceIds.contains($0.id) && selectedDeviceId != $0.id }
            .sorted(by: { $0.alias < $1.alias })
            
        let otherHeaderItem = NSMenuItem()
        otherHeaderItem.view = MenuSectionHeaderView(title: "OTHER DEVICES")
        otherHeaderItem.isEnabled = false
        menu.addItem(otherHeaderItem)
        
        if otherDevices.isEmpty {
            let searchingItem = NSMenuItem(title: "  Searching nearby...", action: nil, keyEquivalent: "")
            searchingItem.isEnabled = false
            menu.addItem(searchingItem)
        } else {
            for device in otherDevices {
                addDeviceItem(to: menu, device: device, canForget: false)
            }
        }
        
        // 4. BROADCAST
        let broadcastItem = NSMenuItem(title: "All Devices (Broadcast)", action: #selector(deviceSelected(_:)), keyEquivalent: "")
        broadcastItem.representedObject = "broadcast"
        broadcastItem.state = selectedDeviceId == "broadcast" ? .on : .off
        menu.addItem(broadcastItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 5. ADVANCED SUBMENU
        let advancedMenu = NSMenu(title: "Advanced")
        advancedMenu.autoenablesItems = false
        
        advancedMenu.addItem(NSMenuItem(title: "Add Device by IP...", action: #selector(addDeviceByIP), keyEquivalent: "a"))
        advancedMenu.addItem(NSMenuItem(title: "Rescan and Refresh", action: #selector(scanForDevices(_:)), keyEquivalent: "r"))
        advancedMenu.addItem(NSMenuItem(title: "Clear Discovered Devices", action: #selector(clearDeviceHistory), keyEquivalent: ""))
        advancedMenu.addItem(NSMenuItem(title: "Reset Identity", action: #selector(resetIdentity(_:)), keyEquivalent: ""))
        
        advancedMenu.addItem(NSMenuItem.separator())
        let autoUpdateItem = NSMenuItem(title: "Auto-check for Updates", action: #selector(toggleAutoUpdate(_:)), keyEquivalent: "")
        autoUpdateItem.state = isAutoUpdateEnabled ? .on : .off
        advancedMenu.addItem(autoUpdateItem)
        
        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advancedItem.submenu = advancedMenu
        menu.addItem(advancedItem)
        
        // 6. SYSTEM STATUS
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 7. VERSION & UPDATE
        let updateItem = NSMenuItem()
        updateItem.view = UpdateMenuItemView()
        menu.addItem(updateItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit AirSend", action: #selector(quit), keyEquivalent: "q"))
    }
    
    private func addDeviceItem(to menu: NSMenu, device: Device, canForget: Bool) {
        // IMPORTANT: No action here to prevent menu from auto-closing on click
        let deviceItem = NSMenuItem(title: device.alias, action: nil, keyEquivalent: "")
        deviceItem.representedObject = device.id
        deviceItem.isEnabled = true 
        
        let connectionState: DeviceMenuItemView.ConnectionState
        if connectingDeviceId == device.id {
            connectionState = .connecting
        } else if selectedDeviceId == device.id {
            connectionState = .connected
        } else {
            connectionState = .idle
        }
        
        deviceItem.view = DeviceMenuItemView(device: device, state: connectionState, canForget: canForget)
        menu.addItem(deviceItem)
    }
    
    func updateMenu() {
        setupMenu()
        updateWindowStatus()
    }
    
    @objc func sendClipboard() {
        print("Send Clipboard clicked")
        if let str = NSPasteboard.general.string(forType: .string) {
            let targets: [Device]
            if selectedDeviceId == "broadcast" {
                targets = Array(devices.values)
            } else if let selected = devices[selectedDeviceId] {
                targets = [selected]
            } else {
                targets = []
            }
            
            print("Clipboard content found: \(str.count) chars")
            print("Sending to \(targets.count) devices")
            
            for device in targets {
                print("Targeting device: \(device.alias) at \(device.ip)")
                Task {
                    do {
                        try await clipboardSender.sendText(str, to: device)
                    } catch {
                        print("Error sending to \(device.alias): \(error)")
                    }
                }
            }
        } else {
            print("No text in clipboard")
        }
    }
    
    @objc func scanForDevices(_ sender: NSMenuItem) {
        print("Manual scan triggered - cleaning up offline other devices")
        
        // Cleanup logic: Keep only history devices or the currently selected one
        let historyIds = self.historyDeviceIds
        let selectedId = self.selectedDeviceId
        
        var nextDevices: [String: Device] = [:]
        for (id, device) in devices {
            if historyIds.contains(id) || selectedId == id {
                nextDevices[id] = device
            }
        }
        
        self.devices = nextDevices
        
        discoveryService.triggerScan()
        
        // Prevent menu from closing and show immediate feedback
        // The menu normally closes on action. We can pop it back up immediately
        // or just let the user re-open it. To really simulate Wi-Fi behavior
        // where you stay IN the menu, we'd need a more complex view-based menu.
        // For now, let's just make it fast and responsive.
        
        // Trick: Reset the menu to show "Scanning" status without closing 
        // if it was triggered via a key equivalent. 
        // If clicked, it WILL close. To stay open, we re-pop it.
        DispatchQueue.main.async {
            self.statusItem.button?.performClick(nil)
        }
    }
    
    @objc func resetIdentity(_ sender: AnyObject?) {
        logTransfer("🧨 Starting Identity Reset...")
        
        Task { @MainActor in
            // 1. Stop services
            // Silent operation - no UI feedback
            
            await transferServer.stop()
            discoveryService.stop()
            
            // 2. Regenerate Certificate
            do {
                try await CertificateManager.shared.forceRegenerate()
                let newFingerprint = try await CertificateManager.shared.getFingerprint()
                self.fingerprint = newFingerprint
                logTransfer("✅ New Identity Fingerprint: \(newFingerprint)")
                
                // 3. Restart Services
                // Preference: HTTPS
                let targetProtocol = ProtocolType.https
                
                self.transferServer = HTTPTransferServer(fingerprint: newFingerprint)
                self.discoveryService = UDPDiscoveryService(fingerprint: newFingerprint, protocolType: targetProtocol)
                self.fileSender = FileSender(fingerprint: newFingerprint, localProtocol: targetProtocol)
                self.clipboardSender = ClipboardSender(fingerprint: newFingerprint, localProtocol: targetProtocol)
                
                // Clear discovered devices to force fresh discovery
                let keptDevices = devices.filter { historyDeviceIds.contains($0.key) || selectedDeviceId == $0.key }
                self.devices = keptDevices
                
                startDiscovery()
                await startTransferServer()
                startClipboardService()
                startDragMonitoring()
                
                logTransfer("✨ Identity Reset Complete. Services restarted.")
                
                // Silent completion
                DispatchQueue.main.async {
                    self.updateMenu()
                }
                
            } catch {
                logTransfer("❌ Reset Identity Failed: \(error)")
            }
        }
    }

    @objc func addDeviceByIP() {
        let alert = NSAlert()
        alert.messageText = "Add Device by IP"
        alert.informativeText = "Enter the IP address of the target LocalSend instance:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        let inputTextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        inputTextField.placeholderString = "192.168.1.100"
        alert.accessoryView = inputTextField
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let ip = inputTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty {
                // For manual IP, we create a pseudo-device or just try to send
                // Let's create a temporary device object
                let manualDevice = Device(
                    id: "manual-\(ip)",
                    alias: "Manual IP (\(ip))",
                    ip: ip,
                    port: 53317,
                    deviceModel: "Remote Device",
                    deviceType: .desktop,
                    version: "2.1",
                    https: false,
                    download: true,
                    lastSeen: Date()
                )
                self.devices[manualDevice.id] = manualDevice
                self.selectedDeviceId = manualDevice.id
            }
        }
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        print("📡 Menu: Opening... starting high-frequency scan.")
        // Perform an initial scan immediately
        discoveryService.triggerScan()
        
        // Auto Update Check (if enabled)
        if isAutoUpdateEnabled {
            UpdateService.shared.checkUpdate(explicit: false)
        }
        
        // Start a 1-second timer for continuous scanning while menu is open
        menuScanTimer?.invalidate()
        menuScanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Stop scanning if a specific device is selected or being connected
                if self?.selectedDeviceId != "broadcast" || self?.connectingDeviceId != nil {
                    print("📡 Menu: Active selection/connection detected, stopping aggressive scan.")
                    self?.menuScanTimer?.invalidate()
                    self?.menuScanTimer = nil
                    return
                }
                
                print("📡 Menu: Periodic scan while open...")
                self?.discoveryService.triggerScan()
            }
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        print("📡 Menu: Closed. Stopping high-frequency scan.")
        menuScanTimer?.invalidate()
        menuScanTimer = nil
    }
    
    @objc func deviceSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { 
            print("🚨 Selector ERROR: Missing ID in representedObject")
            return 
        }
        
        print("🚨 Selector: User clicked device ID [\(id)]")
        
        if id == "broadcast" {
            self.selectedDeviceId = id
            return
        }
        
        // For physical devices, we handle it via handleDeviceClick now 
        // derived from the custom view for smoother stay-open behavior.
        handleDeviceClick(id: id, closeMenu: true)
    }

    func handleDeviceClick(id: String, closeMenu: Bool) {
        print("🚨 App: Handling device click for [\(id)], closeMenu: \(closeMenu)")
        
        if connectingDeviceId == id { return }
        
        self.connectingDeviceId = id
        
        // If it's a manual selection that SHOULD close the menu (like from broadcast), 
        // we let it. But for Wi-Fi style, we stay open.
        
        // Simulate connection delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            print("🚨 App: Connection successful for [\(id)]")
            self.connectingDeviceId = nil
            self.selectedDeviceId = id
            
            if closeMenu {
                // If it was a deep action, maybe close now. 
                // But for the Wi-Fi experience, we might want to stay open 
                // until user clicks away or it's finished.
            }
        }
    }

    func forgetDevice(id: String) {
        print("🚨 App: Forgetting device [\(id)]")
        
        // 1. Remove from history ONLY
        // We do NOT remove from 'devices' dictionary so it remains visible in "Other Devices"
        var currentHistory = historyDeviceIds
        currentHistory.remove(id)
        historyDeviceIds = currentHistory
        
        // 2. If it was selected, fallback to broadcast
        if selectedDeviceId == id {
            selectedDeviceId = "broadcast"
        }
        
        // 3. Update UI
        updateMenu()
        saveDevices()
    }
    
    @MainActor
    @objc func quit() {
        discoveryService.stop()
        NSApplication.shared.terminate(self)
    }
    
    // MARK: - System Integration
    
    private func enableWakelock() {
        guard wakelockAssertionID == 0 else { return }
        let reason = "LocalSend is transferring files" as CFString
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                reason,
                                                &wakelockAssertionID)
        if result == kIOReturnSuccess {
            logTransfer("🔋 Wakelock enabled: Prevent system sleep during transfer.")
        } else {
            logTransfer("⚠️ Failed to enable Wakelock: \(result)")
        }
    }
    
    private func disableWakelock() {
        guard wakelockAssertionID != 0 else { return }
        let result = IOPMAssertionRelease(wakelockAssertionID)
        if result == kIOReturnSuccess {
            logTransfer("🔋 Wakelock disabled: System can now sleep.")
            wakelockAssertionID = 0
        } else {
            logTransfer("⚠️ Failed to disable Wakelock: \(result)")
        }
    }
    
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            let service = SMAppService()
            do {
                if service.status == SMAppService.Status.enabled {
                    try service.unregister()
                    logTransfer("🚀 Launch at Login disabled.")
                } else {
                    try service.register()
                    logTransfer("🚀 Launch at Login enabled.")
                }
                updateMenu() // Refresh checkmark
            } catch {
                logTransfer("❌ Failed to toggle Launch at Login: \(error)")
            }
        }
    }
    
    // MARK: - Update Logic
    
    @objc func manualCheckUpdate() {
        print("🚨 App: Manual update check triggered.")
        UpdateService.shared.checkUpdate(explicit: true)
    }
    
    @objc func toggleAutoUpdate(_ sender: NSMenuItem) {
        isAutoUpdateEnabled.toggle()
        print("🚨 App: Auto-update toggled to [\(isAutoUpdateEnabled)]")
    }
}

// Execution Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()


