# AirSend macOS Runtime Parity Plan

Date: 2026-07-15

## Objective

Bring the macOS application to semantic parity with the mature Android runtime while preserving native macOS interaction patterns, the existing update menu card, and the accepted DropZone activation and dismissal geometry.

The implementation must improve correctness, observability, and recovery without turning the menu bar application into a second Android-style daemon or increasing idle power usage.

## Execution Rules

1. Work only in this repository and preserve all existing uncommitted runtime dependencies until they have been audited.
2. Execute the stages in dependency order. Do not replace a working path until its successor has automated coverage and is ready to be wired in.
3. Automated compilation, unit tests, integration tests, and static checks run continuously during implementation.
4. Per the user's explicit instruction for this program of work, do not pause for manual acceptance after each stage. Complete all stages, build and install the final application, then hand the complete result to the user for one unified acceptance pass.
5. Intermediate commits are allowed only when the included behavior is internally verified and the commit does not omit files required by the running version. Never commit unrelated Android third-party checkouts, generated output, or screenshots.
6. Preserve the existing `UpdateMenuItemView` appearance and placement.
7. Preserve the two-region DropZone model: a wide initial activation band and a much smaller post-activation keepalive/dismissal region.
8. Power policy is event-driven by default. Polling is permitted only when macOS exposes no reliable event API, and it must be disabled when its feature is off.
9. Backend parity is a hard completion gate. Every Android AirSend capability must exist on macOS or have an explicitly documented native macOS equivalent; no capability may disappear merely because the current Mac UI does not expose it.
10. Frontend quality is a hard completion gate. Do not ship placeholder panels, demo-only controls, fabricated state, unfinished navigation, or visually inconsistent fallback components.

## Backend Parity Contract

The macOS runtime must cover the Android AirSend contracts for runtime health, discovery, preferred target, manual peers, trusted peers, receive policy, text and file sending, share-origin metadata, screenshot automation, clipboard automation, active transfers, accept, decline, cancel, retry, sent and received history, per-file progress, previews, saved paths, destination configuration, transport preference, logs, log export and clearing, service recovery, network recovery, versioned configuration, versioned history, and capability reporting.

Android-only root authorization, LSPosed module state, Android foreground-service notification state, boot receiver state, and media-provider integration are not copied literally. Their user-visible outcomes must have native equivalents where relevant: launch at login, listener health, runtime restart, sleep/wake recovery, Finder reveal/share, and macOS file metadata handling.

Before final acceptance, maintain a source-backed parity matrix with one of three statuses for every Android action and state field: `implemented`, `native equivalent`, or `not applicable with reason`. No item may remain `planned` or `placeholder`.

## Frontend Quality Contract

- Preserve the established dark glass visual language, spacing rhythm, typography hierarchy, icon treatment, compact status-menu density, and the existing update card.
- Every control must be wired to live runtime state and expose disabled, loading, success, empty, offline, permission, and failure states where applicable.
- Activity, device, transfer, trust, receive, automation, diagnostic, and settings views must support their complete expected workflows rather than stopping at summary cards.
- Active transfers must remain stable under live progress updates; labels, buttons, and rows may not resize or overlap as values change.
- Use native macOS controls, SF Symbols, keyboard focus, VoiceOver labels, tooltips for unfamiliar icon-only actions, and appropriate confirmation for destructive operations.
- Validate the finished status menu and every Console page at minimum window size, default size, enlarged size, light and dark system contrast behavior where applicable, empty data, long device names, concurrent transfers, and error-heavy states.
- Final visual acceptance requires captured screenshots of all important states and a comparison pass against the existing AirSend design language and the functional density of the Android application.

## Stage 0: Protect the Current Baseline

- Audit every modified and untracked macOS source file and identify which files are required by the currently running build.
- Build the current macOS package and run all existing updater, drag handoff, console support, and discovery support self-tests.
- Record the current application version, bundle identity, signature state, and installed behavior before replacing any implementation.
- Exclude unrelated Android third-party directories, generated outputs, screenshots, and unrelated documents from future commits.

