import Foundation

public enum AirSendRuntimeCapabilities {
    public static let protocolVersion = 1

    public static let current: Set<String> = [
        "runtime_snapshot",
        "runtime_events",
        "runtime_health",
        "peer_discovery",
        "manual_peers",
        "preferred_target",
        "peer_trust",
        "receive_policy",
        "versioned_config",
        "directional_history",
        "log_tail",
        "log_export",
        "log_clear",
        "send_text",
        "send_file",
        "send_files",
        "clipboard_image",
        "screenshot_file",
        "active_transfers",
        "per_file_progress",
        "cancel_transfer",
        "retry_transfer",
        "accept_transfer",
        "decline_transfer",
        "saved_paths",
        "media_previews",
        "destination_configuration",
        "transport_preference",
        "network_recovery",
        "runtime_restart",
        "launch_at_login",
        "finder_reveal",
        "system_share",
        "drop_zone",
        "campus_fallback",
        "sparkle_updates",
    ]
}
