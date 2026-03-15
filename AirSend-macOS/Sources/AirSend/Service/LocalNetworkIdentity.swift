import Foundation

enum LocalNetworkIdentity {
    static func primaryHardwareAddress() -> String? {
        guard let interfaceName = primaryIPv4InterfaceName() else {
            return nil
        }
        return hardwareAddress(for: interfaceName)
    }

    private static func primaryIPv4InterfaceName() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return nil
        }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        var bestCandidate: (priority: Int, name: String)?

        while let interface = current {
            defer { current = interface.pointee.ifa_next }

            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = interface.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: interface.pointee.ifa_name)
            guard !isExcludedInterface(name), let ip = ipv4Address(from: addr), isPrivateIPv4(ip) else {
                continue
            }

            let priority = interfacePriority(name)
            if bestCandidate == nil || priority < bestCandidate!.priority {
                bestCandidate = (priority, name)
            }
        }

        return bestCandidate?.name
    }

    private static func hardwareAddress(for interfaceName: String) -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return nil
        }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }

            let name = String(cString: interface.pointee.ifa_name)
            guard name == interfaceName,
                  let addr = interface.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let link = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_dl.self).pointee as sockaddr_dl? else {
                continue
            }

            let macLength = Int(link.sdl_alen)
            guard macLength > 0 else { continue }

            let dataPointer = UnsafeRawPointer(addr)
                .advanced(by: Int(link.sdl_nlen) + MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)!)
                .assumingMemoryBound(to: UInt8.self)

            let octets = (0..<macLength).map { String(format: "%02x", dataPointer[$0]) }
            return octets.joined(separator: ":")
        }

        return nil
    }

    private static func ipv4Address(from sockaddrPointer: UnsafeMutablePointer<sockaddr>) -> String? {
        var addrCopy = sockaddrPointer.pointee
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            &addrCopy,
            socklen_t(sockaddrPointer.pointee.sa_len),
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: hostBuffer)
    }

    private static func isExcludedInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "lo0"
            || lower.hasPrefix("utun")
            || lower.hasPrefix("awdl")
            || lower.hasPrefix("llw")
            || lower.hasPrefix("bridge")
            || lower.hasPrefix("anpi")
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

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]),
              let second = Int(parts[1]) else {
            return false
        }
        return first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
    }
}
