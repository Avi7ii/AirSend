public enum PreferredHostProbeTrigger: Sendable {
    case startup
    case wake
    case networkPathChange
    case manualRefresh
    case offlineRecovery
    case menuOpen
    case periodicAnnouncement
}

public enum PreferredHostProbePolicy {
    public static func shouldProbe(for trigger: PreferredHostProbeTrigger) -> Bool {
        switch trigger {
        case .startup, .wake, .networkPathChange, .manualRefresh, .offlineRecovery:
            true
        case .menuOpen, .periodicAnnouncement:
            false
        }
    }
}
