import Cocoa
import QuartzCore

// Custom rounded progress bar with gradient fill
class RoundedProgressView: NSView {
    var progress: Double = 0 {
        didSet {
            progress = max(0, min(1, progress))
            needsDisplay = true
        }
    }
    
    var trackColor: NSColor = NSColor.white.withAlphaComponent(0.1)
    var barColors: [NSColor] = [.controlAccentColor, .systemBlue]
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds
        let radius = rect.height / 2
        
        // Track
        let trackPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        trackColor.setFill()
        trackPath.fill()
        
        // Fill
        guard progress > 0 else { return }
        let fillWidth = max(rect.height, rect.width * CGFloat(progress)) // Min width = height (full circle)
        let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: rect.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        
        // Gradient fill
        NSGraphicsContext.saveGraphicsState()
        fillPath.addClip()
        let gradient = NSGradient(colors: barColors)!
        gradient.draw(in: fillRect, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// 1. Dashed Border View - Purely visual
class DashedBorderView: NSView {
    var borderColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: self.bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        let dashPattern: [CGFloat] = [6, 4]
        path.setLineDash(dashPattern, count: 2, phase: 0)
        path.lineWidth = 2
        borderColor.setStroke()
        path.stroke()
    }
}

// 2. Content View - Handles Drag & Hover Logic
@MainActor
class DropZoneContentView: NSVisualEffectView {
    var onDrop: (([URL]) -> Void)?
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    
    weak var borderView: DashedBorderView?
    weak var iconView: NSImageView?
    weak var statusLabel: NSTextField?
    weak var progressBar: RoundedProgressView?
    weak var percentLabel: NSTextField?
    weak var requestView: RequestOverlayView? // NEW
    
    private(set) var isExpanded: Bool = false
    private(set) var isShowingSuccess: Bool = false
    private(set) var isShowingError: Bool = false
    var isPerformingDrop: Bool = false
    var isRequesting: Bool = false // NEW
    
    private var requestContinuation: CheckedContinuation<Bool, Never>? // CHECK: Handling concurrency
    
    /// Called when user clicks the window during an active transfer (to minimize to menu)
    var onClickDuringTransfer: (() -> Void)?
    
    override func mouseDown(with event: NSEvent) {
        // Only intercept clicks during active transfer (not during success/error/idle)
        if isPerformingDrop && !isShowingSuccess && !isShowingError && !isRequesting {
            onClickDuringTransfer?()
            return
        }
        super.mouseDown(with: event)
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setup() {
        self.material = .hudWindow
        self.state = .active
        self.blendingMode = .behindWindow
        self.wantsLayer = true
        self.layer?.cornerRadius = 16
        self.layer?.masksToBounds = true
        self.registerForDraggedTypes([.fileURL])
    }
    
    // NEW: Request Flow
    func startRequest(sender: String, info: String) {
        isRequesting = true
        requestView?.configure(sender: sender, info: info)
        
        // Hide standard UI
        iconView?.animator().alphaValue = 0
        statusLabel?.animator().alphaValue = 0
        borderView?.animator().alphaValue = 0
        
        // Show Request UI
        requestView?.isHidden = false
        requestView?.animator().alphaValue = 1
    }
    
    func awaitRequestAction() async -> Bool {
        return await withCheckedContinuation { continuation in
            if requestContinuation != nil {
                requestContinuation?.resume(returning: false)
            }
            requestContinuation = continuation
            
            requestView?.onAccept = { [weak self] in
                self?.completeRequest(accepted: true)
            }
            requestView?.onDecline = { [weak self] in
                self?.completeRequest(accepted: false)
            }
        }
    }

    func showRequest(sender: String, info: String) async -> Bool {
        startRequest(sender: sender, info: info)
        return await awaitRequestAction()
    }
    
    func completeRequest(accepted: Bool) {
        requestContinuation?.resume(returning: accepted)
        requestContinuation = nil
        isRequesting = false
        
        // Hide Request View
        requestView?.animator().alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.requestView?.isHidden = true
        }
        
        // If declined, hide the window immediately
        if !accepted {
             // We need to call the WINDOW's hide method, but we are in the view.
             // We can access properties but this is a bit messy. 
             // Ideally, the caller (DropZoneWindow) should handle it, but wait, 
             // askUser is awaiting this.
             // Let's rely on DropZoneWindow's logic or add a callback.
             // Actually, since askUser awaits, let's look at main.swift.
             // Ah, main.swift calls await askUser. If it returns false, main logic ends.
             // But the window stays open because nothing tells it to close.
             // We must close it here or in main.swift. 
             // Let's do it in main.swift for cleaner logic, OR here for self-containment.
             // Let's ADD a closure callback to the View to request window hide.
             // OR simpler: access window.
             self.window?.animator().alphaValue = 0
             self.window?.orderOut(nil)
        }
    }
    
