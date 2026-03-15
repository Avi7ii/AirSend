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

// 2. Content View - 透明外层容器，处理 Drag 事件（比视觅区域大 30px，就是为了让 performDragOperation 一定被调用）
@MainActor
class DropZoneContentView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?

    /// 视觅盒子：240x180 frosted glass，是展示给用户的全部内容。
    /// 外层 DropZoneContentView 是 300x240 透明拖放识别层。
    let contentBox = NSVisualEffectView()
    
    weak var borderView: DashedBorderView?
    weak var iconView: NSImageView?
    weak var statusLabel: NSTextField?
    weak var progressBar: RoundedProgressView?
    weak var percentLabel: NSTextField?
    weak var requestView: RequestOverlayView?
    
    private(set) var isExpanded: Bool = false
    private(set) var isShowingSuccess: Bool = false
    private(set) var isShowingError: Bool = false
    var isPerformingDrop: Bool = false
    var isRequesting: Bool = false
    /// Drag session 正在飞行中（已进入视图但尚未 performDragOperation 完成）
    private(set) var isAcceptingDragSession: Bool = false
    private var dragExitWorkItem: DispatchWorkItem?
    
    private var requestContinuation: CheckedContinuation<Bool, Never>?
    
    var onClickDuringTransfer: (() -> Void)?
    
    /// 全局 drag 状态：由 AppDelegate 设置，show() 据此决定是否使用 orderFront
    var isDuringDrag: Bool = false
    
    override func mouseDown(with event: NSEvent) {
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
        // 外层：全透明，接受 drag
        self.wantsLayer = true
        self.registerForDraggedTypes(LocalFileDrag.acceptedTypes)
        
        // 内层视觅盒子：240x180 frosted glass
        contentBox.material = .hudWindow
        contentBox.state = .active
        contentBox.blendingMode = .behindWindow
        contentBox.wantsLayer = true
        contentBox.layer?.cornerRadius = 16
        contentBox.layer?.masksToBounds = true
        contentBox.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(contentBox)
        
        // top=0: contentBox 顶部与窗口顶部持平（视觅位置贴近 status bar）
        // 左右各 60px、底部 90px 为透明拖放容豆带（更大的缓冲区 = 更少弹回）
        NSLayoutConstraint.activate([
            contentBox.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            contentBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -90),
            contentBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 60),
            contentBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -60),
        ])
    }
    
    // 关键：hitTest 覆写
    // drag 进行中（鼠标按下）始终返回 self，防止 contentBox 子视图劫持 drag。
    // 否则 AppKit 会对 contentBox 调用 draggingExited，循环触发弹回。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSEvent.pressedMouseButtons != 0 {
            return self
        }
        return super.hitTest(point)
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
        isAcceptingDragSession = false  // drop 流程结束，释放 drag session 锁
        dragExitWorkItem?.cancel()
        dragExitWorkItem = nil
        
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

    func clearStaleDragSessionIfNeeded() {
        guard isAcceptingDragSession,
              NSEvent.pressedMouseButtons == 0,
              !isPerformingDrop else { return }
        FileLogger.log("🧯 [Drag] Clearing stale drag session flag (mouse released).")
        isAcceptingDragSession = false
        dragExitWorkItem?.cancel()
        dragExitWorkItem = nil
        if !isShowingSuccess {
            contract()
            isBorderHighlighted = false
        }
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
        let urls = LocalFileDrag.stageValidLocalFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            FileLogger.log("⛔️ [Drag] DropZoneContentView ignored non-local-file drag.")
            return []
        }
        // 取消任何待执行的「退出清除」任务
        dragExitWorkItem?.cancel()
        dragExitWorkItem = nil
        // 立刻锁定：drag 飞行中，禁止 hide()
        isAcceptingDragSession = true
        if !isShowingSuccess {
            expand()
            isBorderHighlighted = true
        }
        FileLogger.log("🎯 [Drag] draggingEntered DropZoneContentView. isAcceptingDragSession=true, isPerformingDrop=\(isPerformingDrop)")
        onDragEnter?()
        return .copy
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        LocalFileDrag.stageValidLocalFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }
    
    // 关闭系统级周期性 poll，减少 drag session 被系统提前中止的概率
    var wantsPeriodicDraggingUpdates: Bool { false }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        // 关键：延迟 600ms 才清除保护标志。
        // 日志证明用户松手时鼠标极易瞬间越界触发 exit，但 performDragOperation
        // 可能在 exit 之后的 0~300ms 内才被系统调用。
        // 600ms > 最慢的 performDragOperation 调用延迟，足够安全。
        FileLogger.log("🚪 [Drag] draggingExited DropZoneContentView. isPerformingDrop=\(isPerformingDrop), isAcceptingDragSession=\(isAcceptingDragSession). Scheduling 600ms cleanup.")
        dragExitWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 双重保险：如果 performDragOperation 已经接管（isPerformingDrop），不要清除
            if !self.isPerformingDrop {
                FileLogger.log("🚪 [Drag] 600ms cleanup: clearing isAcceptingDragSession (isPerformingDrop=false)")
                self.isAcceptingDragSession = false
                if !self.isShowingSuccess {
                    self.contract()
                    self.isBorderHighlighted = false
                }
            } else {
                FileLogger.log("🚪 [Drag] 600ms cleanup: SKIPPED (isPerformingDrop=true, drop already handled)")
            }
        }
        dragExitWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        onDragExit?()
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let finalURLs = LocalFileDrag.stagedOrCurrentLocalFileURLs(from: sender.draggingPasteboard)
        guard !finalURLs.isEmpty else {
            self.isPerformingDrop = false
            self.isAcceptingDragSession = false
            return false
        }

        // 取消退出计时，确保 drag session 期间 isAcceptingDragSession 保持 true
        dragExitWorkItem?.cancel()
        dragExitWorkItem = nil
        
        // 同步标记：立即接管，阻止任何 hide 路径
        self.isPerformingDrop = true
        // isAcceptingDragSession 保持 true，直到 drop 流程完成后由 resetFromSuccess 清除
        
        FileLogger.log("⬇️ [Drag] performDragOperation called. isPerformingDrop=true, isAcceptingDragSession=\(isAcceptingDragSession)")

        FileLogger.log("✅ [Drag] performDragOperation: \(finalURLs.count) file(s) accepted. Calling onDrop.")
        onDrop?(finalURLs)
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
    
    /// Drag session 正在飞行中，外部可查询（供 checkDragState 使用）
    var isAcceptingDragSession: Bool {
        dropView.isAcceptingDragSession
    }
    
    /// 全局拖拽状态：由 AppDelegate 在检测到 drag 时设置
    var isDuringDrag: Bool {
        get { dropView.isDuringDrag }
        set { dropView.isDuringDrag = newValue }
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
        // 窗口 360x300：比视觅内容（240x180）每边大 60px，底部 90px。
        // 外层全透明，内层 contentBox 是 240x180 frosted glass。
        // 更大的透明缓冲区 = 用户在视觅边框外松手时仍在 drag 接受区内，
        // performDragOperation 一定被调用，return true，无弹回动画。
        super.init(contentRect: NSRect(x: -9999, y: -9999, width: 360, height: 300),
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
        dropView.contentBox.addSubview(borderView)
        dropView.borderView = borderView
        
        // 2. Icon
        let iconSize: CGFloat = 80
        let iconView = NSImageView(image: NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Drop") ?? NSImage())
        iconView.symbolConfiguration = .init(pointSize: 42, weight: .semibold)
        iconView.contentTintColor = .labelColor
        iconView.wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        dropView.contentBox.addSubview(iconView)
        dropView.iconView = iconView
        
        // 3. Label
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        dropView.contentBox.addSubview(label)
        dropView.statusLabel = label
        
        // 4. Progress bar
        let progressBar = RoundedProgressView()
        progressBar.alphaValue = 0
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        dropView.contentBox.addSubview(progressBar)
        dropView.progressBar = progressBar
        
        // 5. Percentage label
        let percentLabel = NSTextField(labelWithString: "")
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alphaValue = 0
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        dropView.contentBox.addSubview(percentLabel)
        dropView.percentLabel = percentLabel
        
        // 6. Request Overlay
        let requestView = RequestOverlayView()
        requestView.alphaValue = 0
        requestView.isHidden = true
        requestView.translatesAutoresizingMaskIntoConstraints = false
        dropView.contentBox.addSubview(requestView)
        dropView.requestView = requestView
        
        // 所有视觅子视图加入 contentBox（视觅盒子），而非 dropView（透明外层）
        // 约束都相对于 contentBox，视觅效果与原先 240x180 一致。
        NSLayoutConstraint.activate([
            borderView.topAnchor.constraint(equalTo: dropView.contentBox.topAnchor, constant: 10),
            borderView.bottomAnchor.constraint(equalTo: dropView.contentBox.bottomAnchor, constant: -10),
            borderView.leadingAnchor.constraint(equalTo: dropView.contentBox.leadingAnchor, constant: 10),
            borderView.trailingAnchor.constraint(equalTo: dropView.contentBox.trailingAnchor, constant: -10),
            
            iconView.centerXAnchor.constraint(equalTo: dropView.contentBox.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: dropView.contentBox.centerYAnchor, constant: -18),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
            
            progressBar.leadingAnchor.constraint(equalTo: dropView.contentBox.leadingAnchor, constant: 35),
            progressBar.trailingAnchor.constraint(equalTo: dropView.contentBox.trailingAnchor, constant: -35),
            progressBar.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            progressBar.heightAnchor.constraint(equalToConstant: 6),
            
            percentLabel.centerXAnchor.constraint(equalTo: dropView.contentBox.centerXAnchor),
            percentLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            
            label.centerXAnchor.constraint(equalTo: dropView.contentBox.centerXAnchor),
            label.topAnchor.constraint(equalTo: percentLabel.bottomAnchor, constant: 2),
            
            // Request View 充满 contentBox
            requestView.topAnchor.constraint(equalTo: dropView.contentBox.topAnchor),
            requestView.bottomAnchor.constraint(equalTo: dropView.contentBox.bottomAnchor),
            requestView.leadingAnchor.constraint(equalTo: dropView.contentBox.leadingAnchor),
            requestView.trailingAnchor.constraint(equalTo: dropView.contentBox.trailingAnchor)
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
    
    private func resolveTargetOrigin(under statusItem: NSStatusItem) -> NSPoint? {
        if let button = statusItem.button, let window = button.window {
            let frameInWindow = button.convert(button.bounds, to: nil)
            let buttonFrame = window.convertToScreen(frameInWindow)
            let x = buttonFrame.midX - (self.frame.width / 2)
            let y = buttonFrame.minY - self.frame.height - 10
            return NSPoint(x: x, y: y)
        }
        
        FileLogger.log("⚠️ DropZoneWindow: No status item frame found. Using fallback.")
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let fallback = NSRect(x: frame.maxX - 40, y: frame.maxY - 10, width: 22, height: 22)
            let x = fallback.midX - (self.frame.width / 2)
            let y = fallback.minY - self.frame.height - 10
            return NSPoint(x: x, y: y)
        }
        
        FileLogger.log("❌ DropZoneWindow: Could not determine target frame.")
        return nil
    }
    
    /// Drag 开始时预热窗口：先完成定位和 orderFront，但保持不可见。
    /// 后续只通过 alpha 从 0 淡入，避免在拖拽飞行中做层级变更导致 draggingExited。
    func prewarmForDrag(under statusItem: NSStatusItem) {
        let isDragActive = dropView.isAcceptingDragSession || dropView.isDuringDrag
        let currentAlpha = self.alphaValue
        let isOrderedIn = self.isVisible
        FileLogger.log("🧊 DropZoneWindow.prewarmForDrag() called. Alpha: \(currentAlpha), OrderedIn: \(isOrderedIn), isDragActive: \(isDragActive)")
        
        // 若窗口已可见，保持现状（例如正在显示错误/成功），避免强制变透明。
        if isDragActive && isOrderedIn && currentAlpha > 0.5 {
            return
        }
        
        guard let targetOrigin = resolveTargetOrigin(under: statusItem) else { return }
        
        self.ignoresMouseEvents = false
        if !isDragActive || !isOrderedIn {
            if abs(self.frame.origin.x - targetOrigin.x) > 1 || abs(self.frame.origin.y - targetOrigin.y) > 1 {
                self.setFrameOrigin(targetOrigin)
            }
        }
        if !isOrderedIn {
            self.orderFront(nil)  // 不用 makeKeyAndOrderFront，避免干扰 drag session
        }
        
        // 只保留“在层级中但不可见”的预热状态。
        if self.alphaValue != 0 {
            self.alphaValue = 0
        }
    }
    
    func show(under statusItem: NSStatusItem) {
        let isDragActive = dropView.isAcceptingDragSession || dropView.isDuringDrag
        
        // ━━━ drag 飞行中保护 ━━━
        // drag 进行时，任何窗口层级变更（orderFront/makeKeyAndOrderFront/setFrameOrigin）
        // 都可能导致 AppKit 认为 drag 目标丢失，触发 draggingExited + 弹回。
        // 如果窗口已可见（alpha≈1），什么都不做。
        // 如果窗口不可见，只做最小操作：定位 + orderFront + 淡入。
        if isDragActive && self.isVisible && self.alphaValue > 0.5 {
            return  // 窗口已可见，drag 期间不干扰
        }
        
        // [LOG]
        let currentAlpha = self.alphaValue
        let isOrderedIn = self.isVisible
        FileLogger.log("✨ DropZoneWindow.show() called. Alpha: \(currentAlpha), OrderedIn: \(isOrderedIn), isDragActive: \(isDragActive)")
        
        self.ignoresMouseEvents = false
        
        if let targetOrigin = resolveTargetOrigin(under: statusItem) {
            if currentAlpha < 0.01 && !isOrderedIn {
                // 窗口完全不可见：定位 → orderFront → 淡入
                FileLogger.log("📍 Initial positioning at: \(targetOrigin.x), \(targetOrigin.y)")
                self.setFrameOrigin(targetOrigin)
                self.alphaValue = 0
                self.orderFront(nil)  // 不用 makeKeyAndOrderFront，避免干扰 drag session
            } else {
                // 窗口已可见或正在动画
                if !isDragActive {
                    // 非 drag 期间才移动位置（避免 drag 期间 setFrameOrigin 打断 session）
                    if abs(self.frame.origin.x - targetOrigin.x) > 1 || abs(self.frame.origin.y - targetOrigin.y) > 1 {
                        self.setFrameOrigin(targetOrigin)
                    }
                }
                if !isOrderedIn {
                    self.orderFront(nil)
                }
            }
        }
        
        // 淡入动画
        if self.alphaValue < 0.99 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = isDragActive ? 0.1 : 0.2
                self.animator().alphaValue = 1
            }
        }
    }
    

    func hide() {
        // 正在处理接收请求时禁止隐藏
        if dropView.isRequesting {
            FileLogger.log("🛡️ [hide] BLOCKED: isRequesting=true")
            return
        }
        // 若 drag 标志因边界抖动残留，先尝试自恢复。
        dropView.clearStaleDragSessionIfNeeded()
        // Drag session 飞行中（鼠标已进入但 performDragOperation 尚未完成）禁止隐藏
        if dropView.isAcceptingDragSession {
            FileLogger.log("🛡️ [hide] BLOCKED: isAcceptingDragSession=true")
            return
        }
        // 全局 drag 进行中：仅做 soft hide（alpha=0），不做 orderOut。
        // 这样可以在拖拽中按距离逻辑隐藏窗口，同时避免层级变更打断 drag session。
        if dropView.isDuringDrag {
            if self.alphaValue <= 0.01 {
                return
            }
            FileLogger.log("🙈 [hide] Drag active: soft hide (alpha only, keep ordered in)")
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                self.animator().alphaValue = 0
            })
            return
        }
        FileLogger.log("🙈 [hide] Hiding window. isPerformingDrop=\(dropView.isPerformingDrop), isShowingSuccess=\(dropView.isShowingSuccess)")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            self.animator().alphaValue = 0
        }) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                // 关键保护：completion 可能延迟执行，如果此时 show() 已重新显示窗口
                // （alphaValue > 0 或 isDuringDrag），则不执行 orderOut。
                // 这防止了 hide 的异步 orderOut 与 show 的 orderFront 竞争导致弹回。
                if self.alphaValue == 0 && !self.dropView.isDuringDrag {
                    self.orderOut(nil)
                    // Only reset state when NOT actively transferring
                    if !self.dropView.isPerformingDrop {
                        self.dropView.resetFromSuccess()
                    }
                } else {
                    FileLogger.log("🛡️ [hide completion] SKIPPED orderOut: alpha=\(self.alphaValue), isDuringDrag=\(self.dropView.isDuringDrag)")
                }
            }
        }
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
