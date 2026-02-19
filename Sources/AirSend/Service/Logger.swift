import Foundation

@Sendable
func logTransfer(_ message: String) {
    FileLogger.log(message)
}

struct FileLogger {
    private static let logQueue = DispatchQueue(label: "com.airsend.logger", qos: .background)
    static func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"
        print(logMessage)
        
        logQueue.async {
            let fm = FileManager.default
            let logURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("AirSend.log")
            
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil, attributes: nil)
            }
            
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                if let data = logMessage.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        }
    }
}
