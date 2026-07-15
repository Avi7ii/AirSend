import Foundation

public let airSendConfigurationVersion = 1

public enum ReceivePolicy: String, Codable, Sendable, CaseIterable {
    case ask
    case trustedOnly = "trusted_only"
    case off
}

public enum TransportPreference: String, Codable, Sendable, CaseIterable {
    case https
    case httpCompatibility = "http_compatibility"
}

public struct ManualPeer: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var alias: String
    public var address: String
    public var port: Int
    public var fingerprint: String?

    public init(id: String, alias: String, address: String, port: Int, fingerprint: String? = nil) {
        self.id = id
        self.alias = alias
        self.address = address
        self.port = port
        self.fingerprint = fingerprint
    }
}

public struct AirSendRuntimeConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var preferredTargetID: String?
    public var manualPeers: [ManualPeer]
    public var trustedPeerFingerprints: [String]
    public var receivePolicy: ReceivePolicy
    public var clipboardSyncEnabled: Bool
    public var clipboardImageSyncEnabled: Bool
    public var screenshotSyncEnabled: Bool
    public var launchAtLoginEnabled: Bool
    public var downloadDestination: String
    public var mediaDestination: String
    public var transportPreference: TransportPreference
    public var historyLimitPerDirection: Int

    public init(
        version: Int = airSendConfigurationVersion,
        preferredTargetID: String? = nil,
        manualPeers: [ManualPeer] = [],
        trustedPeerFingerprints: [String] = [],
        receivePolicy: ReceivePolicy = .ask,
        clipboardSyncEnabled: Bool = false,
        clipboardImageSyncEnabled: Bool = false,
        screenshotSyncEnabled: Bool = false,
        launchAtLoginEnabled: Bool = false,
        downloadDestination: String = "~/Downloads",
        mediaDestination: String = "~/Downloads",
        transportPreference: TransportPreference = .https,
        historyLimitPerDirection: Int = 30
    ) {
        self.version = version
        self.preferredTargetID = preferredTargetID
        self.manualPeers = manualPeers
        self.trustedPeerFingerprints = trustedPeerFingerprints
        self.receivePolicy = receivePolicy
        self.clipboardSyncEnabled = clipboardSyncEnabled
        self.clipboardImageSyncEnabled = clipboardImageSyncEnabled
        self.screenshotSyncEnabled = screenshotSyncEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.downloadDestination = downloadDestination
        self.mediaDestination = mediaDestination
        self.transportPreference = transportPreference
        self.historyLimitPerDirection = historyLimitPerDirection
    }

    public func normalized() throws -> AirSendRuntimeConfiguration {
        guard version == airSendConfigurationVersion else {
            throw RuntimeConfigurationError.unsupportedVersion(version)
        }
        guard (1...500).contains(historyLimitPerDirection) else {
            throw RuntimeConfigurationError.invalidHistoryLimit(historyLimitPerDirection)
        }

        let preferredTargetID = preferredTargetID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let downloadDestination = downloadDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaDestination = mediaDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !downloadDestination.isEmpty else {
            throw RuntimeConfigurationError.invalidDestination("downloadDestination")
        }
        guard !mediaDestination.isEmpty else {
            throw RuntimeConfigurationError.invalidDestination("mediaDestination")
        }

        var peersByEndpoint: [String: ManualPeer] = [:]
        for peer in manualPeers {
            let id = peer.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let alias = peer.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = peer.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !alias.isEmpty, !address.isEmpty, (1...65_535).contains(peer.port) else {
                throw RuntimeConfigurationError.invalidManualPeer(peer.id)
            }
            let normalizedPeer = ManualPeer(
                id: id,
                alias: alias,
                address: address,
                port: peer.port,
                fingerprint: normalizeFingerprint(peer.fingerprint)
            )
            peersByEndpoint["\(address.lowercased()):\(peer.port)"] = normalizedPeer
        }

        let trusted = Set(trustedPeerFingerprints.compactMap { normalizeFingerprint($0) }).sorted()
        return AirSendRuntimeConfiguration(
            preferredTargetID: preferredTargetID,
            manualPeers: peersByEndpoint.values.sorted { $0.id < $1.id },
            trustedPeerFingerprints: trusted,
            receivePolicy: receivePolicy,
            clipboardSyncEnabled: clipboardSyncEnabled,
            clipboardImageSyncEnabled: clipboardImageSyncEnabled,
            screenshotSyncEnabled: screenshotSyncEnabled,
            launchAtLoginEnabled: launchAtLoginEnabled,
            downloadDestination: downloadDestination,
            mediaDestination: mediaDestination,
            transportPreference: transportPreference,
            historyLimitPerDirection: historyLimitPerDirection
        )
    }
}

public enum RuntimeConfigurationError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidHistoryLimit(Int)
    case invalidDestination(String)
    case invalidManualPeer(String)
}

public struct ConfigurationLoadOutcome: Sendable {
    public var configuration: AirSendRuntimeConfiguration
    public var warning: String?
    public var recoveredFile: URL?

    public init(configuration: AirSendRuntimeConfiguration, warning: String? = nil, recoveredFile: URL? = nil) {
        self.configuration = configuration
        self.warning = warning
        self.recoveredFile = recoveredFile
    }
}

public actor RuntimeConfigurationStore {
    public let fileURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AirSend-macOS", isDirectory: true)
            .appendingPathComponent("runtime-config.json", isDirectory: false)
    }

    public func load(defaults: AirSendRuntimeConfiguration = AirSendRuntimeConfiguration()) throws -> ConfigurationLoadOutcome {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let normalized = try defaults.normalized()
            try save(normalized)
            return ConfigurationLoadOutcome(configuration: normalized)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try decoder.decode(AirSendRuntimeConfiguration.self, from: data)
            return ConfigurationLoadOutcome(configuration: try decoded.normalized())
        } catch {
            let recoveredURL = recoveryURL()
            try fileManager.moveItem(at: fileURL, to: recoveredURL)
            let normalized = try defaults.normalized()
            try save(normalized)
            return ConfigurationLoadOutcome(
                configuration: normalized,
                warning: "Configuration was invalid and has been replaced with safe defaults: \(error.localizedDescription)",
                recoveredFile: recoveredURL
            )
        }
    }

    public func save(_ configuration: AirSendRuntimeConfiguration) throws {
        let normalized = try configuration.normalized()
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try encoder.encode(normalized)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func recoveryURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("runtime-config.corrupt-\(stamp).json", isDirectory: false)
    }
}

private func normalizeFingerprint(_ value: String?) -> String? {
    value?
        .lowercased()
        .filter(\.isHexDigit)
        .nilIfEmpty
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
