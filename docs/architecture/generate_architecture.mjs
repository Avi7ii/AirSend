import fs from "node:fs";
import path from "node:path";

const outDir = path.dirname(decodeURIComponent(new URL(import.meta.url).pathname));
const output = path.join(outDir, "airsend-engineering-architecture.drawio");

const cells = [];
let sequence = 2;

const esc = (value) =>
  String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

const baseText =
  "html=1;whiteSpace=wrap;overflow=hidden;fontFamily=Helvetica;fontColor=#25324A;";
const sketch = "sketch=1;curveFitting=1;jiggle=1;";

function vertex(id, value, x, y, w, h, style, parent = "1") {
  cells.push(
    `<mxCell id="${id}" value="${esc(value)}" style="${style}" vertex="1" parent="${parent}"><mxGeometry x="${x}" y="${y}" width="${w}" height="${h}" as="geometry"/></mxCell>`,
  );
}

function edge(id, value, source, target, style, points = []) {
  const waypointXml = points.length
    ? `<Array as="points">${points.map(([x, y]) => `<mxPoint x="${x}" y="${y}"/>`).join("")}</Array>`
    : "";
  cells.push(
    `<mxCell id="${id}" value="${esc(value)}" style="${style}" edge="1" parent="1" source="${source}" target="${target}"><mxGeometry relative="1" as="geometry">${waypointXml}</mxGeometry></mxCell>`,
  );
}

const palette = {
  mac: "fillColor=#EAF3FF;strokeColor=#3B73C8;",
  macStrong: "fillColor=#D8E9FF;strokeColor=#245FAE;",
  lan: "fillColor=#FFF5D6;strokeColor=#C28A1A;",
  lanStrong: "fillColor=#FFE8A6;strokeColor=#A86E00;",
  android: "fillColor=#E8FFF2;strokeColor=#299865;",
  androidStrong: "fillColor=#D4F8E4;strokeColor=#17784B;",
  rust: "fillColor=#FFF0E8;strokeColor=#D36937;",
  rustStrong: "fillColor=#FFDFCF;strokeColor=#B64C1F;",
  xposed: "fillColor=#F4ECFF;strokeColor=#8757C9;",
  xposedStrong: "fillColor=#E6D7FF;strokeColor=#6B38AE;",
  neutral: "fillColor=#F5F6F8;strokeColor=#6C778D;",
  dark: "fillColor=#27324A;strokeColor=#27324A;fontColor=#FFFFFF;",
};

const container = (color) =>
  `${baseText}${sketch}${color}rounded=1;arcSize=14;strokeWidth=2;dashed=1;dashPattern=8 5;verticalAlign=top;align=left;spacingTop=12;spacingLeft=14;fontSize=17;fontStyle=1;`;
const group = (color) =>
  `${baseText}${sketch}${color}rounded=1;arcSize=12;strokeWidth=2;verticalAlign=top;align=left;spacingTop=10;spacingLeft=12;fontSize=14;fontStyle=1;`;
const node = (color) =>
  `${baseText}${sketch}${color}rounded=1;arcSize=16;strokeWidth=2;align=left;verticalAlign=middle;spacingLeft=10;spacingRight=8;fontSize=12;`;
const nodeCenter = (color) =>
  `${baseText}${sketch}${color}rounded=1;arcSize=16;strokeWidth=2;align=center;verticalAlign=middle;fontSize=12;`;
const pill = (color) =>
  `${baseText}${sketch}${color}rounded=1;arcSize=45;strokeWidth=2;align=center;verticalAlign=middle;fontSize=11;fontStyle=1;`;

const localEdge =
  `${baseText}${sketch}edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;strokeColor=#667085;strokeWidth=1.6;endArrow=block;endFill=1;fontSize=10;labelBackgroundColor=#FFFAF0;`;
const discoveryEdge =
  `${baseText}${sketch}edgeStyle=orthogonalEdgeStyle;rounded=1;strokeColor=#148A91;strokeWidth=2.4;dashed=1;dashPattern=4 4;endArrow=block;endFill=1;fontSize=10;fontColor=#08636A;labelBackgroundColor=#FFFAF0;`;
