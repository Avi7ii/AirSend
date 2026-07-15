public enum AirSendLiveConnectionState: Equatable, Sendable {
    case networkUnavailable
    case receiverStopped
    case transferring(activeCount: Int)
    case ready(visibleDeviceCount: Int)
}

public enum AirSendLiveConnectionHealthPolicy {
    public static func evaluate(
        networkAvailable: Bool,
        receiverReady: Bool,
        activeTransferCount: Int,
        visibleDeviceCount: Int
    ) -> AirSendLiveConnectionState {
        guard networkAvailable else {
            return .networkUnavailable
        }
        guard receiverReady else {
            return .receiverStopped
        }
        if activeTransferCount > 0 {
            return .transferring(activeCount: activeTransferCount)
        }
        return .ready(visibleDeviceCount: max(0, visibleDeviceCount))
    }
}
