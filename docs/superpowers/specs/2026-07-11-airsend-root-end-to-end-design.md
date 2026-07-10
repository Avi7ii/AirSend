# AirSend Root End-to-End Design

**Date:** 2026-07-11

**Status:** Approved for implementation

## Objective

Turn the Android Root mode from a UI shell around three fire-and-forget daemon
commands into a complete, observable, secure transfer product. Root mode covers
Magisk, KernelSU, and APatch installations with LSPosed enabled for automatic
clipboard integration.

This specification is the first of three ordered projects:

1. Complete Root mode.
2. Add alternative privileged daemon controllers such as Shizuku and a custom
   `su` command where the platform can honestly support them.
3. Add a no-Root mode by porting the official LocalSend discovery, send,
   receive, confirmation, progress, and history behavior into AirSend.

The later projects must reuse the state and UI contracts defined here instead
of creating parallel screens.

## Product Principles

- The daemon is the source of truth for devices, transfers, trust, runtime
  configuration, and transfer history in Root mode.
- The UI never reports success before the daemon reports success.
- Every visible control must either perform its stated action or be omitted.
- Automatic clipboard and screenshot delivery is restricted to a selected,
  trusted target.
- Existing InstallerX Revived and local Miuix components define the visual
  language. New behavior must not introduce a separate component style.
- Liquid glass is reserved for navigation and contextual action surfaces, not
  used as decoration on every card.
- Root background behavior must continue when the app process is absent.

## Current Problems To Remove

The implementation must remove all of these current behaviors:

- `send_text` and `send_file` return no result while the app immediately shows
  a success toast.
- The Activity page always renders an empty card and has no transfer sessions.
- Every discovered device appears selected and cannot be chosen as a target.
- Receive controls, save location, trusted devices, and send mode are disabled
  placeholders.
- Restarting from the UI only restarts `AirSendService`, not the Root daemon.
- The UI infers clipboard health from daemon reachability instead of checking
  the LSPosed reverse IPC path.
- The daemon accepts uploads from any LAN peer without a trust policy.
- Every small `text/plain` file is treated as clipboard data.
- TLS identity is generated but the daemon advertises HTTP and disables its TLS
  server identity.
- The HTTP router declares a one GiB limit despite claiming streaming support
  for larger files.
- Receive sessions never reach a completed state or leave the in-memory map.
- The cancel handler exists but is not registered in the HTTP router.
- Logs grow without rotation and repeated network errors are not rate limited.
- The Magisk service replaces same-version development APKs by hash, so an old
  module payload can overwrite a newer ADB-installed build after reboot.
- Existing Android tests mostly inspect source strings rather than behavior.

## Architecture

### Daemon-owned domain state

The Rust daemon owns a single `AppState` with these bounded services:

- `PeerService`: discovery, manual peers, recent peers, preferred target, and
  peer trust.
- `TransferService`: outgoing and incoming sessions, progress, cancellation,
  retries, and terminal results.
- `ConfigStore`: validated runtime configuration persisted atomically under
  `/data/adb/airsend`.
- `HistoryStore`: completed and failed transfer records persisted in SQLite.
- `EventHub`: fan-out of ordered state events to connected app clients.
- `HealthService`: protocol version, daemon build, TLS state, reverse clipboard
  channel state, network binding, and storage readiness.

Network protocol code remains inside the patched LocalSend crate. UI-specific
state must not be added to that crate.

### Bidirectional local IPC

The existing line-delimited JSON socket remains for compatibility, but new
messages use an envelope:

```json
{"id":"request-id","op":"get_state","payload":{}}
```

Every request receives exactly one response:

```json
{"id":"request-id","ok":true,"data":{}}
```

or:

```json
{"id":"request-id","ok":false,"error":{"code":"target_offline","message":"Target is offline"}}
```

Long-lived clients subscribe to ordered events:

```json
{"event":"transfer_progress","sequence":42,"data":{}}
```

Required operations:

- `hello`
- `subscribe`
- `get_state`
- `get_peers`
- `discover_now`
- `add_manual_peer`
- `remove_manual_peer`
- `set_preferred_target`
- `set_peer_trust`
- `send_text`
- `send_files`
- `accept_transfer`
- `decline_transfer`
- `cancel_transfer`
- `retry_transfer`
- `get_transfers`
- `get_history`
- `delete_history`
- `clear_history`
- `get_config`
- `set_config`
- `get_logs`
- `clear_logs`
- `restart_daemon`