const httpsEdge =
  `${baseText}${sketch}edgeStyle=orthogonalEdgeStyle;rounded=1;strokeColor=#2563B8;strokeWidth=3;endArrow=block;endFill=1;fontSize=10;fontStyle=1;fontColor=#17467F;labelBackgroundColor=#FFFAF0;`;
const compatEdge =
  `${baseText}${sketch}edgeStyle=orthogonalEdgeStyle;rounded=1;strokeColor=#D48806;strokeWidth=2.7;dashed=1;dashPattern=8 5;endArrow=block;endFill=1;fontSize=10;fontStyle=1;fontColor=#8F5700;labelBackgroundColor=#FFFAF0;`;
const fallbackEdge =
  `${baseText}${sketch}edgeStyle=orthogonalEdgeStyle;rounded=1;strokeColor=#C2413B;strokeWidth=2.5;dashed=1;dashPattern=2 5;endArrow=block;endFill=1;fontSize=10;fontStyle=1;fontColor=#8F2723;labelBackgroundColor=#FFFAF0;`;
const ipcEdge =
  `${baseText}${sketch}edgeStyle=orthogonalEdgeStyle;rounded=1;strokeColor=#7C3EB4;strokeWidth=2.5;endArrow=block;endFill=1;fontSize=10;fontStyle=1;fontColor=#5B2789;labelBackgroundColor=#FFFAF0;`;

vertex(
  "title",
  "AirSend · Low-Level Engineering Architecture",
  40,
  24,
  2500,
  48,
  `${baseText}fillColor=none;strokeColor=none;fontSize=30;fontStyle=1;align=left;`,
);
vertex(
  "subtitle",
  "Swift/AppKit ↔ LocalSend LAN Protocol ↔ Kotlin + LSPosed + Rust/Tokio · editable draw.io sketch source",
  42,
  72,
  2300,
  30,
  `${baseText}fillColor=none;strokeColor=none;fontSize=13;fontColor=#64748B;align=left;`,
);

vertex("mac_boundary", "macOS PROCESS · Swift 6.2 / AppKit / Network.framework", 35, 120, 820, 1465, container(palette.mac));
vertex("lan_boundary", "LOCAL NETWORK · DISCOVERY / DATA / RECOVERY PLANES", 885, 120, 780, 1465, container(palette.lan));
vertex("android_boundary", "ANDROID · APP + system_server + ROOT DAEMON", 1695, 120, 850, 1465, container(palette.android));

vertex("mac_ui_group", "AppKit Orchestration · Main Process / @MainActor", 65, 170, 760, 315, group(palette.macStrong));
vertex("app_delegate", "<b>AppDelegate</b><br>lifecycle · device registry · selection · networking restart", 90, 220, 220, 78, node(palette.mac));
vertex("menu_ui", "<b>NSStatusItem + NSMenu</b><br>grouped peers · settings · mode toggles", 330, 220, 220, 78, node(palette.mac));
vertex("dropzone", "<b>DropZoneWindow</b><br>drag proximity · request UI · progress", 570, 220, 220, 78, node(palette.mac));
vertex("local_drag", "<b>LocalFileDrag</b><br>pasteboard inspection · staged payload", 90, 325, 220, 72, node(palette.mac));
vertex("device_state", "<b>Device Registry</b><br>known hosts · grouped identities · last-seen retention", 330, 325, 220, 72, node(palette.mac));
vertex("settings", "<b>SwiftUI Settings</b><br>compatibility · auto-sync · launch at login", 570, 325, 220, 72, node(palette.mac));
vertex("wakelock", "<b>IOPMAssertion</b> · transfer wakelock", 250, 420, 380, 38, pill(palette.neutral));

vertex("mac_service_group", "Actors & Data Services", 65, 510, 760, 285, group(palette.macStrong));
vertex("clipboard_service", "<b>ClipboardService</b><br>NSPasteboard changeCount · 3s poll · TIFF→PNG priority", 90, 560, 220, 78, node(palette.mac));
vertex("file_sender", "<b>FileSender actor</b><br>prepare-upload · chunk upload · progress · cancel · zip", 330, 560, 220, 78, node(palette.mac));
vertex("clip_sender", "<b>ClipboardSender actor</b><br>clipboard.txt / PNG · scheme preflight · retry", 570, 560, 220, 78, node(palette.mac));
vertex("http_server", "<b>HTTPTransferServer actor</b><br>register · prepare · streaming upload · cancel", 90, 675, 220, 78, node(palette.mac));
vertex("stream_sink", "<b>Streaming File Sink</b><br>Downloads · conflict rename · text interception", 330, 675, 220, 78, node(palette.mac));
vertex("session_delegate", "<b>URLSession + curl fallback</b><br>TLS fingerprint challenge · timeout cleanup", 570, 675, 220, 78, node(palette.mac));