Exit criteria: the current source builds, its dependency set is known, and no current behavior is lost accidentally.

## Stage 1: Introduce the Runtime Core

- Add an `AirSendRuntimeCore` Swift package target.
- Define transfer direction, source, transfer status, per-file status, peer identity, retry metadata, saved paths, previews, and structured errors.
- Add a `TransferCoordinator` actor with per-transfer state, monotonic progress, per-transfer cancellation, retry specifications, and bounded recent in-memory records.
- Add an ordered `RuntimeEventHub` based on `AsyncStream`; throttle active progress publication to at most once every 100 ms per transfer.
- Keep the new core independent of AppKit and SwiftUI so it can be tested without launching the application.

Exit criteria: simultaneous transfers cannot overwrite one another, cancelling one transfer cannot cancel another, and invalid state transitions are rejected by tests.

## Stage 2: Add Durable Configuration and History

- Add a versioned, `Codable` configuration store under Application Support with atomic replacement, permissions, validation, corruption recovery, and one-time migration from existing `UserDefaults` keys.
- Persist only terminal transfer records in SQLite; keep active progress in memory.
- Use WAL mode, directional history limits, schema versioning, delete/clear operations, and deterministic migration tests.
- Keep legacy values available until migration succeeds; never silently discard the selected target, trusted peers, compatibility mode, or automation switches.

Exit criteria: settings and terminal history survive restart, corrupted configuration recovers safely, and retention works independently for sent and received records.

## Stage 3: Rebuild the Receiver

- Replace the single global receiver session with a dictionary keyed by the real LocalSend session ID.
- Correlate authorization, upload, progress, cancellation, and completion to the same transfer ID.
- Implement `ask`, `trusted_only`, and `off` receive policies using peer fingerprints.
- Require valid session context for cancellation; never route inbound cancellation into the outgoing sender.
- Stream uploads into session staging files, validate declared sizes, sync data, and atomically promote completed files to their final destination.
- Invalidate tokens and remove session state at every terminal outcome.
- Recognize clipboard text only through the exact clipboard identity and size rules; ordinary text files remain files.
- Add limits for control request bodies, file counts, total declared size, file names, and idle session lifetime.
- Use a reference-counted power assertion only while one or more transfers are active.

Exit criteria: concurrent sessions, token replay, truncation, cancellation, duplicate names, clipboard text, and ordinary text files are covered by receiver integration tests.

## Stage 4: Unify the Sender

- Route files, clipboard text, clipboard images, and screenshots through the runtime coordinator.
- Replace duplicated direct-transfer implementations with one transport client and one retry/fallback policy.
- Use fingerprint-verifying `URLSession` paths for HTTPS preparation and upload; remove feature-dependent `curl -k` behavior.
- Retain the bounded campus fallback and expose its progress and cancellation through the same transfer record.
- Make cancellation and retry transfer-specific and retain retry payloads only while their source remains available.

Exit criteria: every outgoing source reports the same states, real-time progress, structured failures, independent cancellation, and retry behavior.

## Stage 5: Rework Discovery and Network Lifecycle

- Keep passive UDP discovery active and use low-frequency announcements with timer tolerance.
- Probe remembered hosts first with bounded concurrency.
- Use `NWPathMonitor` and workspace wake notifications for network rebinding and recovery.
- Run the official short announcement burst at startup, wake, path change, and explicit refresh.
- Permit a subnet sweep only as an explicit action or a cooldown-protected fallback after passive and preferred-host discovery fail.
- Remove the one-second menu-open scan loop and cap fallback probe concurrency.
- Replace periodic stale-peer cleanup with an event-driven or next-expiry one-shot schedule where practical.

Exit criteria: opening the menu does not repeatedly sweep the subnet, a closed menu performs no subnet sweeps, and Wi-Fi changes plus sleep/wake recover automatically.