Legacy `GET_PEERS`, `SEND_TEXT`, and `SEND_FILE` commands remain accepted during
the Root migration but must use the same services internally.

### Transfer model

Every transfer has a stable ID and includes:

- direction: outgoing or incoming
- peer ID, alias, and fingerprint
- source: app picker, clipboard, share sheet, screenshot, or remote peer
- files with stable IDs, names, MIME types, sizes, transferred bytes, and
  per-file status
- total bytes and transferred bytes
- status: queued, awaiting acceptance, preparing, transferring, paused,
  completed, failed, cancelled, or declined
- start and end timestamps
- structured error code and user-safe message
- retryability

The daemon emits snapshots when a session is created or changes phase and
throttled progress events while bytes move. Progress events must not be written
to persistent history on every chunk.

### Persistence

Runtime configuration is stored at `/data/adb/airsend/config.json` using a
versioned serde model and atomic replace. It includes:

- preferred target
- manual peers
- trusted peer fingerprints
- receive policy
- clipboard sync enabled
- screenshot sync enabled
- service startup enabled
- download and media destinations
- transport preference

Transfer history is stored at `/data/adb/airsend/history.db` using bundled
SQLite. Only terminal records are persisted. The initial retention policy is
500 records, with explicit delete and clear actions.

Files under `/data/adb/airsend` use restrictive permissions. The daemon must
recover from a corrupt configuration by preserving the corrupt file, loading
safe defaults, and publishing a health warning.

### Trust and transport security

- The daemon advertises HTTPS and serves with its persisted TLS identity.
- Peer fingerprints are pinned after explicit trust.
- A changed fingerprint invalidates trust and requires confirmation.
- Manual sends to an untrusted peer require confirmation in the app.
- Automatic clipboard and screenshot sends only target a trusted preferred
  peer.
- Incoming policy supports `ask`, `trusted_only`, and `off`.
- The default is `ask`; automatic acceptance is never enabled for arbitrary LAN
  peers.
- Clipboard payloads are identified by explicit metadata or the reserved
  `clipboard.txt` transfer source. Ordinary text files remain files.

### Root lifecycle and packaging

The app distinguishes the Android foreground shortcut service from the Root
daemon. Health and actions use precise names.

The Root daemon controller can:

- query process and module state
- start, stop, and restart the daemon
- compare app, module, daemon, and IPC versions
- report when a reboot or LSPosed reload is required

The Magisk service installs its APK payload only when the payload version code
is newer than the installed app, or when the package is absent. It must not
replace a same-version ADB development build by hash.

The release build process must update the module daemon and APK together and
verify their versions and hashes before creating the module zip.

### Android runtime layer

The Android app uses one `AirSendRepository` contract and one state model for
all visual themes. The Root implementation maintains a reconnecting IPC client,
merges response snapshots with ordered events, and exposes immutable flows.

ViewModels perform user intents and presentation mapping only. They do not
infer daemon success or duplicate daemon transfer state.

The app-side model includes:

- runtime health
- peers and preferred target
- active outgoing and incoming sessions
- send and receive history
- persisted settings
- transient confirmation and error events

## Product Flows

### Setup and health

Home shows real checks for app service, Root module, daemon version, daemon IPC,
TLS, LSPosed reverse clipboard IPC, notification permission, and storage. A
failed check exposes the relevant action: request permission, open LSPosed,
restart daemon, or report a version mismatch.

### Device selection and trust

Devices are grouped into online, remembered, and manual entries. Selecting a
device makes it the preferred target. Device details expose address, model,
fingerprint, online state, trust state, last seen time, trust or revoke action,
and forget action. Manual peer entry validates IPv4/IPv6 host and port before
asking the daemon to probe it.

### Sending

The Send tab provides file selection and clipboard send using the preferred
target. If no target is selected, the existing device selector opens. The
transfer appears immediately as queued, then follows daemon events through a
terminal state. The contextual action surface offers cancel while active and
retry after a retryable failure.

The Android share sheet uses the same transfer service and event model. It must
not silently choose the first peer when multiple peers exist and no preferred
target is set.

### Receiving