vertex("mac_transport_group", "Transport, Discovery & Recovery", 65, 820, 760, 455, group(palette.macStrong));
vertex("udp_discovery", "<b>UDPDiscoveryService</b><br>NWConnectionGroup · multicast / broadcast", 90, 870, 220, 78, node(palette.mac));
vertex("subnet_probe", "<b>Discovery Recovery</b><br>/24 slice probes · remembered-host reprobe · curl probe", 330, 870, 220, 78, node(palette.mac));
vertex("nw_listener", "<b>NWListener TLS Server</b><br>Network.framework · HTTPS :53318", 570, 870, 220, 78, node(palette.mac));
vertex("plain_server", "<b>PlainHTTPCompatServer</b><br>BSD sockets · one request/connection · :53318", 90, 985, 220, 78, node(palette.mac));
vertex("campus_mac", "<b>CampusFallbackCoordinator</b><br>UDP windows · ACK/NACK · nonce/source binding · ≤1 MiB", 330, 985, 220, 78, node(palette.mac));
vertex("scheme_resolver", "<b>Data-plane Preflight</b><br>preferred scheme · reachability probe · no silent downgrade", 570, 985, 220, 78, node(palette.mac));
vertex("cert_manager", "<b>CertificateManager actor</b><br>self-signed X.509 · P12 · SHA-256 fingerprint", 90, 1100, 220, 78, node(palette.mac));
vertex("identity", "<b>LocalNetworkIdentity</b><br>hardware address · device identity", 330, 1100, 220, 78, node(palette.mac));
vertex("logger", "<b>Rotating FileLogger</b><br>version reset · migration · retention", 570, 1100, 220, 78, node(palette.mac));
vertex("mac_ports", "UDP 53317 · TCP 53318 · HTTPS default / HTTP manual compatibility", 155, 1205, 570, 40, pill(palette.macStrong));

vertex("mac_os_group", "macOS Native Facilities", 65, 1300, 760, 230, group(palette.neutral));
vertex("nspasteboard", "<b>NSPasteboard</b><br>text · TIFF image · anti-echo write", 100, 1360, 190, 72, node(palette.neutral));
vertex("downloads", "<b>FileManager / Downloads</b><br>streamed writes · collision-safe names", 320, 1360, 190, 72, node(palette.neutral));
vertex("smservice", "<b>SMAppService</b><br>launch at login", 540, 1360, 190, 72, node(palette.neutral));
vertex("github_api", "<b>GitHub API</b><br>release update check", 210, 1460, 190, 48, nodeCenter(palette.neutral));
vertex("openssl_cli", "<b>/usr/bin/openssl</b><br>certificate generation", 440, 1460, 190, 48, nodeCenter(palette.neutral));

vertex("discovery_plane", "DISCOVERY PLANE", 915, 175, 720, 350, group(palette.lanStrong));
vertex("multicast", "<b>224.0.0.167:53317 / UDP</b><br>LocalSend announce + peer presence", 950, 230, 300, 72, node(palette.lan));
vertex("broadcast", "<b>LAN Broadcast :53317</b><br>raw announcement fallback", 1280, 230, 300, 72, node(palette.lan));
vertex("active_probe", "<b>Active Discovery Recovery</b><br>/24 expansion · preferred host · ports 53318/53319/53317", 950, 335, 300, 82, node(palette.lan));
vertex("peer_register", "<b>Device Registration</b><br>alias · model · type · IP · port · protocol · fingerprint", 1280, 335, 300, 82, node(palette.lan));
vertex("neighbor_pin", "<b>Android Neighbor Pinning</b><br>su ip neigh replace · MAC-aware LAN stabilization", 1115, 445, 300, 48, nodeCenter(palette.lan));

