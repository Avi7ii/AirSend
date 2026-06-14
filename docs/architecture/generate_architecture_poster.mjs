import fs from "node:fs";
import path from "node:path";

const outDir = path.dirname(decodeURIComponent(new URL(import.meta.url).pathname));
const out = path.join(outDir, "airsend-engineering-architecture.svg");

const esc = (s) => String(s).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
const parts = [];
const add = (s) => parts.push(s);

function text(x, y, value, size = 22, fill = "#dce8ff", weight = 500, anchor = "start", opacity = 1) {
  add(`<text x="${x}" y="${y}" font-family="Inter,Arial,sans-serif" font-size="${size}" font-weight="${weight}" text-anchor="${anchor}" fill="${fill}" opacity="${opacity}">${esc(value)}</text>`);
}

function multiline(x, y, lines, size = 16, fill = "#9fb2d0", lineHeight = 21, weight = 450, anchor = "start") {
  add(`<text x="${x}" y="${y}" font-family="Inter,Arial,sans-serif" font-size="${size}" font-weight="${weight}" text-anchor="${anchor}" fill="${fill}">${lines.map((l, i) => `<tspan x="${x}" dy="${i ? lineHeight : 0}">${esc(l)}</tspan>`).join("")}</text>`);
}

function pill(x, y, w, label, color, fill = "#111a2c", size = 13) {
  add(`<rect x="${x}" y="${y}" width="${w}" height="29" rx="14.5" fill="${fill}" stroke="${color}" stroke-width="1.5"/>`);
  text(x + w / 2, y + 20, label, size, color, 700, "middle");
}

function moduleNode(x, y, w, h, title, lines, color, icon, accent = false) {
  add(`<g filter="url(#softShadow)">`);
  add(`<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${accent ? 22 : 14}" fill="${accent ? "#162440" : "#101a2d"}" stroke="${color}" stroke-width="${accent ? 2.6 : 1.5}"/>`);
  add(`<path d="M ${x + 14} ${y + h - 1} H ${x + w - 14}" stroke="${color}" stroke-width="${accent ? 4 : 2}" stroke-linecap="round" opacity=".85"/>`);
  add(`<circle cx="${x + 26}" cy="${y + 27}" r="14" fill="${color}" opacity=".18"/><text x="${x + 26}" y="${y + 33}" text-anchor="middle" font-size="16">${icon}</text>`);
  text(x + 50, y + 31, title, accent ? 17 : 15, "#f5f8ff", 750);
  multiline(x + 18, y + 58, lines, 12.5, "#9fb2d0", 17);
  add(`</g>`);
}

function smallNode(x, y, title, sub, color, icon) {
  add(`<g><circle cx="${x}" cy="${y}" r="28" fill="#101a2d" stroke="${color}" stroke-width="2"/><circle cx="${x}" cy="${y}" r="20" fill="${color}" opacity=".14"/><text x="${x}" y="${y + 7}" text-anchor="middle" font-size="19">${icon}</text>`);
  text(x, y + 48, title, 13, "#edf3ff", 720, "middle");
  text(x, y + 65, sub, 10.5, "#8295b4", 500, "middle");
  add(`</g>`);
}

function wire(d, color, width = 3, dash = "", opacity = 1, marker = true) {
  add(`<path d="${d}" fill="none" stroke="${color}" stroke-width="${width}" stroke-linecap="round" stroke-linejoin="round" ${dash ? `stroke-dasharray="${dash}"` : ""} opacity="${opacity}" ${marker ? `marker-end="url(#arrow-${color.slice(1)})"` : ""}/>`);
}

function junction(x, y, color, r = 6) {
  add(`<circle cx="${x}" cy="${y}" r="${r + 4}" fill="${color}" opacity=".12"/><circle cx="${x}" cy="${y}" r="${r}" fill="#0a1222" stroke="${color}" stroke-width="2"/>`);
}

