import CryptoKit
import Foundation

final class SessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (URLSessionTask, Int64, Int64) -> Void

    private let lock = NSLock()
    private var fingerprintsByHost: [String: String]
    private var progressHandler: ProgressHandler?
    private var lastCertificateFingerprint: String?

    init(expectedFingerprint: String? = nil, host: String? = nil, onProgress: ProgressHandler? = nil) {
        if let expectedFingerprint, let host {
            self.fingerprintsByHost = [Self.normalizeHost(host): Self.normalizeFingerprint(expectedFingerprint)]
        } else {
            self.fingerprintsByHost = [:]
        }
        self.progressHandler = onProgress
        super.init()
    }

    var expectedFingerprints: [String: String] {
        get { lock.withLock { fingerprintsByHost } }
        set {
            lock.withLock {
                fingerprintsByHost = Dictionary(uniqueKeysWithValues: newValue.map {
                    (Self.normalizeHost($0.key), Self.normalizeFingerprint($0.value))
                })
            }
        }
    }

    var onProgress: ProgressHandler? {
        get { lock.withLock { progressHandler } }
        set { lock.withLock { progressHandler = newValue } }
    }

    var presentedFingerprint: String? {
        lock.withLock { lastCertificateFingerprint }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        lock.withLock { progressHandler }?(task, totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            logTransfer("❌ [SessionDelegate] \(task.taskDescription ?? "request") failed: \(error.localizedDescription)")
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge: challenge, completionHandler: completionHandler)
    }

    private func handle(
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = Self.normalizeHost(challenge.protectionSpace.host)
        let expected = lock.withLock { fingerprintsByHost[host] }
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let certificate = chain.first,
              let actual = Self.calculateFingerprint(for: certificate) else {
            logTransfer("❌ Unable to read the certificate presented by \(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        lock.withLock { lastCertificateFingerprint = actual }

        guard let expected else {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        guard actual == expected else {
            logTransfer("❌ Certificate fingerprint mismatch for \(host). Expected \(expected), received \(actual)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    private static func calculateFingerprint(for certificate: SecCertificate) -> String? {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeFingerprint(_ value: String) -> String {
        value.lowercased().filter(\.isHexDigit)
    }

    private static func normalizeHost(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
