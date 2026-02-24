import Cocoa

// Menu item view that shows transfer progress inline
class TransferProgressMenuView: NSView {
    private let deviceLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let progressBar = RoundedProgressView()
    
    var progress: Double = 0 {
        didSet {
            progressBar.progress = progress
            percentLabel.stringValue = "\(Int(progress * 100))%"
        }
    }
    
    var deviceName: String = "" {
        didSet { deviceLabel.stringValue = "Sending to \(deviceName)..." }
    }
    
    var onClick: (() -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setup() {
        let height: CGFloat = 52
        self.frame.size.height = height
        
        // Device label
        deviceLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        deviceLabel.textColor = .labelColor
        deviceLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deviceLabel)
        
        // Percent label
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percentLabel)
        
        // Progress bar
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)
        
        NSLayoutConstraint.activate([
            deviceLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            deviceLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            deviceLabel.trailingAnchor.constraint(lessThanOrEqualTo: percentLabel.leadingAnchor, constant: -6),
            
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percentLabel.centerYAnchor.constraint(equalTo: deviceLabel.centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 36),
            
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressBar.topAnchor.constraint(equalTo: deviceLabel.bottomAnchor, constant: 6),
            progressBar.heightAnchor.constraint(equalToConstant: 5),
        ])
    }
    
    // Hover highlight
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isMouseInside {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
    }
    
    private var isMouseInside = false
    private var trackingArea: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }
    
    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        needsDisplay = true
    }
    
    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        onClick?()
    }
}