The Receive tab shows pending requests and active downloads. `ask` policy
requires accept or decline. `trusted_only` automatically accepts trusted peers
and declines untrusted peers. `off` declines all incoming requests.

Completed items expose open and share actions when Android can resolve the
saved file. Media files are scanned after a successful atomic rename.

### History

The existing Send and Receive tabs contain their own terminal history below
active work. There is no duplicate History section or bottom destination.
History supports details, retry or resend where possible, open for received
files, delete, and clear-all confirmation.

### Settings and diagnostics

Only working settings remain visible:

- theme and page scale
- foreground shortcut service startup
- clipboard sync
- screenshot sync
- receive policy
- download destination
- media destination
- preferred transport
- trusted devices
- notification and storage permissions
- diagnostics, log export, log clear, and About

Log export uses Android's document creation flow. Permission actions request
the real runtime permission or open the relevant system settings page.

## UI System

The implementation reuses the current local components:

- `FloatingBottomBar` in liquid-glass mode for the four main destinations
- the same floating bar for Send and Receive tabs
- a compact liquid-glass contextual action dock for target selection and
  transfer cancel or retry
- existing status cards for health and aggregate progress
- existing `SegmentedColumn`, Miuix preference components, switches, and
  navigation rows for dense information
- existing Miuix dialogs for trust, receive confirmation, destructive clear,
  and error details

Liquid glass must not be used for long transfer rows, settings groups, history
cards, or nested containers. Material and Miuix pages share behavior and
content but render through their existing component families.

The four-page navigation and the Send/Receive pager must preserve animations
without clipping, overlap, or page-wide accidental swipes.

## Logging and diagnostics

- Rotate daemon logs at four files of four MiB each.
- Rate-limit identical network errors and publish an aggregate count.
- Redact clipboard payloads, local file contents, and private key material.
- Diagnostics include daemon/app/module versions, protocol version, network
  binding, selected target, transfer port, discovery port, and last structured
  error.
- Clear logs is explicit and confirmed.

## Testing

### Rust

- serialization and compatibility tests for every IPC request and event
- request/response correlation and error tests
- transfer state transition tests
- configuration migration and corrupt-file recovery tests
- SQLite history retention and deletion tests
- trust policy tests
- clipboard-versus-text-file classification tests
- cancel route and session cleanup tests
- log rotation and rate-limit tests
- mock LocalSend sender/receiver tests for progress and terminal results

### Android

- repository tests with a fake IPC transport
- ViewModel tests for send, receive, trust, retry, settings, and errors
- Compose semantics tests for working and disabled states
- no source-string assertions as evidence of runtime behavior

### Device and end-to-end

- build daemon and APK from current sources
- update the Root module payload and install it on the connected Root device
- verify module, daemon, app, and IPC versions
- verify all four bottom destinations and both Activity tabs
- transfer text and files Android to macOS and macOS to Android
- verify progress, cancellation, retry, receive confirmation, saved paths, and
  history
- verify clipboard and screenshot toggles
- verify notification permission and LSPosed diagnostics
- reboot and prove that the current app is not replaced by an older payload
- run a crash-focused logcat sweep and inspect bounded daemon logs

## Major Verification Checkpoints

Repository workflow requires user verification after each major code change.
Root mode is therefore delivered through these checkpoints:

1. Protocol, persistence, logging, and packaging foundation.
2. Outgoing transfer sessions and target selection.
3. Incoming requests, saving, trust, and history.
4. Health, settings, permissions, and diagnostics.
5. Shared Material/Miuix UI integration and full end-to-end regression.

Each checkpoint ends with focused tests, a complete Android build, ADB install,
launch, process check, daemon check, and crash-log sweep. Accepted checkpoints
are committed before the next major change.

## Acceptance Criteria

Root mode is complete only when:

- every Root-mode control is functional and backed by daemon or Android state
- send and receive operations expose truthful progress and terminal results
- cancellation and retry work on real transfers
- trust policy prevents automatic transfer to or from arbitrary LAN peers
- settings survive daemon and device restarts and affect runtime behavior
- history survives restarts and is manageable from the matching Activity tab
- current APK and daemon survive reboot without stale payload replacement
- daemon logs remain bounded
- automated tests cover behavior rather than source text
- physical-device end-to-end transfer passes in both directions
- the four pages and their animations pass visual checks at the connected
  device resolution and at least one Android Studio emulator phone resolution