add(`<?xml version="1.0" encoding="UTF-8"?>`);
add(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2400 1500" width="2400" height="1500">`);
add(`<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#07101f"/><stop offset=".52" stop-color="#0b1425"/><stop offset="1" stop-color="#071526"/></linearGradient>
  <radialGradient id="coreGlow"><stop offset="0" stop-color="#2b75ff" stop-opacity=".28"/><stop offset="1" stop-color="#2b75ff" stop-opacity="0"/></radialGradient>
  <pattern id="grid" width="34" height="34" patternUnits="userSpaceOnUse"><path d="M34 0H0V34" fill="none" stroke="#8aa4cc" stroke-opacity=".055" stroke-width="1"/></pattern>
  <filter id="softShadow" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#000814" flood-opacity=".48"/></filter>
  <filter id="glow"><feGaussianBlur stdDeviation="7" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
  ${["31c7d4","4f8cff","f3a629","ef5b5b","a06cff","35d07f"].map(c => `<marker id="arrow-${c}" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto"><path d="M0,0 L0,6 L8,3 z" fill="#${c}"/></marker>`).join("")}
</defs>`);
add(`<rect width="2400" height="1500" fill="url(#bg)"/><rect width="2400" height="1500" fill="url(#grid)"/>`);
add(`<circle cx="1200" cy="720" r="480" fill="url(#coreGlow)"/>`);

// Header
text(74, 72, "AirSend", 38, "#ffffff", 820);
text(74, 107, "LOW-LEVEL ENGINEERING ARCHITECTURE", 15, "#7f94b5", 700);
pill(1830, 54, 142, "Swift 6.2", "#4f8cff");
pill(1984, 54, 142, "Kotlin/JVM", "#35d07f");
pill(2138, 54, 180, "Rust + Tokio", "#f07947");
text(2320, 112, "v3.5 runtime map", 12, "#5f7394", 600, "end");

// Device silhouettes
add(`<g filter="url(#softShadow)"><rect x="64" y="155" width="710" height="1190" rx="44" fill="#0c1729" stroke="#4f8cff" stroke-width="2.5"/><rect x="88" y="190" width="662" height="1090" rx="28" fill="#0a1323" stroke="#274a80" stroke-width="1.5"/><path d="M250 1345 H590 L640 1390 H200 Z" fill="#0d192c" stroke="#4f8cff" stroke-width="2"/></g>`);
add(`<circle cx="420" cy="173" r="4" fill="#4f8cff"/><circle cx="438" cy="173" r="4" fill="#35d07f"/>`);
text(106, 235, "macOS NATIVE HUB", 20, "#8fb7ff", 800);
text(106, 264, "single Swift/AppKit process · @MainActor orchestration", 12, "#6883ab", 550);

add(`<g filter="url(#softShadow)"><rect x="1626" y="145" width="710" height="1210" rx="64" fill="#0b1827" stroke="#35d07f" stroke-width="2.5"/><rect x="1655" y="190" width="652" height="1105" rx="42" fill="#091421" stroke="#1e6549" stroke-width="1.5"/><rect x="1880" y="164" width="202" height="9" rx="5" fill="#17392f"/></g>`);
text(1680, 235, "ANDROID PRIVILEGED RUNTIME", 20, "#75e3ad", 800);
text(1680, 264, "App process + system_server + root native daemon", 12, "#6f9f8b", 550);

// macOS islands
text(106, 315, "EXPERIENCE + ORCHESTRATION", 12, "#567fbf", 800);
moduleNode(106, 342, 194, 118, "AppDelegate", ["lifecycle · registry", "selection · restart"], "#4f8cff", "⌘");
moduleNode(321, 342, 194, 118, "Menu + DropZone", ["NSStatusItem", "drag · progress"], "#4f8cff", "⇩");
moduleNode(536, 342, 194, 118, "SwiftUI Settings", ["compatibility mode", "sync · launch"], "#4f8cff", "⚙");

text(106, 505, "CONCURRENT DATA SERVICES", 12, "#567fbf", 800);
moduleNode(106, 532, 194, 130, "ClipboardService", ["NSPasteboard poll", "TIFF → PNG", "anti-echo"], "#6da3ff", "▣");
moduleNode(321, 532, 194, 130, "FileSender actor", ["prepare-upload", "stream · cancel", "directory zip"], "#6da3ff", "⇧", true);
moduleNode(536, 532, 194, 130, "ClipboardSender", ["clipboard.txt / PNG", "scheme preflight", "bounded retry"], "#6da3ff", "↗");
moduleNode(106, 686, 260, 130, "HTTPTransferServer actor", ["register · prepare · upload", "streaming sink · cancel", "conflict-safe rename"], "#4f8cff", "⇣", true);
moduleNode(390, 686, 340, 130, "Session / Security", ["URLSession + curl transport fallback", "TLS fingerprint challenge", "X.509 P12 identity"], "#4f8cff", "⌁");

text(106, 860, "NETWORK ENGINES", 12, "#567fbf", 800);
smallNode(160, 925, "Discovery", "NWConnectionGroup", "#31c7d4", "◉");
smallNode(300, 925, "/24 Probe", "known-host reprobe", "#31c7d4", "⌖");
smallNode(440, 925, "TLS Listener", "NWListener :53318", "#4f8cff", "◆");
smallNode(580, 925, "HTTP Compat", "BSD socket :53318", "#f3a629", "◇");
smallNode(690, 925, "UDP Fallback", "≤1 MiB windows", "#ef5b5b", "⟲");

text(106, 1038, "NATIVE FACILITIES", 12, "#567fbf", 800);
pill(106, 1060, 155, "NSPasteboard", "#7c91b3");
pill(274, 1060, 155, "FileManager", "#7c91b3");
pill(442, 1060, 155, "SMAppService", "#7c91b3");
pill(610, 1060, 120, "OpenSSL", "#7c91b3");
multiline(106, 1135, ["Device registry: grouped identities · remembered hosts · last-seen retention", "Transport policy: HTTPS default · explicit HTTP mode · no silent downgrade", "Resilience: streaming writes · cancellation cleanup · rotating logs"], 13, "#7185a6", 24);

// Android process slabs
add(`<path d="M1680 310 H2282" stroke="#35d07f" stroke-width="1.5" opacity=".45"/>`);
pill(1680, 292, 180, "APP PROCESS", "#35d07f", "#0d2130");
moduleNode(1680, 342, 185, 118, "AirSendService", ["START_STICKY", "GET_PEERS / 30s"], "#35d07f", "☰");
moduleNode(1885, 342, 185, 118, "Direct Share", ["ShortcutManager", "ShareTargetActivity"], "#35d07f", "↗", true);
moduleNode(2090, 342, 185, 118, "URI + Commands", ["PathUtils", "JSON IPC encoder"], "#35d07f", "⌘");

add(`<path d="M1680 500 H2282" stroke="#a06cff" stroke-width="1.5" opacity=".45"/>`);
pill(1680, 482, 230, "system_server · UID 1000", "#a06cff", "#17142d");
moduleNode(1680, 532, 185, 126, "ClipboardHook", ["Xposed API 82", "setPrimaryClip hook"], "#a06cff", "✦", true);
moduleNode(1885, 532, 185, 126, "Loop Guard", ["volatile write lock", "500ms release"], "#a06cff", "∞");
moduleNode(2090, 532, 185, 126, "Reverse IPC", ["@airsend_app_ipc", "force clipboard write"], "#a06cff", "⇣");
wire("M 1772 675 C 1772 710, 2182 710, 2182 675", "#a06cff", 2.5, "7 7", .9, false);
text(1977, 705, "abstract UDS IPC · system context write", 11, "#b999ed", 650, "middle");

add(`<path d="M1680 748 H2282" stroke="#f07947" stroke-width="1.5" opacity=".45"/>`);
pill(1680, 730, 255, "ROOT DAEMON · arm64-v8a", "#f07947", "#25172a");
moduleNode(1680, 780, 185, 130, "Tokio Supervisor", ["resilient init", "network rebind", "self restart"], "#f07947", "◎");
moduleNode(1885, 780, 185, 130, "UDS Broker", ["@airsend_ipc", "preferred target", "JSON commands"], "#f07947", "⇄", true);
moduleNode(2090, 780, 185, 130, "inotify Watcher", ["CLOSE_WRITE", "rename · 1s settle", "screenshots"], "#f07947", "◌");

text(1680, 965, "PATCHED LOCALSEND RUST CORE 0.2.2", 12, "#b86a4c", 800);
smallNode(1735, 1030, "Discovery", "Tokio UdpSocket", "#31c7d4", "◉");
smallNode(1870, 1030, "Axum", "HTTP / rustls", "#4f8cff", "⬡");
smallNode(2005, 1030, "Reqwest", "prepare / upload", "#4f8cff", "↗");
smallNode(2140, 1030, "Sessions", "tokens · routing", "#f07947", "⌘");
smallNode(2250, 1030, "Fallback", "window state", "#ef5b5b", "⟲");
multiline(1680, 1135, ["TLS: RSA-2048 · SHA-256 fingerprint · /data/adb/airsend", "Storage: Downloads / Pictures · auto rename · MediaScanner broadcast", "Network: interface detection · system route · neighbor pinning"], 13, "#789a8c", 24);

// Central protocol core, not a column of boxes.
add(`<g filter="url(#glow)"><circle cx="1200" cy="710" r="250" fill="#0b172b" stroke="#315f9f" stroke-width="2"/><circle cx="1200" cy="710" r="205" fill="#0d1b31" stroke="#31c7d4" stroke-width="1.5" stroke-dasharray="7 10" opacity=".8"/><circle cx="1200" cy="710" r="158" fill="#101e35" stroke="#4f8cff" stroke-width="2.5"/><circle cx="1200" cy="710" r="108" fill="#142746" stroke="#f3a629" stroke-width="2"/></g>`);
text(1200, 675, "AirSend", 30, "#ffffff", 820, "middle");
text(1200, 707, "RUNTIME CORE", 15, "#83a6dc", 750, "middle");
text(1200, 744, "register · info · prepare", 12, "#d1ddf1", 600, "middle");
text(1200, 765, "upload · cancel", 12, "#d1ddf1", 600, "middle");

// Orbit labels
pill(1080, 414, 240, "DISCOVERY PLANE · UDP 53317", "#31c7d4", "#0b1929");
pill(1035, 972, 330, "RECOVERY PLANE · PREFLIGHT + FALLBACK", "#ef5b5b", "#1c1425");
pill(1030, 835, 340, "LOCALSEND-COMPATIBLE HTTP API", "#4f8cff", "#101a30");

smallNode(1015, 570, "Announce", "multicast/broadcast", "#31c7d4", "◉");
smallNode(1385, 570, "Register", "identity + fingerprint", "#31c7d4", "⌁");
smallNode(1015, 845, "HTTPS", "default secure path", "#4f8cff", "◆");
smallNode(1385, 845, "HTTP", "manual compatibility", "#f3a629", "◇");
smallNode(1200, 1055, "UDP Windows", "600 B × 24 · ≤1 MiB", "#ef5b5b", "⟲");

// Main cable trunks with dedicated lanes.
wire("M 720 925 C 850 925, 865 570, 987 570", "#31c7d4", 3.5, "9 8");
wire("M 1413 570 C 1530 570, 1545 1030, 1707 1030", "#31c7d4", 3.5, "9 8");
junction(850, 925, "#31c7d4"); junction(1550, 1030, "#31c7d4");

wire("M 730 605 C 850 605, 875 845, 987 845", "#4f8cff", 4);
wire("M 1043 845 C 1100 845, 1100 810, 1120 790", "#4f8cff", 4);
wire("M 1280 790 C 1320 810, 1320 845, 1357 845", "#4f8cff", 4);
wire("M 1413 845 C 1535 845, 1550 1030, 1842 1030", "#4f8cff", 4);
junction(850, 605, "#4f8cff"); junction(1550, 1030, "#4f8cff");

wire("M 580 925 C 800 925, 850 900, 850 875 C 850 820, 1000 800, 1120 760", "#f3a629", 3.2, "10 8");
wire("M 1280 760 C 1460 790, 1510 845, 1357 845", "#f3a629", 3.2, "10 8");

wire("M 690 925 C 840 1080, 980 1055, 1172 1055", "#ef5b5b", 3.2, "3 8");
wire("M 1228 1055 C 1460 1055, 1550 1050, 2222 1030", "#ef5b5b", 3.2, "3 8");
junction(900, 1055, "#ef5b5b"); junction(1550, 1050, "#ef5b5b");

// Android IPC wiring, kept inside the phone.
wire("M 2182 460 C 2182 490, 1977 490, 1977 780", "#a06cff", 2.7, "7 7");
wire("M 1772 658 C 1645 658, 1645 845, 1885 845", "#a06cff", 2.7, "7 7");
wire("M 1977 910 C 1977 940, 2140 940, 2140 1002", "#a06cff", 2.7, "7 7");

// Flow labels and protocol facts
pill(800, 546, 170, "announce / probe", "#31c7d4");
pill(1430, 546, 168, "peer registration", "#31c7d4");
pill(795, 650, 185, "Swift sender / receiver", "#4f8cff");
pill(1420, 790, 175, "Rust client / server", "#4f8cff");
pill(820, 1034, 210, "ACK / NACK retransmit", "#ef5b5b");
pill(1370, 1034, 220, "nonce + source binding", "#ef5b5b");

// Bottom operational strip
add(`<path d="M75 1360 H2325" stroke="#243b5f" stroke-width="1.5"/>`);
text(75, 1405, "OPERATING CONSTRAINTS", 12, "#607ba6", 800);
pill(260, 1384, 250, "HTTPS stays default", "#4f8cff");
pill(530, 1384, 290, "HTTP requires explicit mode", "#f3a629");
pill(840, 1384, 300, "fallback payload ≤ 1 MiB", "#ef5b5b");
pill(1160, 1384, 280, "AP isolation must be off", "#31c7d4");
pill(1460, 1384, 320, "Root + Magisk/KernelSU + LSPosed", "#a06cff");
pill(1800, 1384, 270, "two abstract UDS buses", "#a06cff");
pill(2090, 1384, 230, "streaming file I/O", "#35d07f");

text(75, 1470, "Color key", 12, "#607ba6", 750);
pill(155, 1449, 190, "Discovery", "#31c7d4");
pill(360, 1449, 190, "HTTPS data", "#4f8cff");
pill(565, 1449, 190, "HTTP compat", "#f3a629");
pill(770, 1449, 190, "UDP fallback", "#ef5b5b");
pill(975, 1449, 190, "Android IPC", "#a06cff");
text(2320, 1470, "source of truth: repository code", 11, "#536b8d", 600, "end");

add(`</svg>`);
fs.writeFileSync(out, parts.join("\n"));
console.log(out);