vertex("data_plane", "LOCALSEND-COMPATIBLE HTTP API DATA PLANE", 915, 555, 720, 475, group(palette.lanStrong));
vertex("standard_https", "<b>STANDARD PATH · HTTPS</b><br>Mac :53318 ↔ Android :53319<br>TLS identity + fingerprint", 950, 610, 300, 88, node(palette.lan));
vertex("compat_http", "<b>MANUAL COMPAT PATH · HTTP</b><br>same LocalSend API · explicit mode<br>for policy-heavy LANs", 1280, 610, 300, 88, node(palette.lan));
vertex("api_routes", "<b>HTTP API Surface</b><br>/register · /info · /prepare-upload<br>/upload · /cancel", 950, 735, 300, 100, node(palette.lan));
vertex("session_tokens", "<b>Session State</b><br>sessionId · fileId · token · sender/receiver metadata", 1280, 735, 300, 100, node(palette.lan));
vertex("payloads", "<b>Payload Semantics</b><br>files · directories(zip) · clipboard.txt · PNG · screenshots", 950, 875, 300, 82, node(palette.lan));
vertex("streaming", "<b>Transfer Semantics</b><br>prepare handshake · chunked/streaming body · cancel · progress", 1280, 875, 300, 82, node(palette.lan));

vertex("recovery_plane", "RECOVERY & SECURITY PLANE", 915, 1060, 720, 470, group(palette.lanStrong));
vertex("preflight", "<b>Reachability Preflight</b><br>probe actual data plane before upload<br>scheme selection + bounded retry", 950, 1115, 300, 88, node(palette.lan));
vertex("no_downgrade", "<b>Downgrade Boundary</b><br>HTTPS remains default · HTTP requires user mode<br>fallback is not a large-file tunnel", 1280, 1115, 300, 88, node(palette.lan));
vertex("fallback_protocol", "<b>Campus UDP Fallback · ≤1 MiB</b><br>600-byte chunks · 24-chunk windows<br>ACK/NACK retransmit · 90s stale GC", 950, 1240, 300, 105, node(palette.lan));
vertex("binding", "<b>Packet Binding</b><br>targetId · senderId · sessionNonce · expected source IP", 1280, 1240, 300, 105, node(palette.lan));
vertex("lan_failure", "<b>Failure Modes Addressed</b><br>multicast suppression · stale routes · HTTPS stalls · interface rebinding", 1030, 1390, 470, 72, nodeCenter(palette.lan));
vertex("lan_ports", "Discovery UDP :53317 · Mac TCP :53318 · Android TCP :53319", 1030, 1480, 470, 36, pill(palette.lanStrong));

vertex("android_app_group", "Android App Process · Kotlin / JVM 17 / SDK 34", 1725, 170, 790, 355, group(palette.androidStrong));
vertex("boot_receiver", "<b>BootReceiver</b><br>foreground service startup", 1750, 225, 210, 70, node(palette.android));
vertex("foreground_service", "<b>AirSendService</b><br>START_STICKY · dataSync · GET_PEERS / 30s", 1980, 225, 230, 70, node(palette.android));
vertex("shortcut_manager", "<b>ShortcutManager</b><br>dynamic Direct Share peers", 2230, 225, 250, 70, node(palette.android));
vertex("share_target", "<b>ShareTargetActivity / GhostActivity</b><br>SEND text/file/multiple · silent routing", 1750, 330, 260, 82, node(palette.android));
vertex("path_utils", "<b>PathUtils</b><br>content URI → real/cache path", 2030, 330, 210, 82, node(palette.android));
vertex("ipc_encoder", "<b>IpcCommandEncoder</b><br>JSON GET_PEERS / SEND_TEXT / SEND_FILE", 2260, 330, 220, 82, node(palette.android));
vertex("app_uds", "abstract UDS client · @airsend_ipc", 1900, 445, 440, 42, pill(palette.xposed));

