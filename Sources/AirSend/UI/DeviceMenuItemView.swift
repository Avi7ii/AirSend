import Cocoa

class DeviceMenuItemView: NSView {
    enum ConnectionState {
        case idle
        case connecting
        case connected
    }
    
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let checkmarkView = NSImageView()
    private let forgetButton = NSImageView() // The "X" button
    
    var state: ConnectionState = .idle {
        didSet {
            updateUI()
        }
    }
    
    private var deviceId: String = ""
    private var canForget: Bool = false
    private let forgetButtonRect = NSRect(x: 226, y: 12, width: 16, height: 16)
    
    init(device: Device, state: ConnectionState = .idle, canForget: Bool = false) {
        self.deviceId = device.id
        self.canForget = canForget
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        setupUI(device: device)
        self.state = state
        updateUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(device: Device) {
        // Icon (Left Aligned)
        let iconName: String
        switch device.deviceType {
        case .mobile: iconName = "iphone"
        case .desktop: iconName = "desktopcomputer"
        case .tablet: iconName = "ipad"
        default: iconName = "questionmark.circle"
        }
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconView.contentTintColor = .labelColor
        iconView.frame = NSRect(x: 12, y: 10, width: 20, height: 20)
        addSubview(iconView)
        
        // Title (Millimeter-level precision centering: Block height 32/40)
        titleLabel.stringValue = device.alias
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.frame = NSRect(x: 44, y: 21, width: 170, height: 15)
        addSubview(titleLabel)
        
        // Subtitle (Increased gap to 5px, Y=4 for absolute center)
        subtitleLabel.stringValue = device.deviceModel ?? ""
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 44, y: 4, width: 170, height: 12)
        addSubview(subtitleLabel)
        
        // Forget Button (X) - Only if allowed
        if canForget {
            forgetButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Forget")
            forgetButton.contentTintColor = .secondaryLabelColor.withAlphaComponent(0.2)
            forgetButton.frame = forgetButtonRect
            addSubview(forgetButton)
        }
        
        // Spinner (Right Aligned)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: 254, y: 12, width: 16, height: 16)
        addSubview(spinner)
        
        // Checkmark (Right Aligned) - Heavy weight, no circle to ensure distinction from X
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .heavy)
        checkmarkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        checkmarkView.contentTintColor = .controlAccentColor
        checkmarkView.frame = NSRect(x: 254, y: 12, width: 16, height: 16)
        checkmarkView.isHidden = true
        addSubview(checkmarkView)
    }
    
    private func updateUI() {
        switch state {
        case .idle:
            spinner.stopAnimation(nil)
            checkmarkView.isHidden = true
            titleLabel.textColor = .labelColor
        case .connecting:
            spinner.startAnimation(nil)
            checkmarkView.isHidden = true
            titleLabel.textColor = .labelColor
        case .connected:
            spinner.stopAnimation(nil)
            checkmarkView.isHidden = false
            titleLabel.textColor = .controlAccentColor
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        if let enclosingMenuItem = self.enclosingMenuItem, enclosingMenuItem.isHighlighted {
            // MacOS style rounded selection - increased corner radius and reduced inset for "fuller" look
            let selectionRect = bounds.insetBy(dx: 2, dy: 1)
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 8, yRadius: 8)
            NSColor.selectedContentBackgroundColor.set()
            path.fill()
            
            titleLabel.textColor = .alternateSelectedControlTextColor
            subtitleLabel.textColor = .alternateSelectedControlTextColor.withAlphaComponent(0.8)
            iconView.contentTintColor = .alternateSelectedControlTextColor
            checkmarkView.contentTintColor = .alternateSelectedControlTextColor
            forgetButton.contentTintColor = .alternateSelectedControlTextColor.withAlphaComponent(0.7)
        } else {
            titleLabel.textColor = state == .connected ? .controlAccentColor : .labelColor
            subtitleLabel.textColor = .secondaryLabelColor
            iconView.contentTintColor = .labelColor
            checkmarkView.contentTintColor = .controlAccentColor
            forgetButton.contentTintColor = .secondaryLabelColor.withAlphaComponent(0.2)
        }
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // Support clicking: When the view is clicked, trigger the connection flow directly
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        // Check if click is on the Forget (X) button (only if it exists)
        if canForget && forgetButtonRect.insetBy(dx: -8, dy: -8).contains(point) {
            print("❌ View: Forget Button clicked for device [\(deviceId)]")
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.forgetDevice(id: deviceId)
            }
            return
        }
        
        // Normal behavior: Find AppDelegate to trigger logic without closing menu
        if let delegate = NSApp.delegate as? AppDelegate {
            print("🖱️ View: Manual click detected for device [\(deviceId)]")
            delegate.handleDeviceClick(id: deviceId, closeMenu: false)
        }
    }
}
