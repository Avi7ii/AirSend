<p align="center">
  <img src="m3-icon-dynamic-rose.png" width="200" height="200" alt="AirSend Icon">
</p>

<h1 align="center">🚀 AirSend </h1>

<p align="center">
  <img src="https://komarev.com/ghpvc/?username=Avi7ii&repo=AirSend&label=Views&color=007ec6&style=social" alt="Views">
  <a href="https://github.com/Avi7ii/AirSend/releases"><img src="https://img.shields.io/github/downloads/Avi7ii/AirSend/total" alt="Total Downloads"></a>
  <a href="https://github.com/Avi7ii/AirSend"><img src="https://img.shields.io/github/stars/Avi7ii/AirSend" alt="GitHub stars"></a>
  <a href="https://github.com/Avi7ii/AirSend/releases/latest"><img src="https://img.shields.io/github/v/release/Avi7ii/AirSend?color=pink&include_prereleases" alt="Latest Release"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/Platform-macOS%2013%2B-blue.svg" alt="Platform: macOS"></a>
  <a href="https://www.android.com/"><img src="https://img.shields.io/badge/Platform-Android%2010%2B-green.svg" alt="Platform: Android"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.2-orange.svg" alt="Swift: 6.2"></a>
  <a href="https://kotlinlang.org"><img src="https://img.shields.io/badge/Kotlin-1.9.23-purple.svg" alt="Kotlin: 1.9.23"></a>
  <a href="https://www.rust-lang.org/"><img src="https://img.shields.io/badge/Rust-1.93.1-black.svg" alt="Rust: 1.93.1"></a>
</p>

<p align="center">
  <b>English</b> | <a href="README.md">简体中文</a>
</p>

<h2 align="center">🤔 What is this?</h2>

AirSend is a cross-platform connectivity tool designed for **Mac + Android** users. The core goal is simple: **make file transfers and clipboard sync as effortless as AirDrop — without needing two Apple devices.**

It consists of two parts:
- **macOS side**: A natively-built Swift menu bar app, ~20MB RAM, no main window, drag-and-drop to send
- **Android side**: Choose as needed — use the official LocalSend directly, or install the AirSend custom app for system-level deep integration

> **Network requirement**: Both devices must be on the same Wi-Fi LAN, with AP isolation disabled on the router. HTTPS remains the default path; if you are on a campus or dorm network where discovery works but transfers stall, see the `HTTP Compatibility Mode` section below.

---

<h2 align="center"> ⚖️ How it compares to official LocalSend </h2>

<div align="center">

| Feature                | Official LocalSend                   | AirSend                                         |
| ---------------------- | ------------------------------------ | ----------------------------------------------- |
| macOS UI               | Flutter cross-platform main window   | Pure Swift native menu bar, no main window      |
| RAM Usage              | ~300MB                               | **~20MB**                                       |
| Clipboard Sync         | ❌                                    | ✅ Two-way automatic (Android ↔ Mac)             |
| Screenshot Auto-Push   | ❌                                    | ✅ Screenshots appear in Mac Downloads instantly |
| Image Clipboard Sync   | ❌                                    | ✅ Copied images on Mac auto-send to Android     |
| Android Background     | Depends on system process management | Rust daemon, independent of App lifecycle       |
| System-Level Clipboard | ❌                                    | ✅ (Requires Root + LSPosed)                     |
| Campus LAN path        | ❌ No manual HTTP compatibility path  | ✅ Manual HTTP compatibility mode (default off) |
| Large campus-subnet discovery | ❌ Easy to lose visibility once multicast is suppressed | ✅ `/24` slice expansion + remembered-host keepalive |
| Drag-and-drop UX       | Standard window drag target          | ✅ Prewarmed DropZone, anti-bounce, background minimize |
| Protocol Compatibility | ✅ LocalSend standard                 | ✅ Fully compatible with LocalSend               |

</div>

---

<h2 align="center"> ✨ Features </h2>

### 📁 File Transfer

