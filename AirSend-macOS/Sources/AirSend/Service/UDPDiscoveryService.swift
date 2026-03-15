import Foundation
import Network

final class UDPDiscoveryService: @unchecked Sendable {
    private var group: NWConnectionGroup?
    private let multicastGroupAddress = "224.0.0.167"
    private let discoveryPort = NWEndpoint.Port(rawValue: NetworkPorts.discoveryPort)!
    
    var onDeviceFound: ((Device) -> Void)?
    var onTransportFailure: ((String) -> Void)?
    var onCampusFallbackPacket: ((Data, String) -> Void)?
    
    private let fingerprint: String
    private let alias = Host.current().localizedName ?? "AirSend"
    private let deviceModel = "macOS"
    private let deviceType = DeviceType.desktop
    let protocolType: ProtocolType
    private var macAddress: String? { LocalNetworkIdentity.primaryHardwareAddress() }
    
    init(fingerprint: String, protocolType: ProtocolType = .https) {
        self.fingerprint = fingerprint
        self.protocolType = protocolType
    }
    
    private var broadcastConnection: NWConnection?
    private var broadcastListener: NWListener? // Extra listener for raw broadcast
    private var lastFailureReportAt: Date = .distantPast
    private let failureReportCooldown: TimeInterval = 1.0
    private let subnetProbeQueue = DispatchQueue(label: "com.airsend.discovery.subnet-probe", qos: .utility)
    private let subnetProbeStateQueue = DispatchQueue(label: "com.airsend.discovery.subnet-probe-state")
    private var isSubnetProbeRunning = false
    private lazy var discoverySession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.2
        config.timeoutIntervalForResource = 1.2
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: SessionDelegate(), delegateQueue: nil)
    }()
    
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
        let multicastEndpoint = NWEndpoint.hostPort(host: multicastHost, port: discoveryPort)
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        FileLogger.log("📡 Discovery using system-selected network path")
        
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
                 self?.startSubnetProbe(reason: "multicast-ready")
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
        // Do not pin discovery to a stale interface. Let the kernel pick the active path.
        let host = NWEndpoint.Host("255.255.255.255")
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        // Avoid binding a local endpoint here so it can coexist with the multicast group socket.
        let connection = NWConnection(host: host, port: discoveryPort, using: parameters)
        
        connection.stateUpdateHandler = { newState in
            switch newState {
            case .failed(let error):
                FileLogger.log("❌ Broadcast connection failed: \(error)")
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
            version: "3.0.0",
            deviceModel: deviceModel,
            deviceType: deviceType.rawValue,
            fingerprint: fingerprint,
            macAddress: macAddress,
            port: Int(NetworkPorts.transferPort),
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

    func sendCampusPacket(_ data: Data) {
        group?.send(content: data) { _ in }
        broadcastConnection?.send(content: data, completion: .contentProcessed({ _ in }))
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
        startSubnetProbe(reason: "manual-scan")
    }
    
    private func handleMessage(content: Data, source: NWEndpoint) {
        let resolvedIP = normalizedRemoteIP(from: source)

        if CampusFallbackCoordinator.looksLikeCampusPacket(content) {
            onCampusFallbackPacket?(content, resolvedIP)
            return
        }

        do {
            let dto = try JSONDecoder().decode(MulticastDto.decode, from: content)
            
            // Ignore own messages
            if dto.fingerprint == self.fingerprint {
                return
            }
            
            // Extract IP
            let ip = resolvedIP

            let device = Device(
                id: dto.fingerprint,
                alias: dto.alias,
                ip: ip,
                port: dto.port ?? Int(NetworkPorts.transferPort),
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

    private func normalizedRemoteIP(from source: NWEndpoint) -> String {
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

        if let firstPart = ip.split(separator: "%").first {
            ip = String(firstPart)
        }
        if ip.hasPrefix("::ffff:") {
            ip = String(ip.dropFirst(7))
        }
        if let activeRange = ip.range(of: "%") {
            ip = String(ip[..<activeRange.lowerBound])
        }
        return ip
    }

    private func startSubnetProbe(reason: String) {
        let shouldStart = subnetProbeStateQueue.sync { () -> Bool in
            guard !isSubnetProbeRunning else { return false }
            isSubnetProbeRunning = true
            return true
        }
        guard shouldStart else { return }

        subnetProbeQueue.async { [weak self] in
            guard let self = self else { return }
            Task {
                defer {
                    self.subnetProbeStateQueue.sync {
                        self.isSubnetProbeRunning = false
                    }
                }
                await self.probeCurrentSubnet(reason: reason)
            }
        }
    }

    private func probeCurrentSubnet(reason: String) async {
        let candidates = subnetProbeCandidates()
        guard !candidates.isEmpty else { return }

        FileLogger.log("🔎 Discovery: Subnet probe [\(reason)] scanning \(candidates.count) host(s)")

        await withTaskGroup(of: Void.self) { group in
            for host in candidates {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    await self.probeHost(host)
                }
            }
        }
    }

    private func probeHost(_ host: String) async {
        let registerDto = RegisterDto(
            alias: alias,
            version: "3.0.0",
            deviceModel: deviceModel,
            deviceType: deviceType.rawValue,
            fingerprint: fingerprint,
            macAddress: macAddress,
            port: Int(NetworkPorts.transferPort),
            protocolType: protocolType.rawValue,
            download: true
        )

        for candidatePort in candidateProbePorts() {
            guard let url = URL(string: "\(protocolType.rawValue)://\(host):\(candidatePort)/api/localsend/v2/register") else {
                continue
            }

            do {
                var request = URLRequest(url: url, timeoutInterval: 1.2)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(registerDto)

                let (data, response) = try await discoverySession.data(for: request)
                guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    continue
                }

                let dto = try JSONDecoder().decode(RegisterDto.self, from: data)
                let device = Device(
                    id: dto.fingerprint,
                    alias: dto.alias,
                    ip: host,
                    port: dto.port ?? candidatePort,
                    deviceModel: dto.deviceModel,
                    deviceType: dto.deviceType,
                    version: dto.version ?? "3.0.0",
                    https: dto.protocolType == ProtocolType.https.rawValue,
                    download: dto.download ?? false,
                    lastSeen: Date()
                )
                FileLogger.log("✅ Discovery: HTTP subnet probe found [\(device.alias)] at \(device.ip):\(device.port)")
                onDeviceFound?(device)
                return
            } catch {
                // Keep subnet probing quiet; UDP remains the primary discovery mechanism.
            }
        }
    }

    private func candidateProbePorts() -> [Int] {
        var ports: [Int] = []
        for port in [Int(NetworkPorts.transferPort), 53319, Int(NetworkPorts.discoveryPort)] where !ports.contains(port) {
            ports.append(port)
        }
        return ports
    }

    private func subnetProbeCandidates() -> [String] {
        let subnets = currentPrivateIPv4Subnets()
        guard !subnets.isEmpty else { return [] }

        var candidates = Set<String>()
        for subnet in subnets {
            for host in subnet.hosts {
                if host != subnet.address {
                    candidates.insert(host)
                }
            }
        }
        return candidates.sorted()
    }

    private func currentPrivateIPv4Subnets() -> [IPv4Subnet] {
        var results: [IPv4Subnet] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }

            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = interface.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = interface.pointee.ifa_netmask,
                  mask.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: interface.pointee.ifa_name)
            guard !isExcludedProbeInterface(name) else { continue }

            var addrCopy = addr.pointee
            var maskCopy = mask.pointee
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var maskBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            let addrResult = getnameinfo(
                &addrCopy,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            let maskResult = getnameinfo(
                &maskCopy,
                socklen_t(mask.pointee.sa_len),
                &maskBuffer,
                socklen_t(maskBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard addrResult == 0, maskResult == 0 else { continue }

            let ip = String(
                decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            let netmask = String(
                decoding: maskBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard let subnet = IPv4Subnet(address: ip, netmask: netmask), subnet.isPrivate else {
                continue
            }
            results.append(subnet)
        }

        return results
    }

    private func isExcludedProbeInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "lo0"
            || lower.hasPrefix("utun")
            || lower.hasPrefix("awdl")
            || lower.hasPrefix("llw")
            || lower.hasPrefix("bridge")
            || lower.hasPrefix("anpi")
    }
}

// Helper to decode MulticastDto correctly since we have custom keys
extension MulticastDto {
     static var decode: MulticastDto.Type {
         return MulticastDto.self
     }
}

private struct IPv4Subnet {
    let address: String
    let hosts: [String]
    let isPrivate: Bool

    init?(address: String, netmask: String) {
        guard let addressValue = Self.parse(address),
              let netmaskValue = Self.parse(netmask) else {
            return nil
        }

        self.address = address
        self.isPrivate = Self.isPrivate(addressValue)

        let hostMask = ~netmaskValue
        let hostCount = Int(hostMask)
        let baseNetwork = addressValue & netmaskValue

        if hostCount <= 1 {
            self.hosts = []
            return
        }

        if hostCount > 254 {
            let octets = Self.octets(addressValue)
            self.hosts = (1...254).map { "\(octets.0).\(octets.1).\(octets.2).\($0)" }
            return
        }

        var generated: [String] = []
        generated.reserveCapacity(max(0, hostCount - 1))
        for offset in 1..<hostCount {
            generated.append(Self.string(baseNetwork + UInt32(offset)))
        }
        self.hosts = generated
    }

    private static func parse(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        return value
    }

    private static func octets(_ value: UInt32) -> (UInt32, UInt32, UInt32, UInt32) {
        (
            (value >> 24) & 0xff,
            (value >> 16) & 0xff,
            (value >> 8) & 0xff,
            value & 0xff
        )
    }

    private static func string(_ value: UInt32) -> String {
        let octets = octets(value)
        return "\(octets.0).\(octets.1).\(octets.2).\(octets.3)"
    }

    private static func isPrivate(_ value: UInt32) -> Bool {
        let first = (value >> 24) & 0xff
        let second = (value >> 16) & 0xff
        return first == 10 || (first == 172 && (16...31).contains(Int(second))) || (first == 192 && second == 168)
    }
}