## Stage 6: Converge DropZone on an Event-Driven State Machine

- Remove the permanent 20 Hz proximity timer.
- Install local and global drag-event monitors and throttle evaluation to at most 20 Hz only while drag movement exists.
- Gate activation in this order: drag movement, fresh drag pasteboard session, file-related pasteboard types, activation geometry.
- Do not require file URLs to be readable at the first gate; delayed URL publication must still activate naturally.
- Reject three-finger window dragging, AirSend window dragging, and non-file drags before any expensive window inspection.
- Keep window enumeration out of the normal path; allow at most a one-shot ambiguous-session fallback when pasteboard evidence genuinely cannot decide.
- Preserve the wide activation band and the small keepalive region as separate policies.
- End the session from mouse-up events, with only a short active-session watchdog for missed events.

Exit criteria: first-attempt Finder drags activate naturally, delayed URLs work, ordinary and three-finger window drags never activate, multi-display anchors work, cancellation distance remains compact, and idle window enumeration is zero.

## Stage 7: Complete Automation and Diagnostics

- Run clipboard polling only while text or clipboard-image sync is enabled; retain the existing coalescing tolerance.
- Prevent clipboard echo loops with explicit local-write suppression and bounded deduplication.
- Implement actual screenshot-file automation with directory events, screenshot metadata checks, file-stability checks, trusted-target requirements, and no directory polling.
- Report real listener, TLS, network path, discovery, transfer, storage, and automation health.
- Add bounded log tail, export, clear, networking restart, and diagnostic snapshot actions.

Exit criteria: all automation stops when disabled, screenshot watching is event-driven, and every diagnostic value comes from live runtime state rather than UI heuristics.

## Stage 8: Complete Status Menu and Console Parity

- Drive both surfaces from the same runtime snapshot and event stream.
- Add active transfer rows with direction, peer, progress, cancellation, failure, and retry.
- Add sent/received activity views with details, previews, open/share, retry, delete, and directional clear operations.
- Add trusted devices, receive policy, destination selection, automation controls, and real diagnostics.
- Keep the menu concise: immediate actions, active work, devices, critical status, settings, and the existing update card.
- Do not copy Android-only root, module, or foreground-service controls into macOS.

Exit criteria: no visible status is fabricated, the menu remains fast and compact, and the Console exposes the same core capabilities as Android in native macOS form.

## Stage 9: Final Regression, Power, CI, and Installation

- Run all Swift unit and integration tests, existing self-tests, release build, bundle assembly, signing checks, and updater validation.
- Exercise Mac to Android and Android to Mac text, image, multi-file, large-file, concurrent, cancel, retry, decline, offline, network-change, and sleep/wake scenarios.
- Verify deterministic power budgets: no idle subnet sweeps, no idle window enumeration, no disabled-feature clipboard timer, bounded progress events, and no leaked power assertions.
- Extend CI so runtime-core, receiver, sender, discovery, DropZone, release assembly, and Android compatibility tests protect the new contracts.
- Build and cover-install the final macOS application for the user's unified acceptance pass.

Exit criteria: all automated checks pass, the installed application matches the built source, and the complete acceptance matrix is ready for one user verification session.

## Unified Acceptance Matrix

- Device discovery, remembered peers, manual peers, self-filtering, broadcast selection, and network recovery.
- Bidirectional text, clipboard image, screenshot, single file, multiple files, folders, and large files.
- Concurrent send/receive, per-transfer cancel, decline, retry, failure recovery, and application restart history.
- Receive policies, trusted devices, save destinations, exact clipboard behavior, and duplicate file names.
- Status menu active state, update card, Console activity, diagnostics, logs, and settings persistence.
- Finder drag activation, delayed drag URLs, three-finger window dragging, AirSend window dragging, multi-display behavior, and compact DropZone dismissal.
- Idle CPU/network behavior, disabled automation behavior, sleep/wake, Wi-Fi changes, and updater installation.
