import Cocoa

class UpdateMenuItemView: NSView {
    private let containerView = NSView()
    private let iconContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "Check for Update")
    private let versionLabel = NSTextField(labelWithString: "v\(UpdateService.shared.currentVersion)")
    
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        // Container for card effect
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 12
        containerView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        addSubview(containerView)
        
        // Geometric Stacking Icon
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.wantsLayer = true
        containerView.addSubview(iconContainer)
        
        // Title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        containerView.addSubview(titleLabel)
        
        // Version
        versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.isEditable = false
        versionLabel.isSelectable = false
        versionLabel.isBezeled = false
        versionLabel.drawsBackground = false
        containerView.addSubview(versionLabel)
        
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            
            iconContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            iconContainer.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 38), // Slightly larger container
            iconContainer.heightAnchor.constraint(equalToConstant: 38),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor, constant: -6),
            
            versionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            versionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        drawGeometricIcon()
    }
    
    private func drawGeometricIcon() {
        let colors: [NSColor] = [
            .systemIndigo, .systemPurple, .systemPink, .systemOrange
        ]
        
        iconContainer.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        
        let count = 4
        for i in 0..<count {
            let layer = CAShapeLayer()
            let angle = CGFloat(i) * (CGFloat.pi / 4) + (CGFloat.pi / 8)
            
            let size: CGFloat = 22 // Increased from 18 to 22 as requested
            let rect = NSRect(x: -size/2, y: -size/2, width: size, height: size)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            
            layer.path = path.cgPath
            layer.fillColor = colors[i % colors.count].withAlphaComponent(0.45).cgColor // More transparent (0.6 -> 0.45)
            layer.position = CGPoint(x: 19, y: 19) // Centered for 38x38 container
            layer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            
            iconContainer.layer?.addSublayer(layer)
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }
    
    override func mouseUp(with event: NSEvent) {
        // Direct click on the card triggers update
        UpdateService.shared.checkUpdate(explicit: true)
        
        // Close menu
        if let menu = self.enclosingMenuItem?.menu {
            menu.cancelTracking()
        }
    }
}

// Extension to bridge NSBezierPath to CGPath
extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            @unknown default: break
            }
        }
        return path
    }
}