vertex("system_server_group", "system_server Process · LSPosed / Xposed API 82 / UID 1000", 1725, 555, 790, 340, group(palette.xposedStrong));
vertex("clipboard_hook", "<b>ClipboardHook</b><br>hook ClipboardService$ClipboardImpl.setPrimaryClip", 1750, 610, 240, 82, node(palette.xposed));
vertex("loop_guard", "<b>Anti-loop Guard</b><br>volatile isWritingFromSync · 500ms release", 2010, 610, 220, 82, node(palette.xposed));
vertex("reverse_ipc", "<b>Reverse IPC Server</b><br>LocalServerSocket @airsend_app_ipc", 2250, 610, 230, 82, node(palette.xposed));
vertex("system_context", "<b>ActivityThread System Context</b><br>ClipboardManager write under UID 1000", 1850, 735, 260, 82, node(palette.xposed));
vertex("system_clipboard", "<b>Android System Clipboard</b><br>background focus restriction bypass", 2140, 735, 260, 82, node(palette.xposed));
vertex("system_uds", "SEND_TEXT → @airsend_ipc · incoming text ← @airsend_app_ipc", 1860, 840, 520, 38, pill(palette.xposedStrong));

vertex("daemon_group", "Root Native Process · arm64-v8a · Rust 2021 / Tokio Multi-thread Runtime", 1725, 925, 790, 605, group(palette.rustStrong));
vertex("tokio_main", "<b>airsend_daemon main</b><br>proxy bypass · concurrent task supervisor · resilient init", 1750, 980, 230, 82, node(palette.rust));
vertex("uds_broker", "<b>Tokio UnixListener</b><br>@airsend_ipc · JSON command broker · preferred target", 2000, 980, 230, 82, node(palette.rust));
vertex("inotify", "<b>notify / inotify Watcher</b><br>CLOSE_WRITE + rename · screenshot dirs · 1s settle", 2250, 980, 230, 82, node(palette.rust));
vertex("network_rebind", "<b>Network Rebind Watcher</b><br>3s interface/IP detection · scheduled self-restart", 1750, 1095, 230, 82, node(palette.rust));
vertex("tls_android", "<b>OpenSSL TLS Identity</b><br>RSA-2048 · X.509 · SHA-256 fingerprint · /data/adb", 2000, 1095, 230, 82, node(palette.rust));
vertex("filesystem", "<b>Android File/Media Sink</b><br>Downloads/Pictures · rename · MediaScanner broadcast", 2250, 1095, 230, 82, node(palette.rust));

vertex("localsend_core", "Patched LocalSend Rust Core 0.2.2", 1750, 1210, 730, 280, group(palette.rustStrong));
vertex("rust_discovery", "<b>Discovery</b><br>Tokio UdpSocket · multicast/broadcast · peers · pinned neighbors", 1775, 1260, 210, 92, node(palette.rust));
vertex("rust_server", "<b>Axum / Hyper Server</b><br>plain HTTP or rustls HTTP/1.1 · request body ≤1 GiB", 2005, 1260, 210, 92, node(palette.rust));
vertex("rust_client", "<b>Reqwest Client</b><br>prepare/upload/cancel · no proxy · system route", 2235, 1260, 210, 92, node(palette.rust));
vertex("rust_sessions", "<b>Session + Token Map</b><br>auto-accept · text interception · file routing", 1775, 1380, 210, 78, node(palette.rust));
vertex("rust_campus", "<b>CampusFallbackState</b><br>window state · retransmit · source/nonce validation", 2005, 1380, 210, 78, node(palette.rust));
vertex("rust_tasks", "<b>Tokio Tasks</b><br>HTTP server · UDP listener · adaptive announcements", 2235, 1380, 210, 78, node(palette.rust));
vertex("android_ports", "UDP 53317 · TCP 53319 · abstract UDS @airsend_ipc + @airsend_app_ipc", 1810, 1500, 620, 38, pill(palette.rustStrong));

// Boundary gateways create explicit cable-management lanes. Cross-domain links
// terminate here instead of cutting through unrelated components.
vertex("mac_discovery_gw", "DISCOVERY<br>GATEWAY", 795, 330, 48, 105, nodeCenter("fillColor=#DDF7F8;strokeColor=#148A91;fontColor=#08636A;"));
vertex("mac_data_gw", "DATA<br>GATEWAY", 795, 710, 48, 105, nodeCenter("fillColor=#E6F0FF;strokeColor=#2563B8;fontColor=#17467F;"));
vertex("mac_recovery_gw", "RECOVERY<br>GATEWAY", 795, 1210, 48, 105, nodeCenter("fillColor=#FFE9E7;strokeColor=#C2413B;fontColor=#8F2723;"));
vertex("android_discovery_gw", "DISCOVERY<br>GATEWAY", 1707, 330, 48, 105, nodeCenter("fillColor=#DDF7F8;strokeColor=#148A91;fontColor=#08636A;"));
vertex("android_data_gw", "DATA<br>GATEWAY", 1707, 710, 48, 105, nodeCenter("fillColor=#E6F0FF;strokeColor=#2563B8;fontColor=#17467F;"));
vertex("android_recovery_gw", "RECOVERY<br>GATEWAY", 1707, 1210, 48, 105, nodeCenter("fillColor=#FFE9E7;strokeColor=#C2413B;fontColor=#8F2723;"));

