import Cocoa

class MenuSectionHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        setupUI(title: title)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(title: String) {
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 10, y: 4, width: 260, height: 14)
        addSubview(titleLabel)
    }
}
