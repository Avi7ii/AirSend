# AirSend Console Devices Design

## Goal

Turn the existing AirSend Settings window into an `Open AirSend...` console while preserving the current Devices page as the default landing view. The first implementation should feel like a careful evolution of the existing UI, not a redesign.

The console should answer three questions at a glance:

- Which target will AirSend use now?
- Is local discovery and transport healthy?
- What happened recently?

## Scope

In scope:

- Rename the status menu entry from `Settings...` to `Open AirSend...`.
- Rename the window from `AirSend Settings` to an AirSend console-style window.
- Change the sidebar subtitle from `Settings` to `Console`.
- Keep `Devices` selected by default.
- Replace the sidebar sections with `Devices`, `Transfers`, `Clipboard`, `Diagnostics`, and `Settings`.
- Keep the existing Devices content and visual language.
- Add a compact health/status strip above `CURRENT TARGET`.
- Replace the bottom `Actions` section with a two-column lower area: `Quick Actions` and `Recent Activity`.

Out of scope for this pass:

- Dock icon / normal app activation policy changes.
- Persistent transfer history storage.
- Full Diagnostics page implementation.
- Retry queues, rules, trusted-device management, or clipboard history.

## UX Design

The Devices page remains the default page. Its subtitle changes to:

`Targets, discovery, health, and recent AirSend activity.`

Add a top health strip before the Current Target card:

- Left: green status dot plus `Ready`
- Middle: visible device count
- Right: last preflight summary such as `Last check: HTTPS preflight OK`
- Right action: `Run Diagnostics`

The Current Target and LAN Devices cards should remain visually close to the existing implementation. Avoid moving core target selection or LAN device rows.

Replace the bottom `Actions` card with:

- `Quick Actions`: existing `Rescan`, `Add by IP`, and `Broadcast` controls.
- `Recent Activity`: three to five compact rows. For the first pass, rows can be derived from lightweight in-memory events emitted by existing app callbacks. If no events exist, show an empty state.

## Architecture

Extend the existing settings window instead of adding a new window controller.

Primary files:

- `AirSendSettingsWindowController.swift`: rename window title and keep close behavior as hide/order-out if needed.
- `AirSendSettingsView.swift`: update sidebar, Devices page layout, and add small reusable rows/cards.
- `main.swift`: rename menu item and extend `AirSendSettingsSnapshot` with health and activity data.

New model fields should be added to `AirSendSettingsSnapshot`, not pulled directly from global app state inside SwiftUI views. The AppDelegate remains the source of runtime state.

## Data Flow

`AppDelegate` builds a snapshot with:

- current target title/subtitle
- protocol label
- visible and remembered device counts
- health state
- preflight summary
- recent activity rows

`AirSendSettingsStore` publishes the snapshot. UI actions call the existing action closures where possible:

- `rescan`
- `addDeviceByIP`
- `selectBroadcastTarget`
- `sendClipboardNow`

For first-pass activity rows, use a small bounded in-memory list in `AppDelegate`. Emit events for:

- discovery found/updated device
- outgoing clipboard text/image attempt success or failure
- incoming transfer completion
- manual rescan
- compatibility mode toggle

Do not store clipboard contents in activity rows.

## Error Handling

The health strip should be conservative:

- `Ready`: at least one visible device or no recent transport error.
- `Needs attention`: recent transfer/preflight/discovery error.
- `Searching`: no visible devices.

The `Run Diagnostics` button can initially trigger a rescan and record a diagnostic activity entry. A full Diagnostics page can be implemented later.

If activity data is unavailable, show an empty row rather than failing the window.

## Testing

Manual verification:

- Open menu and confirm `Open AirSend...` opens the window.
- Close the window and confirm status bar app remains alive.
- Confirm Devices remains default and existing target/device actions still work.
- Confirm resizing does not cause text overlap.
- Confirm no clipboard content is displayed in activity rows.

Build verification:

- Run the macOS Swift package build or existing self-test target used by this repo.

## Approved Reference

Approved direction: preserve the current Devices page and add console elements in-place. The generated visual mockup was preview-only and should be treated as direction, not pixel-perfect source.