Drag files onto the macOS menu bar icon to send. Two modes supported:
- **Broadcast mode**: Send to all online AirSend/LocalSend devices on the LAN simultaneously
- **Unicast mode**: Select a specific device in the menu to send only to that device

Received files are saved to the Downloads folder via streaming I/O, auto-renamed on conflict (e.g. `photo (1).jpg`), with no extra memory buffer.

On home routers, mobile hotspots, and other normal LANs, AirSend still defaults to the standard LocalSend-style HTTPS path, so Android users can use the official LocalSend app to transfer files with Mac with no extra configuration.

On campus Wi-Fi, dorm networks, or other policy-heavy LANs, however, official LocalSend often stops at "the device is visible, but the actual transfer never really starts". That is where AirSend's full mode and the `HTTP Compatibility Mode` below come in.

### 📋 Two-Way Clipboard Sync

**Android → Mac**: Copy text on your phone, and the Mac clipboard updates automatically within seconds — no app needed, no popups. Requires full mode (Root + LSPosed).

**Mac → Android**: Copy anything on Mac, and the Android clipboard syncs automatically. Equally seamless and silent.

**Anti-loop design**: When synced content is written to the local clipboard, an internal flag is set to prevent triggering another sync cycle. Clipboard temp files (`clipboard.txt`) received from Android are read and immediately deleted — no trace left on disk.

### 📸 Screenshot Auto-Send (Android → Mac)

Take a screenshot on Android and it appears directly in your Mac's Downloads folder — without opening any app or manually sharing.

How it works: The Rust daemon uses Linux `inotify` to continuously monitor screenshot directories. On detecting a new file write, it waits 1 second (for EXT4 page cache flush), then pushes it to Mac via the default HTTPS path or the compatibility HTTP path when needed. Compatible with AOSP native paths and custom ROM paths (MIUI, HyperOS, ColorOS, etc.).

### 🖼️ Image Clipboard Sync (Mac → Android)

When you copy a screenshot or image on Mac, `ClipboardService` checks first for TIFF image data in the clipboard, converts it to PNG, and sends it to Android via the default HTTPS path or the compatibility HTTP path when needed.

### 📱 Direct Share Integration

When sharing files on Android, your Mac appears directly in the system's Direct Share target list — like sending to a contact. No need to open AirSend, just tap and send.

### 🌐 Campus / Complex LAN Compatibility

AirSend 3.0.0 adds a **manual, default-off** `HTTP Compatibility Mode` specifically for networks where discovery works but the HTTPS data plane repeatedly times out or hangs.

- The default remains **secure HTTPS mode**, so normal home-network usage and standard compatibility with official LocalSend stay intact
- If devices can discover each other on a campus network but transfers keep stalling, turn on `Advanced -> Compatibility Mode (HTTP)` in the macOS menu bar
- Once enabled, macOS exposes a plain-HTTP receive path, and the sender performs a real data-plane preflight before sending so it can choose the path that actually works on that LAN
- If campus policy suppresses UDP multicast, AirSend can expand discovery by `/24` slices across a large subnet and also remember the last reachable device IP for lightweight re-probing and list keepalive
- In practice, AirSend now addresses not only “device discovered but transfer unusable”, but also “after switching to campus Wi-Fi the phone is missing from the menu again”
- This compatibility path is an extra AirSend capability built for difficult LANs; **official LocalSend does not currently provide it**
- For home routers and mobile hotspots, leaving the default HTTPS mode on is still recommended
- The compatibility path itself is also tighter now: no silent downgrade by default, better cancellation and timeout cleanup, small-payload fallback boundaries, and session/source binding to reduce packet mixups

---

<h2 align="center"> 📋 Requirements </h2>


<div align="center">

| Platform                      | Requirement                                               |
| ----------------------------- | --------------------------------------------------------- |
| macOS                         | macOS 13 Ventura or later                                 |
| Android (basic file transfer) | Android 8.0+, install official LocalSend                  |
| Android (full features)       | Root + Magisk or KernelSU + LSPosed                       |
| Network                       | Both devices on the same Wi-Fi LAN, AP isolation disabled |
| Firewall                      | Allow UDP 53317 and TCP 53317-53319                       |

