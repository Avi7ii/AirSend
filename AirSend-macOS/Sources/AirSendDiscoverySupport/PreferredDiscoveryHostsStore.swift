import Foundation

/// A small, lock-protected value boundary between the main-actor app state and
/// background discovery work. Readers always receive one complete immutable
/// snapshot; they never execute a callback into UI-owned state.
public final class PreferredDiscoveryHostsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String]

    public init(initialHosts: [String] = []) {
        hosts = Self.normalized(initialHosts)
    }

    public func replace(with newHosts: [String]) {
        let replacement = Self.normalized(newHosts)
        lock.lock()
        hosts = replacement
        lock.unlock()
    }

    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    private static func normalized(_ rawHosts: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for rawHost in rawHosts {
            let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, seen.insert(host).inserted else { continue }
            result.append(host)
        }
        return result
    }
}
