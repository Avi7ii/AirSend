import AirSendRuntimeCore
import Foundation

actor ClipboardSender {
    private let fileSender: FileSender

    init(fileSender: FileSender) {
        self.fileSender = fileSender
    }

    @discardableResult
    func sendText(_ text: String, to device: Device) async throws -> UUID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try await fileSender.sendData(
            Data(text.utf8),
            fileName: "clipboard.txt",
            mimeType: "text/plain",
            previewText: text,
            source: .clipboard,
            to: device
        )
    }

    @discardableResult
    func sendImage(_ imageData: Data, to device: Device) async throws -> UUID {
        try await fileSender.sendData(
            imageData,
            fileName: "Mac_Clipboard_\(Int(Date().timeIntervalSince1970)).png",
            mimeType: "image/png",
            previewText: nil,
            source: .clipboardImage,
            to: device
        )
    }
}