// macOS execution chains. Waypoints keep arrows in the whitespace between rows.
edge(`e${sequence++}`, "", "app_delegate", "menu_ui", localEdge);
edge(`e${sequence++}`, "", "menu_ui", "dropzone", localEdge);
edge(`e${sequence++}`, "text / TIFF→PNG", "clipboard_service", "clip_sender", localEdge, [[200, 650], [680, 650]]);
edge(`e${sequence++}`, "incoming stream", "http_server", "stream_sink", localEdge);
edge(`e${sequence++}`, "host probes", "subnet_probe", "udp_discovery", localEdge);
edge(`e${sequence++}`, "fallback packets", "udp_discovery", "campus_mac", localEdge, [[200, 970], [440, 970]]);

// macOS gateway feeds use a dedicated right-edge vertical rail.
edge(`e${sequence++}`, "", "udp_discovery", "mac_discovery_gw", discoveryEdge, [[775, 910], [775, 382]]);
edge(`e${sequence++}`, "", "subnet_probe", "mac_discovery_gw", discoveryEdge, [[775, 910], [775, 382]]);
edge(`e${sequence++}`, "", "session_delegate", "mac_data_gw", httpsEdge, [[775, 714], [775, 762]]);
edge(`e${sequence++}`, "", "nw_listener", "mac_data_gw", httpsEdge, [[775, 910], [775, 762]]);
edge(`e${sequence++}`, "", "plain_server", "mac_data_gw", compatEdge, [[760, 1024], [760, 762]]);
edge(`e${sequence++}`, "", "scheme_resolver", "mac_recovery_gw", compatEdge, [[775, 1024], [775, 1262]]);
edge(`e${sequence++}`, "", "campus_mac", "mac_recovery_gw", fallbackEdge, [[760, 1024], [760, 1262]]);

// Android App and IPC chains.
edge(`e${sequence++}`, "", "boot_receiver", "foreground_service", localEdge);
edge(`e${sequence++}`, "dynamic peers", "foreground_service", "shortcut_manager", localEdge);
edge(`e${sequence++}`, "share intent", "shortcut_manager", "share_target", localEdge, [[2355, 315], [1880, 315]]);
edge(`e${sequence++}`, "", "share_target", "path_utils", localEdge);
edge(`e${sequence++}`, "", "path_utils", "ipc_encoder", localEdge);
edge(`e${sequence++}`, "GET_PEERS / SEND_*", "app_uds", "uds_broker", ipcEdge, [[2495, 466], [2495, 955], [2235, 955]]);
edge(`e${sequence++}`, "hook + guard", "clipboard_hook", "loop_guard", localEdge);
edge(`e${sequence++}`, "clipboard text", "clipboard_hook", "uds_broker", ipcEdge, [[1735, 650], [1735, 955], [2115, 955]]);
edge(`e${sequence++}`, "incoming text", "rust_sessions", "reverse_ipc", ipcEdge, [[2495, 1418], [2495, 650]]);
edge(`e${sequence++}`, "UID 1000 write", "reverse_ipc", "system_context", ipcEdge, [[2495, 715], [1980, 715]]);
edge(`e${sequence++}`, "", "system_context", "system_clipboard", localEdge);

// Root daemon execution chains.
edge(`e${sequence++}`, "commands", "uds_broker", "tokio_main", localEdge);
edge(`e${sequence++}`, "screenshot path", "inotify", "tokio_main", localEdge, [[2365, 1080], [1865, 1080]]);

