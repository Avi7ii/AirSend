import AirSendRuntimeCore
import Cocoa

@MainActor
final class RuntimeTransferMenuItemView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressView = RoundedProgressView()
    private let cancelButton = NSButton()
    private let transferID: UUID
    private let onCancel: (UUID) -> Void

    init(record: TransferRecord, onCancel: @escaping (UUID) -> Void) {
        self.transferID = record.id
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 64))
        setupUI()
        update(record: record)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(record: TransferRecord) {
        let direction = record.direction == .incoming ? "From" : "To"
        let fileTitle = record.files.count == 1 ? record.files[0].name : "\(record.files.count) items"
        titleLabel.stringValue = fileTitle
        detailLabel.stringValue = "\(direction) \(record.peer.alias)"
        progressView.progress = record.progress
        progressLabel.stringValue = "\(Int((record.progress * 100).rounded()))%"
        cancelButton.isHidden = record.status.isTerminal
        cancelButton.isEnabled = !record.status.isTerminal

        let symbol = record.direction == .incoming ? "arrow.down" : "arrow.up"
        iconView.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: record.direction == .incoming ? "Receiving" : "Sending"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        iconView.contentTintColor = record.direction == .incoming ? .systemGreen : .controlAccentColor
    }

    private func setupUI() {
        iconView.frame = NSRect(x: 14, y: 29, width: 20, height: 20)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.frame = NSRect(x: 43, y: 38, width: 130, height: 16)
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 43, y: 21, width: 145, height: 14)
        addSubview(detailLabel)

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .right
        progressLabel.frame = NSRect(x: 174, y: 39, width: 34, height: 14)
        addSubview(progressLabel)

        progressView.frame = NSRect(x: 43, y: 10, width: 165, height: 4)
        addSubview(progressView)

        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel transfer")
        cancelButton.imagePosition = .imageOnly
        cancelButton.isBordered = false
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.frame = NSRect(x: 212, y: 27, width: 20, height: 20)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTransfer)
        cancelButton.toolTip = "Cancel transfer"
        addSubview(cancelButton)
    }

    @objc private func cancelTransfer() {
        onCancel(transferID)
    }
}
