import Foundation
import Network

final class UDPDiscoveryService: @unchecked Sendable {
    private struct DiscoveryBinding {
        let interfaceName: String
        let ipAddress: String
        let nwInterface: NWInterface
    }

    private var group: NWConnectionGroup?
    private let multicastGroupAddress = "224.0.0.167"
    private let port: NWEndpoint.Port = 53317
    
    var onDeviceFound: ((Device) -> Void)?
    var onTransportFailure: ((String) -> Void)?
    
    private let fingerprint: String
    private let alias = Host.current().localizedName ?? "AirSend"
    private let deviceModel = "macOS"
    private let deviceType = DeviceType.desktop
    let protocolType: ProtocolType
    
    init(fingerprint: String, protocolType: ProtocolType = .https) {
        self.fingerprint = fingerprint
        self.protocolType = protocolType
    }
    
    private var broadcastConnection: NWConnection?
    private var broadcastListener: NWListener? // Extra listener for raw broadcast
    private var lastFailureReportAt: Date = .distantPast
    private let failureReportCooldown: TimeInterval = 1.0
    private lazy var discoveryBinding: DiscoveryBinding? = Self.resolveDiscoveryBinding()
    
    private func reportTransportFailure(_ reason: String) {
        let now = Date()
        if now.timeIntervalSince(lastFailureReportAt) < failureReportCooldown {
            return
        }
        lastFailureReportAt = now
        onTransportFailure?(reason)
    }
    
    func start() {
        let multicastHost = NWEndpoint.Host(multicastGroupAddress)
        let multicastPort = NWEndpoint.Port(integerLiteral: 53317)
        let multicastEndpoint = NWEndpoint.hostPort(host: multicastHost, port: multicastPort)
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        if let binding = discoveryBinding {
            parameters.requiredInterface = binding.nwInterface
            FileLogger.log("📡 Discovery bound to \(binding.interfaceName) (\(binding.ipAddress))")
        } else {
            FileLogger.log("⚠️ Discovery interface auto-selection failed; using system default")
        }
        
        // Define the multicast group
        guard let groupDescriptor = try? NWMulticastGroup(for: [multicastEndpoint]) else {
            print("Failed to create multicast group descriptor")
            return
        }
        
        let group = NWConnectionGroup(with: groupDescriptor, using: parameters)
        
        group.setReceiveHandler(maximumMessageSize: 16384, rejectOversizedMessages: true) { [weak self] (message, content, isComplete) in
            if let content = content, let source = message.remoteEndpoint {
                // FileLogger.log("📩 Received multicast packet (\(content.count) bytes) from \(source)")
                self?.handleMessage(content: content, source: source)
            }
        }
        
        group.stateUpdateHandler = { [weak self] (newState: NWConnectionGroup.State) in
            FileLogger.log("📡 Multicast group state changed: \(newState)")
            switch newState {
            case .ready:
                 FileLogger.log("✅ UDP Discovery (Multicast) Ready")
                 self?.sendAnnouncement() 
            case .failed(let error):
                FileLogger.log("❌ UDP Discovery (Multicast) Failed: \(error)")
                self?.reportTransportFailure("multicast failed: \(error)")
            default:
                break
            }
        }
        
        group.start(queue: DispatchQueue.global())
        self.group = group
        
        // Setup Broadcast infrastructure
        setupBroadcast()
        setupBroadcastListener()
    }
    
    private func setupBroadcastListener() {
        // We already have NWConnectionGroup handling multicast and broadcast on the same port.
        // Adding a second NWListener on the same port often causes "Address already in use" 
        // even with reuse enabled on macOS.
        FileLogger.log("📡 Discovery: Using NWConnectionGroup for all incoming UDP traffic.")
    }
    
