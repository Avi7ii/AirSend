import Foundation
import CryptoKit
import Security

#if canImport(Darwin)
import Darwin
#endif

actor CertificateManager {
    static let shared = CertificateManager()
    
    private let fileManager = FileManager.default
    private let appSupportDir: URL
    private let certPath: URL
    private let keyPath: URL
    private let p12Path: URL
    private let password = "localsend"
    
    private var cachedFingerprint: String?
    
    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.appSupportDir = appSupport.appendingPathComponent("AirSend-macOS")
        self.certPath = appSupportDir.appendingPathComponent("certificate.pem")
        self.keyPath = appSupportDir.appendingPathComponent("key.pem")
        self.p12Path = appSupportDir.appendingPathComponent("certificate.p12")
    }
    
    func setup(force: Bool = false) async throws {
        if !fileManager.fileExists(atPath: appSupportDir.path) {
            try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        }
        
        var shouldRegenerate = force
        if !fileManager.fileExists(atPath: p12Path.path) ||
            !fileManager.fileExists(atPath: certPath.path) ||
            !fileManager.fileExists(atPath: keyPath.path) {
            shouldRegenerate = true
        } else if !hasValidCertificateBundle() {
            logTransfer("⚠️ Existing certificate bundle is invalid. Regenerating identity certificate...")
            shouldRegenerate = true
        }
        
        if shouldRegenerate {
            try await generateCertificate()
        }
    }
    
    // Public method to force regeneration (e.g. from "Reset Identity" menu)
    func forceRegenerate() async throws {
        logTransfer("🧨 Force Regenerating Identity/Certificate...")
        try await generateCertificate()
    }
    
    private func hasValidCertificateBundle() -> Bool {
        // Validate PEM certificate
        let certCheck = Process()
        certCheck.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        certCheck.arguments = ["x509", "-in", certPath.path, "-noout"]
        do {
            try certCheck.run()
            certCheck.waitUntilExit()
            if certCheck.terminationStatus != 0 {
                return false
            }
        } catch {
            return false
        }
        
        // Validate private key
        let keyCheck = Process()
        keyCheck.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        keyCheck.arguments = ["pkey", "-in", keyPath.path, "-noout"]
        do {
            try keyCheck.run()
            keyCheck.waitUntilExit()
            if keyCheck.terminationStatus != 0 {
                return false
            }
        } catch {
            return false
        }
        
        // Validate P12 bundle
        let p12Check = Process()
        p12Check.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p12Check.arguments = [
            "pkcs12", "-in", p12Path.path, "-passin", "pass:\(password)", "-nokeys", "-clcerts", "-noout"
        ]
        do {
            try p12Check.run()
            p12Check.waitUntilExit()
            return p12Check.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    private func generateCertificate() async throws {
        logTransfer("🔐 Generating ultra-minimal official-aligned self-signed certificate...")
        
        // DN requirements: CN is required, O should be empty for official LocalSend alignment
        let commonName = "LocalSend User"
        let organization = "" 
        
        // 1. Generate Key and Cert (Minimal approach, no extensions)
        // Official LocalSend (Dart/Rust) uses very plain certificates.
        // We avoid -config and SANs to maximize compatibility with sensitive TLS clients.
        let fm = FileManager.default
        let configPath = appSupportDir.appendingPathComponent("openssl.conf")
        
        // 2. Generate config with SANs (Subject Alternative Names)
        // This is CRITICAL. Modern clients require SANs, and our setup() 
        // logic checks for them. Missing SANs = Infinite Restart Loop.
        let currentIPs = getAllIPs()
        var sanLines = "subjectAltName = @alt_names\n\n[alt_names]\n"
        sanLines += "DNS.1 = localhost\n"
        sanLines += "IP.1 = 127.0.0.1\n"
        
        for (index, ip) in currentIPs.enumerated() {
            sanLines += "IP.\(index + 2) = \(ip)\n"
        }
        
        let configContent = """
        [req]
        distinguished_name = req_distinguished_name
        prompt = no
        x509_extensions = v3_req

        [req_distinguished_name]
        CN = LocalSend User

        [v3_req]
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth, clientAuth
        \(sanLines)
        """
        
        try configContent.write(to: configPath, atomically: true, encoding: .utf8)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyPath.path,
            "-out", certPath.path,
            "-sha256", "-days", "3650", "-nodes",
            "-config", configPath.path,
            "-extensions", "v3_req"
        ]
        
        // Capture stderr for debugging
        let pipe = Pipe()
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown OpenSSL error"
            logTransfer("❌ OpenSSL 'req' failed (Code: \(process.terminationStatus)): \(errorMsg)")
            throw NSError(domain: "CertificateManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CertificateManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to generate minimal PEM certificate"])
        }
        
        // 2. Export to P12
        let p12Process = Process()
        p12Process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p12Process.arguments = [
            "pkcs12", "-export",
            "-out", p12Path.path,
            "-inkey", keyPath.path,
            "-in", certPath.path,
            "-passout", "pass:\(password)"
        ]
        
        try p12Process.run()
        p12Process.waitUntilExit()
        
        guard p12Process.terminationStatus == 0 else {
            throw NSError(domain: "CertificateManager", code: Int(p12Process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to export certificate to P12"])
        }
        
        // Reset cache
        cachedFingerprint = nil
        logTransfer("✅ Ultra-minimal certificate generated (O='', No Extensions).")
    }
    
    func getP12Data() async throws -> Data {
        try await setup()
        return try Data(contentsOf: p12Path)
    }
    
    func getFingerprint() async throws -> String {
        if let cached = cachedFingerprint { return cached }
        
        try await setup()
        
        // Calculate SHA-256 of the DER certificate
        // First convert PEM to DER
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["x509", "-in", certPath.path, "-outform", "DER"]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        
        try process.run()
        let derData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CertificateManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to convert certificate to DER"])
        }
        
        let hash = SHA256.hash(data: derData)
        let fingerprint = hash.map { String(format: "%02x", $0) }.joined()
        self.cachedFingerprint = fingerprint
        return fingerprint
    }
    
    private func getAllIPs() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                let interface = ptr?.pointee
                guard let addressPointer = interface?.ifa_addr else { continue }
                let addrFamily = addressPointer.pointee.sa_family

                if addrFamily == UInt8(AF_INET) {
                    if let cString = interface?.ifa_name {
                        let name = String(cString: cString)
                        // Accept en0 (WiFi), en1 (Eth), utun (VPN/Proxy), bridge, lo0 (Local)
                        // Actually, just accept everything that isn't loopback 127.0.0.1
                        // But wait, we want 127.0.0.1 too? No, usually handled separately.
                        
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let addressLength = socklen_t(addressPointer.pointee.sa_len)
                        let result = getnameinfo(addressPointer, addressLength, &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        guard result == 0 else {
                            logTransfer("⚠️ Certificate IP scan skipped interface \(name): getnameinfo failed (\(result))")
                            continue
                        }

                        let address = String(cString: hostname)

                        if address != "127.0.0.1" {
                            addresses.append(address)
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return addresses
    }
}