</div>

---

<h2 align="center">🕸️ Architecture Overview</h2>

The diagram below shows the role of each module on the macOS and Android sides, along with the communication links between them.

```mermaid
%%{init: {'theme': 'dark', 'themeVariables': {'background': 'transparent', 'clusterBkg': '#0d0d0d55', 'edgeLabelBackground': '#1a1a2e', 'fontSize': '16px'}}}%%
flowchart TB
    classDef mac_node fill:#1d1d1f,stroke:#007aff,stroke-width:2px,color:#fff
    classDef android_node fill:#0d231e,stroke:#3ddc84,stroke-width:2px,color:#fff
    classDef daemon_node fill:#2b1a13,stroke:#f86523,stroke-width:2px,color:#fff
    classDef magic_node fill:#1e1b4b,stroke:#a855f7,stroke-width:2px,color:#fff
    classDef protocol_line color:#eab308,stroke-width:3px,stroke-dasharray: 5 5

    %% ==========================================
    %% Part 1: macOS Side
    %% ==========================================
    subgraph macOS_Side ["💻 macOS Side (Ultimate Native Hub)"]
        direction TB

        subgraph Mac_App ["App Orchestrator - AppDelegate / @MainActor"]
            AppCore["Menu Bar App / Device Registry / Wakelock"]:::mac_node
            DragDetect["Drag Monitor / DropZoneWindow / 1s idle - 0.1s active / 60px boundary fallback"]:::mac_node
            AppCore --- DragDetect
        end

        subgraph Mac_Security ["Security Layer"]
            CertMgr["CertificateManager / Self-Signed X.509 / TLS Fingerprint"]:::mac_node
            UpdateSvc["UpdateService / GitHub API / Auto Update Check"]:::mac_node
        end

        subgraph Mac_Network ["Network.framework - Dual Engine"]
            UDP_Disc["UDPDiscoveryService / Port 53317 / LAN Broadcast / `/24` Expansion / Remembered Host Probe"]:::mac_node
            HTTP_Trans["HTTPTransferServer / HTTPS Default + HTTP Compatibility / Port 53318 / Per-Conn Queue"]:::mac_node
            CertMgr -->|"Inject TLS Identity"| HTTP_Trans
        end

        subgraph Mac_Send ["Send Engines"]
            FileSender["FileSender / HTTPS Default / HTTP Preflight / Small-Payload Fallback"]:::mac_node
            ClipSender["ClipboardSender / Text as clipboard.txt / Image as PNG / Compatibility Aware"]:::mac_node
        end

        subgraph Mac_Clipboard ["Clipboard Engine"]
            ClipSvc["ClipboardService 3s Poll / TIFF-PNG Priority / changeCount Guard"]:::mac_node
            Mac_Clip["macOS Clipboard / NSPasteboard"]:::mac_node
            ClipSvc <-->|"Read / Write + Anti-Echo"| Mac_Clip
        end

        AppCore -->|"Schedule"| UDP_Disc
        AppCore -->|"Schedule"| HTTP_Trans
        DragDetect -->|"Drop Event"| FileSender
        ClipSvc -->|"Text Change"| ClipSender
        ClipSvc -->|"Image Change"| ClipSender
        HTTP_Trans -->|"Receive Text / Write"| Mac_Clip
        HTTP_Trans -->|"Stream to Disk / Conflict Rename"| AppCore
    end

    %% ==========================================
    %% Part 2: Android Side
    %% ==========================================
    subgraph Android_Side ["🤖 Android Side (Piercing the System)"]
        direction TB

        subgraph App_Layer ["App Layer - Kotlin"]
            BootRcv["BootReceiver / Auto-Start on Boot"]:::android_node
            ForegroundSvc["AirSendService / Foreground / dataSync / START-STICKY"]:::android_node
            ShortcutMgr["ShortcutManager / Dynamic Direct Share Injection"]:::android_node
            ShareTarget["ShareTargetActivity / Silent Ghost Share Entry"]:::android_node
            BootRcv --> ForegroundSvc
            ForegroundSvc --> ShortcutMgr
        end

        subgraph Magisk_Modules ["Xposed Layer - Runs in system-server Process"]
            LSPosedHook{"ClipboardHook / Hook: ClipboardService.ClipboardImpl"}:::magic_node
            AntiLoop["Anti-Loop Lock / isWritingFromSync volatile / 500ms delay"]:::magic_node
            GodMode["God-Mode IPC Server / LocalServerSocket @airsend-app-ipc"]:::magic_node
            SystemClip["SystemClipboard / ClipboardManagerService - UID 1000 bypass"]:::magic_node
            LSPosedHook --> AntiLoop
            AntiLoop <-->|"Spy / Force-Write"| SystemClip
            GodMode -->|"Inject via ActivityThread context"| SystemClip
        end

        subgraph Rust_Daemon ["Rust Daemon - arm64-v8a - Magisk Module"]
            inotify["inotify / notify crate / EXT4 Close-Write and Rename / 1s cache delay"]:::daemon_node
            TokioCore["Tokio Async Runtime / Reqwest Client / Port 53319 / Complex-LAN Rebind"]:::daemon_node
            UDSServer["Unix Domain Sockets / @airsend-ipc and @airsend-app-ipc"]:::daemon_node
            inotify -->|"Screenshot Detected"| TokioCore
            UDSServer <-->|"IPC Command Bus"| TokioCore
        end

        BootRcv -.->|"Verify Daemon Alive"| UDSServer
        ForegroundSvc <-->|"GET-PEERS / 30s poll"| UDSServer
        LSPosedHook -->|"SEND-TEXT via @airsend-ipc"| UDSServer
        UDSServer -->|"push-text-to-app via @airsend-app-ipc"| GodMode
    end

    %% ==========================================
    %% Part 3: LAN Cross-Border Flows
    %% ==========================================
    UDP_Disc <===>|"UDP Discovery - LocalSend Compatible"| TokioCore:::protocol_line
    TokioCore ==>|"HTTPS/HTTP - Screenshot Auto-Send - inotify triggered"| HTTP_Trans:::protocol_line
    ClipSender ==>|"HTTPS/HTTP - clipboard.txt / PNG / campus compatibility"| TokioCore:::protocol_line
    TokioCore ==>|"HTTPS/HTTP - Android Clipboard to Mac NSPasteboard"| HTTP_Trans:::protocol_line
    FileSender <==>|"HTTPS Default / HTTP Compatibility / Chunked File Transfer"| TokioCore:::protocol_line

```