    private func setupBroadcast() {
        let host = NWEndpoint.Host("255.255.255.255")
        let port = NWEndpoint.Port(integerLiteral: 53317)
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        if let binding = discoveryBinding {
            parameters.requiredInterface = binding.nwInterface
        }
        
        let connection = NWConnection(host: host, port: port, using: parameters)
        
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed(let error):
                FileLogger.log("❌ Broadcast connection failed: \(error)")
                self?.reportTransportFailure("broadcast failed: \(error)")
            case .waiting(let error):
                FileLogger.log("⚠️ Broadcast connection waiting: \(error)")
            default:
                break
            }
        }
        connection.start(queue: .global())
        self.broadcastConnection = connection
    }
    
    func stop() {
        group?.cancel()
        group = nil
        broadcastConnection?.cancel()
        broadcastConnection = nil
        broadcastListener?.cancel()
        broadcastListener = nil
    }
    
    func sendAnnouncement(isAnnouncement: Bool = true) {
        let dto = MulticastDto(
            alias: alias,
            version: "2.4.2",
            deviceModel: deviceModel,
            deviceType: deviceType.rawValue,
            fingerprint: fingerprint,
            port: 53317,
            protocolType: protocolType,
            download: true,
            announcement: isAnnouncement,
            announce: isAnnouncement
        )
        
        do {
            let data = try JSONEncoder().encode(dto)
            
            // Send Multicast
            group?.send(content: data) { _ in }
            
            // Send Broadcast
            broadcastConnection?.send(content: data, completion: .contentProcessed({ _ in }))
            
        } catch {
            print("Failed to encode announcement: \(error)")
        }
    }
    
    // Explicit Scan for external triggers
    func triggerScan() {
        FileLogger.log("📡 Triggering manual discovery scan (Step Burst)...")
        // Official LocalSend pattern: [100ms, 500ms, 2000ms]
        let intervals = [0.1, 0.5, 2.0]
        for delay in intervals {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self.sendAnnouncement()
            }
        }
    }
    
    private func handleMessage(content: Data, source: NWEndpoint) {
        do {
            let dto = try JSONDecoder().decode(MulticastDto.decode, from: content)
            
            // Ignore own messages
            if dto.fingerprint == self.fingerprint {
                return
            }
            
            // Extract IP
            var ip = "unknown"
            if case let .hostPort(host, _) = source {
                switch host {
                case .ipv4(let ipv4):
                    ip = "\(ipv4)"
                case .ipv6(let ipv6):
                    ip = "\(ipv6)"
                default:
                     break
                }
            }
            
            // Normalize IP (strip %interface and ::ffff: prefix)
            if let firstPart = ip.split(separator: "%").first {
                ip = String(firstPart)
            }
            if ip.hasPrefix("::ffff:") {
                ip = String(ip.dropFirst(7))
            }
            
            // De-duplicate: If IP is own IP, skip
            // (Optional, fingerprint check usually covers this)
            
            // Dictionary of ::ffff: mapped IPv4
            if ip.hasPrefix("::ffff:") {
                ip = String(ip.dropFirst(7))
            }
            
            // On macOS NWEndpoint.Host(ipv4) debugDescription/description is usually correct.
            // But let's clean it just in case if it has %interface
            if let activeRange = ip.range(of: "%") {
                ip = String(ip[..<activeRange.lowerBound])
            }

            let device = Device(
                id: dto.fingerprint,
                alias: dto.alias,
                ip: ip,
                port: dto.port ?? 53317,
                deviceModel: dto.deviceModel,
                deviceType: dto.deviceType, // 这里的 dto.deviceType 已经是 String? 了，但是 Device 构造需要 String?。
                version: dto.version,
                https: dto.protocolType == .https,
                download: dto.download ?? false,
                lastSeen: Date()
            )
            
            // 🔋 日志已移至 main.swift onDeviceFound 回调中（仅新设备）
            onDeviceFound?(device)
            
            // ACTIVE RESPONSE: If this is an announcement, respond immediately so they see us too
            if dto.announcement == true || dto.announce == true {
                FileLogger.log("📡 Discovery: Responding to announcement from [\(device.alias)]")
                self.sendAnnouncement(isAnnouncement: false)
            }
            
        } catch {
            let contentString = String(data: content, encoding: .utf8) ?? "binary data"
            FileLogger.log("❌ Discovery: Failed to decode UDP message from \(source). Error: \(error). Content: \(contentString)")
        }
    }

    private static func resolveDiscoveryBinding() -> DiscoveryBinding? {
        guard let preferred = preferredIPv4Interface() else {
            return nil
        }

        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "AirSend.UDPDiscovery.Path")
        let semaphore = DispatchSemaphore(value: 0)

        monitor.pathUpdateHandler = { path in
            semaphore.signal()
        }
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 1)
        let interfaces = monitor.currentPath.availableInterfaces
        monitor.cancel()

        guard let nwInterface =
            interfaces.first(where: { $0.name == preferred.name }) ??
            interfaces.first(where: { $0.type == .wifi }) ??
            interfaces.first(where: { $0.type == .wiredEthernet })
        else {
            return nil
        }

        return DiscoveryBinding(
            interfaceName: preferred.name,
            ipAddress: preferred.address,
            nwInterface: nwInterface
        )
    }

    private static func preferredIPv4Interface() -> (name: String, address: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var best: (priority: Int, name: String, address: String)?
        var ptr = ifaddr

        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard
                let interface = ptr?.pointee,
                let addr = interface.ifa_addr,
                addr.pointee.sa_family == UInt8(AF_INET),
                let cString = interface.ifa_name
            else {
                continue
            }

            let name = String(cString: cString)
            if shouldSkipInterface(name) {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                socklen_t(0),
                NI_NUMERICHOST
            )
            let address = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard isPrivateLANIPv4(address) else {
                continue
            }

            let priority = interfacePriority(name)
            if best == nil || priority < best!.priority {
                best = (priority, name, address)
            }
        }

        return best.map { ($0.name, $0.address) }
    }

    private static func shouldSkipInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("lo")
            || lower.hasPrefix("utun")
            || lower.hasPrefix("awdl")
            || lower.hasPrefix("llw")
            || lower.hasPrefix("bridge")
    }

    private static func interfacePriority(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower == "en0" {
            return 0
        }
        if lower.hasPrefix("en") {
            return 10
        }
        if lower.hasPrefix("bridge") {
            return 20
        }
        return 30
    }

    private static func isPrivateLANIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }

        switch (octets[0], octets[1]) {
        case (10, _):
            return true
        case (172, 16...31):
            return true
        case (192, 168):
            return true
        default:
            return false
        }
    }
}

// Helper to decode MulticastDto correctly since we have custom keys
extension MulticastDto {
     static var decode: MulticastDto.Type {
         return MulticastDto.self
     }
}
