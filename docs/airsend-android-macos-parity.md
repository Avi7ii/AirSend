# AirSend Android to macOS Capability Parity

Date: 2026-07-15

This matrix is a completion gate for the macOS runtime work. Android sources are the mature reference. A macOS row may be marked only as `implemented`, `native equivalent`, or `not applicable with reason`.

## Source Baseline

- Android actions: `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeAction.kt`
- Android state: `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeState.kt`
- Android IPC payloads: `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendIpcModels.kt`
- Android daemon capabilities: `Android/airsend_daemon/src/ipc.rs`
- macOS runtime domain: `AirSend-macOS/Sources/AirSendRuntimeCore`
- macOS sender and receiver: `AirSend-macOS/Sources/AirSend/Service`
- macOS runtime wiring and status menu: `AirSend-macOS/Sources/AirSend/main.swift`
- macOS Console: `AirSend-macOS/Sources/AirSend/UI/AirSendSettingsView.swift`

## Runtime Actions

| Android action | macOS status | macOS implementation or native outcome |
| --- | --- | --- |
| Refresh / RefreshSilently | implemented | Event-driven runtime snapshots refresh the menu and Console; diagnostics provides an explicit live refresh. |
| DiscoverNow | implemented | Rescan probes remembered hosts first, sends discovery bursts, and permits a bounded fallback scan. |
| StartService | native equivalent | Launching the menu bar app starts discovery and the receiver automatically. |
| StopService | native equivalent | Quit stops discovery, automation, monitors, and the app-owned receiver; Receive Off disables inbound authorization without killing the UI. |
| RestartService / RestartWholeService / RestartDaemon | native equivalent | Restart Runtime recreates receiver, discovery, campus fallback, sender, and automation in one bounded operation. |
| SetBootStartEnabled | native equivalent | Launch at Login uses `SMAppService`. |
| SetServiceNotificationEnabled | not applicable with reason | macOS menu bar presence is the native persistent runtime surface; Android foreground-service notification policy does not exist. |
| SelectPeer | implemented | Status menu and Devices Console share the persisted preferred target, including broadcast. |
| SendClipboardText | implemented | Manual and automatic clipboard text use the unified sender and transfer coordinator. |
| SendFiles | implemented | File picker, DropZone, clipboard image, screenshot file, and folder ZIP all use the unified sender. |
| CancelTransfer | implemented | Outgoing, HTTP incoming, and campus incoming cancellation are scoped by transfer UUID. |
| RetryTransfer | implemented | Retry metadata retains source paths or text only while the original payload remains available. |
| AcceptTransfer / DeclineTransfer | native equivalent | Receive Ask uses a native modal decision before tokens or staging are issued; Trusted Only and Off decide automatically. |
| SetReceivePolicy | implemented | Ask, Trusted Only, and Off are persisted and enforced by both normal and campus receivers. |
| SetClipboardSyncEnabled | implemented | Clipboard text monitoring runs only while enabled and suppresses local echo. |
| SetScreenshotSyncEnabled | implemented | macOS exposes separate clipboard-image and real screenshot-file switches; screenshot files use filesystem events and metadata checks. |
| SetHistoryLimitPerDirection | implemented | SQLite retention is independent for sent and received records. |
| SetTransportPreference | implemented | HTTPS default and explicit HTTP compatibility mode rebind the full networking stack. |
| SetPeerTrusted | implemented | Fingerprint trust is persisted and used by receive policy plus automatic screenshot targeting. |
| SetDownloadDestination / SetMediaDestination | native equivalent | Native directory pickers configure file and media destinations separately. |
| AddManualPeer / RemoveManualPeer | implemented | Alias, endpoint, port, and optional fingerprint are persisted; HTTPS requires fingerprint identity. |
| DeleteHistory / ClearHistory | implemented | Delete one record or clear one direction from SQLite and live snapshots. |
| OpenReceivedFile | native equivalent | Show in Finder reveals all available received paths. |
| ShareReceivedFile | native equivalent | `NSSharingServicePicker` exposes the system share sheet. |
| ExportLogs / ClearLogs | implemented | Native save panel exports bounded logs; destructive clear is confirmed. |

## Runtime State