<details>
<summary>📖 How to read this diagram (click to expand)</summary>
<br>

- **Yellow links**: LocalSend HTTPS is the default transport path; in compatibility mode AirSend can switch the LAN data path to plain HTTP for difficult campus-style networks
- **Blue area (macOS)**: Pure Swift, default `Network.framework` HTTPS receiver, plus a manually enabled plain-HTTP compatibility receiver for difficult LANs
- **UDPDiscoveryService**: Beyond normal discovery, it also handles `/24` expansion on large subnets and remembered-host re-probing so the device list does not disappear so easily on campus Wi-Fi
- **Green area (Android App)**: Kotlin foreground service, polls daemon every 30s for online devices, updates Direct Share shortcuts
- **Purple area (Xposed)**: Runs in `system_server` process, bypasses Android 10+ background clipboard restrictions via UID 1000, also serves as the Mac→Android direction endpoint of the IPC bus
- **Orange area (Rust Daemon)**: `arm64-v8a` native process, independent of App lifecycle, communicates via two Unix domain sockets (`@airsend_ipc` and `@airsend_app_ipc`), and handles rebinding on unstable LAN changes
- **Campus fallback boundary**: the compatibility fallback is intended as a small-payload recovery path on difficult LANs, not as a universal large-file traversal layer

</details>

---