    // NEW: Transition to Receiving State
    func prepareForReceive() {
        isRequesting = false
        isPerformingDrop = true
        isShowingSuccess = false
        isShowingError = false
        
        // Hide Request View
        requestView?.animator().alphaValue = 0
        requestView?.isHidden = true
        
        // Show Standard UI
        iconView?.animator().alphaValue = 1
        statusLabel?.animator().alphaValue = 1
        borderView?.animator().alphaValue = 1
        
        // Show Progress
        progressBar?.alphaValue = 1
        progressBar?.progress = 0
        percentLabel?.alphaValue = 1
        percentLabel?.stringValue = "0%"
        
        statusLabel?.stringValue = "Preparing..."
    }
    
    // Override reset to include requestView
    func resetFromSuccess() {
        isShowingSuccess = false
        isShowingError = false
        isExpanded = false
        isPerformingDrop = false
        isRequesting = false
        
        iconView?.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Drop")
        iconView?.contentTintColor = .labelColor
        iconView?.layer?.transform = CATransform3DIdentity
        iconView?.layer?.removeAllAnimations()
        iconView?.layer?.shadowOpacity = 0
        iconView?.layer?.shadowRadius = 0
        iconView?.alphaValue = 1 // Restore
        
        statusLabel?.textColor = .labelColor
        statusLabel?.stringValue = "" // Reset text
        statusLabel?.alphaValue = 1 // Restore
        
        borderView?.alphaValue = 1 // Restore
        
        progressBar?.progress = 0
        progressBar?.animator().alphaValue = 0
        percentLabel?.stringValue = ""
        percentLabel?.animator().alphaValue = 0
        
        requestView?.alphaValue = 0
        requestView?.isHidden = true
        requestContinuation?.resume(returning: false) // Safety: ensure any pending continuation is released
        requestContinuation = nil
    }
    
    // --- Hover Logic ---
    
    func expand() {
        guard !isExpanded && !isShowingSuccess, let layer = iconView?.layer else { return }
        isExpanded = true
        
        // Use a faster spring for instant response
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.damping = 12
        spring.stiffness = 150
        spring.mass = 1
        spring.fromValue = 1.0
        spring.toValue = 1.3
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        layer.add(spring, forKey: "hoverScale")
        layer.transform = CATransform3DMakeScale(1.3, 1.3, 1.0)
        
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.duration = 0.15 // Faster response
        glow.fromValue = layer.presentation()?.shadowOpacity ?? 0.0
        glow.toValue = 0.8
        glow.fillMode = .forwards
        glow.isRemovedOnCompletion = false
        layer.add(glow, forKey: "hoverGlow")
        
        layer.shadowColor = NSColor.controlAccentColor.cgColor
        layer.shadowRadius = 15
        layer.shadowOffset = .zero
    }
    
    func contract() {
        guard isExpanded && !isShowingSuccess, let layer = iconView?.layer else { return }
        isExpanded = false
        
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.damping = 20
        spring.stiffness = 250
        spring.fromValue = 1.3
        spring.toValue = 1.0
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        layer.add(spring, forKey: "hoverScale")
        layer.transform = CATransform3DIdentity
        
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.duration = 0.15 // Faster response
        fade.fromValue = layer.presentation()?.shadowOpacity ?? 0.8
        fade.toValue = 0.0
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "hoverGlow")
        layer.shadowOpacity = 0
    }

