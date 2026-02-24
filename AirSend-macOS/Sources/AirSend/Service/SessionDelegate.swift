import Foundation
import CryptoKit

final class SessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var onProgress: ((URLSessionTask, Int64, Int64) -> Void)?
    var expectedFingerprints: [String: String] = [:] // host -> fingerprint
    
    // Calculate SHA-256 as required by LocalSend protocol
    private func calculateFingerprint(for certificate: SecCertificate) -> String? {
        guard let derData = SecCertificateCopyData(certificate) as Data? else { return nil }
        let hash = SHA256.hash(data: derData)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress?(task, totalBytesSent, totalBytesExpectedToSend)
        onProgress?(task, totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            logTransfer("❌ [SessionDelegate] Task \(task.taskDescription ?? "") finished with error: \(error.localizedDescription) (Code: \((error as NSError).code))")
        } else {
            logTransfer("✅ [SessionDelegate] Task \(task.taskDescription ?? "") finished successfully.")
        }
    }
    
    // For session-level challenges
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        logTransfer("🔐 Session challenge: \(challenge.protectionSpace.authenticationMethod)")
        handle(challenge: challenge, completionHandler: completionHandler)
    }
    
    // For task-level challenges
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        logTransfer("🔐 Task challenge for \(task.taskDescription ?? "unknown"): \(challenge.protectionSpace.authenticationMethod)")
        handle(challenge: challenge, completionHandler: completionHandler)
    }
    
    private func handle(challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            
            let host = challenge.protectionSpace.host
            
            // LocalSend Protocol: Verify fingerprint if known
            if let expectedFingerprint = expectedFingerprints[host] {
                // Robust Certificate Extraction
                var leafCert: SecCertificate?
                if let certs = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate], !certs.isEmpty {
                    leafCert = certs.first
                } else {
                    // Fallback to older API or index 0 if chain copy fails
                    leafCert = SecTrustGetCertificateAtIndex(serverTrust, 0)
                }

                if let cert = leafCert, let actualFingerprint = calculateFingerprint(for: cert) {
                    if actualFingerprint.lowercased() == expectedFingerprint.lowercased() {
                        logTransfer("✅ Fingerprint verified for \(host)")
                        completionHandler(.useCredential, URLCredential(trust: serverTrust))
                        return
                    } else {
                        logTransfer("❌ Fingerprint mismatch for \(host)! Expected: \(expectedFingerprint), Actual: \(actualFingerprint). Rejecting security risk.")
                        // Strict security: Reject if we EXPECTED a fingerprint but got a different one.
                        // This prevents MITM. If connection fails here, it's a legit security block.
                        completionHandler(.cancelAuthenticationChallenge, nil)
                        return
                    }
                }
                logTransfer("⚠️ Could not extract certificate/fingerprint from \(host). Allowing connection (Soft Fail).")
            } else {
                logTransfer("🙌 Trusting \(host) (No expected fingerprint found)...")
            }
            
            // Default: Trust
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            logTransfer("🤷 Default handling for \(challenge.protectionSpace.authenticationMethod)")
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