<h2 align="center"> 💻 macOS Side </h2>

### 📌 How It Runs

AirSend lives entirely in the menu bar — no Dock icon, no main window. It launches at login by default via `SMAppService` (macOS 13+).

### 📂 Drag-and-Drop File Transfer

Drag a file toward the menu bar icon and a frosted-glass DropZone panel appears automatically. Release to immediately initiate a LocalSend handshake; transfer progress is shown in the panel. If no response is received within 8 seconds, the panel minimizes to the menu bar (a white dot appears on the icon) and the transfer continues in the background.

- Defaults to **broadcast** (all LAN devices); select a specific device in the menu to switch to **unicast**
- Previously connected devices are remembered and stay in the list even when offline
- Incoming files are **auto-accepted and auto-saved** with no confirmation popup

### 📋 Clipboard Monitoring

Mac polls `NSPasteboard.general.changeCount` every 3 seconds (wake coalescing tolerance: 1.5s):

| Change Type           | Behavior                                                              |
| --------------------- | --------------------------------------------------------------------- |
| Image (TIFF)          | Converts to PNG → sends via `ClipboardSender` to Android              |
| Plain text            | Wraps as `clipboard.txt` → sends via `ClipboardSender`                |
| Incoming Android text | Written to NSPasteboard; temp file deleted immediately, no disk trace |

---

<h2 align="center"> 🤖 Android Side </h2>

Android supports two modes:

### 🟢 Basic Mode (No Root Required)