    func showSuccess() {
        guard !isShowingSuccess, let layer = iconView?.layer else { 
            isPerformingDrop = false // Cleanup if somehow called twice
            return 
        }
        isShowingSuccess = true
        isPerformingDrop = false // Drop handling is officially over/transitioned to animation
        
        // 1. Switch Icon & Text
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        iconView?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Success")
        iconView?.contentTintColor = .systemGreen
        iconView?.alphaValue = 1 // Ensure visible
        
        statusLabel?.stringValue = "Sent!"
        statusLabel?.textColor = .systemGreen
        statusLabel?.alphaValue = 1 // Ensure visible
        
        borderView?.animator().alphaValue = 0 // Hide dashed border
        CATransaction.commit()

        // 2. High-end Pop Animation
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.damping = 15
        spring.stiffness = 300
        spring.mass = 1.0
        spring.initialVelocity = 0
        spring.fromValue = 1.0
        spring.toValue = 1.2
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        layer.add(spring, forKey: "successPop")
        layer.transform = CATransform3DMakeScale(1.2, 1.2, 1.0) // Hold at 1.2

        // 3. Smooth LARGE Pulse/Glow (Coordinated with Window Hide)
        let pulseGlow = CABasicAnimation(keyPath: "shadowRadius")
        pulseGlow.fromValue = 0
        pulseGlow.toValue = 80 // Increased glow size
        
        let pulseOpacity = CABasicAnimation(keyPath: "shadowOpacity")
        pulseOpacity.fromValue = 1.0
        pulseOpacity.toValue = 0.0
        
        let group = CAAnimationGroup()
        group.animations = [pulseGlow, pulseOpacity]
        group.duration = 1.2 // Sync with the hide delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards  // CRITICAL: Prevent snapping
        group.isRemovedOnCompletion = false
        
        layer.shadowColor = NSColor.systemGreen.cgColor
        layer.shadowOffset = .zero
        layer.add(group, forKey: "successPulse")
    }

    func showError(message: String) {
        // We set isShowingError to true to "pin" the window visibility in AppDelegate
        isShowingError = true 
        isShowingSuccess = false 
        isPerformingDrop = false  // Transfer is done (error/cancel)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        iconView?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
        iconView?.contentTintColor = .systemRed
        iconView?.alphaValue = 1 // Ensure visible
        
        statusLabel?.stringValue = message
        statusLabel?.textColor = .systemRed
        statusLabel?.alphaValue = 1 // Ensure visible
        
        borderView?.animator().alphaValue = 0
        CATransaction.commit()

        // Simple shake animation for error
        let shake = CABasicAnimation(keyPath: "position")
        shake.duration = 0.08
        shake.repeatCount = 3
        shake.autoreverses = true
        let currentPos = iconView?.layer?.position ?? .zero
        shake.fromValue = NSValue(point: CGPoint(x: currentPos.x - 6, y: currentPos.y))
        shake.toValue = NSValue(point: CGPoint(x: currentPos.x + 6, y: currentPos.y))
        iconView?.layer?.add(shake, forKey: "errorShake")
    }


    
    func setProgress(_ value: Double) {
        // If we are showing success, don't revert to progress bar
        guard !isShowingSuccess && isPerformingDrop else { return }
        
        if progressBar?.alphaValue == 0 {
            progressBar?.animator().alphaValue = 1
            percentLabel?.animator().alphaValue = 1
        }
        
        progressBar?.progress = value
        let pct = Int(value * 100)
        percentLabel?.stringValue = "\(pct)%"
    }
    
    // --- Draggable Implementation ---
    
    var isBorderHighlighted: Bool = false {
        didSet {
            borderView?.borderColor = isBorderHighlighted ? .controlAccentColor : .secondaryLabelColor
        }
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return .copy
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // 1. Critical: Mark as performing drop IMMEDIATELY and synchronously
        // to prevent AppDelegate's timer from hiding us.
        self.isPerformingDrop = true
        
        // 2. Read URLs correctly
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            self.isPerformingDrop = false
            return false
        }
        
        // 3. Trigger callback and standard success flow
        onDrop?(urls)
        
        // Success state will be managed by AppDelegate calling showSuccess() 
        // which now handles clearing isPerformingDrop.
        return true
    }
}

// --- Request UI Helper Classes ---

class HoverButton: NSButton {
    let baseColor: NSColor
    
    init(title: String, color: NSColor) {
        self.baseColor = color
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .rounded
        self.wantsLayer = true
        self.isBordered = false
        self.layer?.backgroundColor = color.withAlphaComponent(0.2).cgColor
        self.layer?.cornerRadius = 8
        
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        self.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .paragraphStyle: style
        ])
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
            addTrackingArea(area)
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            self.layer?.backgroundColor = baseColor.withAlphaComponent(0.4).cgColor
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            self.layer?.backgroundColor = baseColor.withAlphaComponent(0.2).cgColor
        }
    }
}

class RequestOverlayView: NSView {
    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?
    
    private let titleLabel = NSTextField(labelWithString: "接收文件")
    let senderLabel = NSTextField(labelWithString: "")
    let infoLabel = NSTextField(labelWithString: "")
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        wantsLayer = true
        