// Android gateway feeds use a dedicated left-edge vertical rail.
edge(`e${sequence++}`, "", "rust_discovery", "android_discovery_gw", discoveryEdge, [[1720, 1305], [1720, 382]]);
edge(`e${sequence++}`, "", "rust_server", "android_data_gw", httpsEdge, [[2110, 1480], [1730, 1480], [1730, 762]]);
edge(`e${sequence++}`, "", "rust_client", "android_data_gw", httpsEdge, [[2340, 1480], [1740, 1480], [1740, 762]]);
edge(`e${sequence++}`, "", "rust_campus", "android_recovery_gw", fallbackEdge, [[1745, 1418], [1745, 1262]]);

// Cross-boundary trunk lines are short, aligned, and terminate at gateways.
edge(`e${sequence++}`, "UDP announce / probe / registration", "mac_discovery_gw", "active_probe", discoveryEdge, [[870, 382]]);
edge(`e${sequence++}`, "UDP announce / registration", "active_probe", "android_discovery_gw", discoveryEdge, [[1680, 382]]);
edge(`e${sequence++}`, "", "active_probe", "multicast", discoveryEdge);
edge(`e${sequence++}`, "", "active_probe", "broadcast", discoveryEdge);
edge(`e${sequence++}`, "", "active_probe", "peer_register", discoveryEdge);
edge(`e${sequence++}`, "", "peer_register", "neighbor_pin", discoveryEdge);

edge(`e${sequence++}`, "HTTPS / explicit HTTP", "mac_data_gw", "standard_https", httpsEdge, [[870, 762]]);
edge(`e${sequence++}`, "compatible HTTP API", "standard_https", "android_data_gw", httpsEdge, [[1680, 762]]);
edge(`e${sequence++}`, "", "standard_https", "api_routes", httpsEdge);
edge(`e${sequence++}`, "", "standard_https", "session_tokens", httpsEdge);
edge(`e${sequence++}`, "", "api_routes", "payloads", localEdge);
edge(`e${sequence++}`, "", "session_tokens", "streaming", localEdge);
edge(`e${sequence++}`, "manual mode", "compat_http", "standard_https", compatEdge);

edge(`e${sequence++}`, "preflight / bounded fallback", "mac_recovery_gw", "preflight", compatEdge, [[870, 1262]]);
edge(`e${sequence++}`, "bounded fallback", "fallback_protocol", "android_recovery_gw", fallbackEdge, [[1680, 1292]]);
edge(`e${sequence++}`, "", "preflight", "no_downgrade", compatEdge);
edge(`e${sequence++}`, "", "preflight", "fallback_protocol", fallbackEdge);
edge(`e${sequence++}`, "", "fallback_protocol", "binding", fallbackEdge);

// Legend
vertex("legend", "FLOW LEGEND", 35, 1615, 2510, 125, group(palette.neutral));
vertex("legend_discovery", "Discovery / registration", 90, 1665, 260, 42, pill("fillColor=#E5F7F7;strokeColor=#148A91;"));
vertex("legend_https", "Standard HTTPS data path", 390, 1665, 290, 42, pill("fillColor=#E6F0FF;strokeColor=#2563B8;"));
vertex("legend_compat", "Manual HTTP compatibility", 720, 1665, 300, 42, pill("fillColor=#FFF2D8;strokeColor=#D48806;"));
vertex("legend_fallback", "Campus UDP fallback ≤1 MiB", 1060, 1665, 310, 42, pill("fillColor=#FFE9E7;strokeColor=#C2413B;"));
vertex("legend_ipc", "Android abstract UDS IPC", 1410, 1665, 290, 42, pill("fillColor=#F2E8FF;strokeColor=#7C3EB4;"));
vertex("legend_local", "In-process / OS integration", 1740, 1665, 300, 42, pill(palette.neutral));
vertex("legend_source", "Source of truth: repository code · generated for developer-facing README", 2080, 1665, 410, 42, pill(palette.dark));

const xml = `<?xml version="1.0" encoding="UTF-8"?>
<mxfile host="Electron" modified="2026-06-14T00:00:00.000Z" agent="AirSend architecture generator" version="26.0.0">
  <diagram id="airsend-engineering" name="AirSend Engineering Architecture">
    <mxGraphModel dx="2600" dy="1800" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="2600" pageHeight="1800" math="0" shadow="0" background="#FFFAF0">
      <root>
        <mxCell id="0"/>
        <mxCell id="1" parent="0"/>
        ${cells.join("\n        ")}
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
`;

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(output, xml);
console.log(output);