Install the official [LocalSend](https://github.com/localsend/localsend/releases) to transfer files with Mac — best compatibility.

For normal home Wi-Fi and hotspots, this is also the recommended starting point.  
For campus or dorm networks where devices can be discovered but transfers are still unusable, official LocalSend alone is often not enough; that is where AirSend full mode and HTTP compatibility become relevant.

**Not included**: clipboard auto-sync, screenshot auto-push, Direct Share shortcuts.

### 🔴 Full Mode (Root + Magisk/KernelSU + LSPosed)

Installing the AirSend custom App gives you three components:

---

### ① Kotlin Foreground Service (AirSendService)

Auto-starts via `BootReceiver`, runs as a `dataSync` foreground service (Android 14+ compatible), `START_STICKY` keep-alive. Polls the Rust daemon every 30 seconds for a device list; only updates Direct Share shortcuts when the list actually changes (avoiding pointless Binder calls).

---

### ② Rust Daemon (Magisk/KernelSU Module)

Starts with the system as a Magisk module, fully independent of the App lifecycle:

| Responsibility        | Implementation                                                    |
| --------------------- | ----------------------------------------------------------------- |
| Screenshot monitoring | `inotify` on two screenshot dirs, 1s Page Cache delay before push |
| Device discovery      | LocalSend UDP broadcast, maintains online device table            |
| IPC bus               | Two Unix domain sockets: `@airsend_ipc` / `@airsend_app_ipc`      |
| Transport resilience  | HTTPS by default, HTTP compatibility on difficult LANs, rebinding on interface change |
| Proxy bypass          | Forces `NO_PROXY=*` at startup                                    |

Monitored screenshot paths:
- `/data/media/0/Pictures/Screenshots` (AOSP native)
- `/data/media/0/DCIM/Screenshots` (MIUI / HyperOS / ColorOS, etc.)

---

### ③ LSPosed Module (Xposed)

Runs in `system_server`, hooks `ClipboardService$ClipboardImpl.setPrimaryClip`:

| Direction     | Mechanism                                                             |
| ------------- | --------------------------------------------------------------------- |
| Android → Mac | Intercepts copy event → sends via UDS to daemon → HTTPS push to Mac   |
| Mac → Android | Listens on `@airsend_app_ipc`, writes to system clipboard as UID 1000 |
| Anti-loop     | `isWritingFromSync` volatile flag, released after 500ms               |

---

<h2 align="center"> 🚀 Quick Start </h2>

### 💻 Step 1: macOS Setup

1. Download the latest `AirSend.app` from [Releases](https://github.com/Avi7ii/AirSend/releases/latest)
2. Drag it into `/Applications` and launch it
3. Right-click the menu bar icon → **"Launch at Login"** → enable

### 🤖 Step 2: Android Setup

**Basic Mode (recommended for non-root users)**

Install the official [LocalSend](https://github.com/localsend/localsend/releases). Both devices on the same Wi-Fi and you're ready to transfer files.

If you are testing on a campus or dorm LAN and the devices can see each other but transfers freeze, do not stop at basic mode. Use the full AirSend mode below and manually enable `Advanced -> Compatibility Mode (HTTP)` on Mac.

**Full Mode (root users)**

1. Download the latest Magisk module from [Releases](https://github.com/Avi7ii/AirSend/releases/latest)
2. Flash the module in **Magisk / KernelSU**, then **reboot**
3. Enable the AirSend module in **LSPosed**, scope set to **Android System and System Framework**, then **reboot**

After setup, clipboard sync, screenshot auto-send, and Direct Share shortcuts all work automatically.

---

<h2 align="center"> ❓ FAQ </h2>

**Q: Devices can't find each other?**

Confirm both devices are on the same Wi-Fi and that the router doesn't have "AP Isolation" or "Client Isolation" enabled (some routers enable this by default). Firewall must allow UDP 53317 and TCP 53317-53319. Also try clicking **Rescan and Refresh** in the Mac menu.

On large campus-style subnets, AirSend now first tries remembered-host recovery and then falls back to `/24` expansion probing, so the very first recovery can still take a while. Once the device is found again, later keepalive is much faster.

---

**Q: On campus Wi-Fi the devices can discover each other, but every transfer times out or feels unusable. What should I do?**

If mobile hotspot or home Wi-Fi works but the campus LAN does not, the problem is usually the campus data plane rather than the devices themselves.

- Home network / hotspot: keep the default HTTPS mode
- Campus / dorm LAN: use AirSend full mode and manually enable `Advanced -> Compatibility Mode (HTTP)` on macOS
- Official LocalSend: it currently **does not** provide this manual HTTP compatibility path

---

**Q: After switching to campus Wi-Fi, the phone is missing from the device list, or it appears once and disappears again. What should I do?**

AirSend 3.0.0 now has two recovery layers for this:

- first recovery by `/24` expansion across large subnets when multicast is suppressed
- later keepalive by remembering the last reachable device IP and re-probing it directly

So the first recovery may still take some time, but once the phone is found again the list should stay much more stable. If the campus network uses strict client isolation or fully blocks device-to-device traffic, that is beyond what local compatibility logic can fix.

---

**Q: What's the clipboard sync latency?**

Android → Mac: Xposed intercepts the copy event immediately, typically under 0.1 seconds.

Mac → Android: Mac polls every 3 seconds, typical latency under 2 seconds.

---

**Q: Can clipboard sync work without Root?**

No. Android 10+ explicitly prohibits background apps from reading the clipboard. Only an Xposed module running in `system_server` with UID 1000 can bypass this restriction.

---

**Q: Where are received files saved?**

- **Mac**: `~/Downloads` — file name conflicts auto-append a sequence number (e.g. `image (1).png`)
- **Android**: Photos → `~/Pictures/AirSend`, other files → `~/Downloads/AirSend`

---

**Q: Does screenshot auto-send require the App to be open?**

No. The Rust daemon runs as a Magisk module at the system level, independently of whether AirSend App is in the foreground.

---

**Q: Will Mac slow down when sending large files?**

No. `HTTPTransferServer` uses streaming I/O — data is written to disk chunk by chunk without accumulating in memory. Large file transfers have virtually no extra memory pressure.

---

<h2 align="center"> 🤝 Contributing & Feedback </h2>

Bug reports and PRs are welcome. If this tool is useful to you, giving it a 🌟 is the most direct way to support the project.

---

<p align="center">
  <b>AirSend</b> · <i>Simple is the new smart. AirDrop, but for everyone.</i>
</p>