| Android state group | macOS status | macOS implementation or native outcome |
| --- | --- | --- |
| serviceRunning / daemonReachable / daemonProcessRunning | native equivalent | Receiver listener health, network-path state, runtime uptime, and Restart Runtime describe the in-process menu bar runtime. |
| authorizationMode / rootAvailable / rootProvider | not applicable with reason | macOS does not require Android root authorization to host its user process. |
| moduleInstalled / moduleEnabled / moduleVersion / moduleVersionCode / requiresReboot | not applicable with reason | LSPosed and Magisk module lifecycle is Android-only. |
| appVersion / appVersionCode | native equivalent | Sparkle and bundle metadata report the macOS version; the preserved update card owns update state. |
| bootStartEnabled | native equivalent | Launch at Login reflects `SMAppService` state. |
| serviceNotificationEnabled / notificationPermissionGranted | not applicable with reason | The status item is the native runtime indicator and does not require notification permission. |
| storagePermissionGranted | native equivalent | Diagnostics reports actual destination writability; native directory pickers establish user intent. |
| peers | implemented | Passive discovery, remembered hosts, manual peers, trust, selection, endpoint changes, and self-filtering feed one device snapshot. |
| protocolVersion / daemonVersion | native equivalent | Runtime capability protocol version and bundle version replace Android daemon IPC versioning. |
| configVersion / historySchemaVersion | implemented | Versioned JSON configuration and SQLite schema versions are exposed in Diagnostics. |
| daemonStartedAtMs | native equivalent | Runtime uptime is derived from app start. |
| preferredTargetId | implemented | Persisted target selection is shared by menu, Console, clipboard, screenshots, and files. |
| receivePolicy / trustedPeerFingerprints | implemented | Live configuration drives both normal HTTP(S) and campus fallback authorization. |
| downloadDestination / mediaDestination | implemented | Separate destinations are used by both receiver transports. |
| clipboardSyncEnabled / screenshotSyncEnabled | implemented | macOS provides text, clipboard-image, and screenshot-file state independently. |
| historyLimitPerDirection / historyCount | implemented | Directional SQLite retention and sent/received lists are live. |
| activeTransferCount / transfers | implemented | Runtime event snapshots include direction, source, peer, files, status, progress, failure, retry, saved paths, and previews. |
| healthWarnings / lastError | implemented | Diagnostics and recent activity expose listener, path, TLS, storage, automation, discovery, transfer, and persistence errors. |
| tlsFingerprint / tlsReady | implemented | Certificate identity, fingerprint, and active receiver protocol are live diagnostics. |
| transportProtocol / transportPreference | implemented | Current receiver protocol and persisted preference are distinct. |
| reverseClipboardIpcReady | native equivalent | Clipboard controller readiness replaces Android reverse IPC readiness. |
| storageReady | implemented | Both configured destinations are checked for writability. |
| networkBinding / transferPort / discoveryPort | implemented | Live network path and both service ports are reported. |
| capabilities | implemented | `AirSendRuntimeCapabilities` is source-backed and shown in Diagnostics. |
| isRefreshing | native equivalent | Console diagnostics displays an explicit run action and completion activity instead of a persistent Android-style spinner. |

## Transfer Payload and Behavior

| Android transfer field or behavior | macOS status | macOS implementation |
| --- | --- | --- |
| direction, source, peer identity | implemented | `TransferRecord` carries all three for every transport and source. |
| per-file id, name, MIME, size, bytes, status | implemented | `TransferFileRecord` is updated monotonically at no more than 10 UI events per second per transfer. |
| terminal status and timestamps | implemented | Completed, failed, cancelled, and declined records are persisted only after termination. |
| savedPaths | implemented | Atomic receiver publication records each final path. |
| previewPaths / previewText | native equivalent | Media paths use Quick Look thumbnails; clipboard transfers retain text preview metadata. |
| errorCode / errorMessage / retryable | implemented | Structured failures distinguish prepare, upload, save, timeout, cancellation, decline, and transport failures. |
| concurrent transfers | implemented | Coordinator, sender sessions, receiver sessions, cancellation, and power assertions are transfer-scoped. |
| large-file receive | implemented | HTTP(S) uploads stream to bounded staging files and atomically publish after size validation. |
| large-file send | implemented | URLSession streams file-backed request bodies; campus fallback is intentionally capped at 1 MiB. |
| exact clipboard identity | implemented | Only `clipboard.txt` with `text/plain` updates the clipboard; ordinary text files remain files. |
| duplicate names | implemented | Destination naming is collision-safe before atomic publication. |

## Native macOS Additions

- Event-driven DropZone with separate activation and compact keepalive regions.
- Clipboard-image sync separated from actual screenshot-file automation.
- Finder reveal, Quick Look thumbnails, system share sheet, launch at login, sleep/wake recovery, and Sparkle click-to-install updates.
- Capability reporting includes `drop_zone`, `campus_fallback`, `sparkle_updates`, `finder_reveal`, and `system_share` in addition to Android-equivalent runtime contracts.
