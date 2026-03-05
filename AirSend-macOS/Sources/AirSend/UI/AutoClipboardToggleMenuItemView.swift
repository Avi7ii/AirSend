import Cocoa

class AutoClipboardToggleMenuItemView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let toggleSwitch = NSSwitch()
    private let onToggle: (Bool) -> Void

    init(title: String, isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        setupUI(title: title, isOn: isOn)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(title: String, isOn: Bool) {
        wantsLayer = true

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        // Match default NSMenuItem text indent.
        titleLabel.frame = NSRect(x: 21, y: 6, width: 143, height: 16)
        addSubview(titleLabel)

        toggleSwitch.controlSize = .mini
        toggleSwitch.state = isOn ? .on : .off
        toggleSwitch.frame = NSRect(x: 190, y: 5, width: 30, height: 18)
        toggleSwitch.target = self
        toggleSwitch.action = #selector(switchChanged(_:))
        addSubview(toggleSwitch)
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        onToggle(sender.state == .on)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !toggleSwitch.frame.contains(point) else {
            return
        }

        toggleSwitch.state = (toggleSwitch.state == .on) ? .off : .on
        onToggle(toggleSwitch.state == .on)
    }
}