        // Title
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        
        // Sender
        senderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        senderLabel.textColor = .systemBlue
        senderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(senderLabel)
        
        // Info
        infoLabel.font = .systemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(infoLabel)
        
        // Buttons
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 15
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        
        let declineBtn = HoverButton(title: "拒绝", color: .systemRed)
        declineBtn.target = self
        declineBtn.action = #selector(handleDecline)
        stack.addArrangedSubview(declineBtn)
        
        let acceptBtn = HoverButton(title: "接收", color: .systemGreen)
        acceptBtn.target = self
        acceptBtn.action = #selector(handleAccept)
        stack.addArrangedSubview(acceptBtn)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            
            senderLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            senderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            
            infoLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 4),
            infoLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: 160),
            stack.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
    
    @objc private func handleDecline() { onDecline?() }
    @objc private func handleAccept() { onAccept?() }
    
    func configure(sender: String, info: String) {
        senderLabel.stringValue = sender
        infoLabel.stringValue = info
    }
}

// 3. Main Window Class
@MainActor
class DropZoneWindow: NSPanel {
    private let dropView = DropZoneContentView()
    
    var onDrop: (([URL]) -> Void)? { get { dropView.onDrop } set { dropView.onDrop = newValue } }
    var onDragEnter: (() -> Void)? { get { dropView.onDragEnter } set { dropView.onDragEnter = newValue } }
    var onDragExit: (() -> Void)? { get { dropView.onDragExit } set { dropView.onDragExit = newValue } }
    var onClickDuringTransfer: (() -> Void)? { get { dropView.onClickDuringTransfer } set { dropView.onClickDuringTransfer = newValue } }
    
    var isIconExpanded: Bool {
        get { dropView.isExpanded }
        set { 
            if newValue { dropView.expand() }
            else { dropView.contract() }
        }
    }
    
    func setStatusText(_ text: String) {
        dropView.statusLabel?.stringValue = text
    }
    
    var isBorderHighlighted: Bool {
        get { dropView.isBorderHighlighted }
        set { dropView.isBorderHighlighted = newValue }
    }

    var isShowingSuccess: Bool {
        dropView.isShowingSuccess
    }

    var isShowingError: Bool {
        dropView.isShowingError
    }

    var isPerformingDrop: Bool {
        get { dropView.isPerformingDrop }
        set { dropView.isPerformingDrop = newValue }
    }

    var isRequesting: Bool {
        dropView.isRequesting
    }
    
    func setProgress(_ value: Double) {
        dropView.setProgress(value)
    }
    
    func showSuccess() {
        dropView.showSuccess()
    }
    
    func showError(message: String) {
        dropView.showError(message: message)
    }
    
    func resetFromSuccess() {
        dropView.resetFromSuccess()
    }
    
    // NEW: Request Handling
    func askUser(requestSender: String, fileInfo: String) async -> Bool {
        // Reset state
        dropView.resetFromSuccess()
        
        // 1. Setup UI and State IMMEDIATELY
        dropView.startRequest(sender: requestSender, info: fileInfo)
        
        // 2. Wait for user action
        return await dropView.awaitRequestAction()
    }
    
    func prepareForReceive() {
        dropView.prepareForReceive()
    }
    
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
                   styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
                   backing: .buffered,
                   defer: false)
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .transient]
        self.contentView = dropView
        
        setupUI()
    }
    
    private func setupUI() {
        // 1. Dashed Border
        let borderView = DashedBorderView()
        borderView.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(borderView)
        dropView.borderView = borderView
        
        // 2. Icon - THE DEFINITIVE CENTERED APPROACH
        // We use a centered iconView with manually managed Layer anchor and position.
        let iconSize: CGFloat = 80
        let iconView = NSImageView(image: NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Drop") ?? NSImage())
        iconView.symbolConfiguration = .init(pointSize: 42, weight: .semibold)
        iconView.contentTintColor = .labelColor
        iconView.wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        
        dropView.addSubview(iconView)
        dropView.iconView = iconView
        
        // 3. Label - Initialize empty, will be set by AppDelegate
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(label)
        dropView.statusLabel = label
        
        // 4. Custom rounded progress bar
        let progressBar = RoundedProgressView()
        progressBar.alphaValue = 0 // Hidden by default
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(progressBar)
        dropView.progressBar = progressBar
        
        // 5. Percentage label
        let percentLabel = NSTextField(labelWithString: "")
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alphaValue = 0
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(percentLabel)
        dropView.percentLabel = percentLabel
        
        // 6. Request Overlay (Hidden by default)
        let requestView = RequestOverlayView()
        requestView.alphaValue = 0
        requestView.isHidden = true
        requestView.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(requestView)
        dropView.requestView = requestView
        
        // Constraints
        NSLayoutConstraint.activate([
            borderView.topAnchor.constraint(equalTo: dropView.topAnchor, constant: 10),
            borderView.bottomAnchor.constraint(equalTo: dropView.bottomAnchor, constant: -10),
            borderView.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 10),
            borderView.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -10),
            
            iconView.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: dropView.centerYAnchor, constant: -18),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
            
            progressBar.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 35),
            progressBar.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -35),
            progressBar.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            progressBar.heightAnchor.constraint(equalToConstant: 6),
            
            percentLabel.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            percentLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            
            label.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            label.topAnchor.constraint(equalTo: percentLabel.bottomAnchor, constant: 2),
            
            // Request View fills content
            requestView.topAnchor.constraint(equalTo: dropView.topAnchor),
            requestView.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
            requestView.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            requestView.trailingAnchor.constraint(equalTo: dropView.trailingAnchor)
        ])
    }
    
    // In macOS, AutoLayout and anchorPoint change don't mix well. 
    // We override layout to ensure the Layer is always centered correctly after AutoLayout finishes.
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        if let iconView = dropView.iconView, let layer = iconView.layer {
            // Anchor point (0.5, 0.5) is critical for center scaling.
            // But AutoLayout sets the frame. In standard macOS views, (0.5, 0.5) anchor 
            // means we must set position to the center of that frame.
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: iconView.frame.midX, y: iconView.frame.midY)
        }
    }
    
    func show(under statusItem: NSStatusItem) {
        // [LOG] Log show request
        let currentAlpha = self.alphaValue
        let isOrderedIn = self.isVisible
        FileLogger.log("✨ DropZoneWindow.show() called. Alpha: \(currentAlpha), OrderedIn: \(isOrderedIn)")

        var targetFrame: NSRect?
        
        if let button = statusItem.button, let windowFrame = button.window?.frame {
             targetFrame = windowFrame
        } else {
             FileLogger.log("⚠️ show() warning: No status item frame found. Using fallback.")
             if let screen = NSScreen.main {
                 let frame = screen.visibleFrame
                 targetFrame = NSRect(x: frame.maxX - 40, y: frame.maxY - 10, width: 22, height: 22)
             }
        }
        
        self.ignoresMouseEvents = false
        
        if let frame = targetFrame {
            let x = frame.midX - (self.frame.width / 2)
            let y = frame.minY - self.frame.height - 10
            
            // OPTIMIZATION: Fix flicker by being more careful about when we reset alpha.
            // If the window is already being shown (alpha > 0), don't snap it back to 0.
            if currentAlpha < 0.01 && !isOrderedIn {
                FileLogger.log("📍 Initial positioning at: \(x), \(y) (Resetting alpha to 0)")
                self.setFrameOrigin(NSPoint(x: x, y: y))
                self.alphaValue = 0
                self.makeKeyAndOrderFront(nil)
            } else {
                // Window is already visible or animating, just ensure it's in the right place.
                if abs(self.frame.origin.x - x) > 1 || abs(self.frame.origin.y - y) > 1 {
                    FileLogger.log("📍 Moving visible window to: \(x), \(y) (Current Alpha: \(currentAlpha))")
                    self.setFrameOrigin(NSPoint(x: x, y: y))
                }
                
                // If it was ordered out but had alpha, bring it back
                if !isOrderedIn {
                    FileLogger.log("👁️ Window was hidden but had alpha, ordering front.")
                    self.makeKeyAndOrderFront(nil)
                }
            }
        } else {
             FileLogger.log("❌ show() failed: Could not determine target frame.")
        }
        
        // Ensure we animate to 1 if not already there
        if self.alphaValue < 0.99 {
            FileLogger.log("✨ Animating Alpha \(currentAlpha) -> 1")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.animator().alphaValue = 1
            }
        }
    }
    

    func hide() {
        // If showing a request, do NOT hide!
        if dropView.isRequesting { return }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            self.animator().alphaValue = 0
        }) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if self.alphaValue == 0 {
                    self.orderOut(nil)
                    // Only reset state when NOT actively transferring
                    // (During transfer, hide is just a visual hide for "minimize to menu")
                    if !self.dropView.isPerformingDrop {
                        self.dropView.resetFromSuccess()
                    }
                }
            }
        }
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
