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
function multiline(x, y, lines, size = 16, fill = "#afbdd3", lineHeight = 21, weight = 450, anchor = "start") {
  add(`<text x="${x}" y="${y}" font-family="Inter,Arial,sans-serif" font-size="${size}" font-weight="${weight}" text-anchor="${anchor}" fill="${fill}">${lines.map((l, i) => `<tspan x="${x}" dy="${i ? lineHeight : 0}">${esc(l)}</tspan>`).join("")}</text>`);
}
function pill(x, y, w, label, color, fill = "#111a2c", size = 13) {
  add(`<rect x="${x}" y="${y}" width="${w}" height="29" rx="7" fill="${fill}" stroke="${color}" stroke-width="1.35"/>`);
  text(x + w / 2, y + 20, label, size, color, 700, "middle");
}
function moduleNode(x, y, w, h, title, lines, color, icon, accent = false) {
  add(`<g filter="url(#softShadow)"><rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${accent ? 14 : 8}" fill="${accent ? "#162440" : "#101a2d"}" stroke="${color}" stroke-width="${accent ? 2.4 : 1.35}"/>`);
  add(`<path d="M ${x + 12} ${y + h - 1} H ${x + w - 12}" stroke="${color}" stroke-width="${accent ? 3 : 1.5}" opacity=".8"/>`);
  add(`<circle cx="${x + 26}" cy="${y + 27}" r="13" fill="${color}" opacity=".16"/><text x="${x + 26}" y="${y + 33}" text-anchor="middle" font-size="15">${icon}</text>`);
  text(x + 50, y + 31, title, accent ? 17 : 15, "#f5f8ff", 750);
  multiline(x + 18, y + 58, lines, 12.5, "#9fb2d0", 17);
  add(`</g>`);
}
function smallNode(x, y, title, sub, color, icon) {
  add(`<g><circle cx="${x}" cy="${y}" r="27" fill="#101a2d" stroke="${color}" stroke-width="2"/><circle cx="${x}" cy="${y}" r="18" fill="${color}" opacity=".12"/><text x="${x}" y="${y + 7}" text-anchor="middle" font-size="18">${icon}</text>`);
  text(x, y + 47, title, 13, "#edf3ff", 720, "middle");
  text(x, y + 64, sub, 10.5, "#a3b3cc", 500, "middle");
  add(`</g>`);
}
function wire(d, color, width = 3, dash = "", opacity = 1, marker = true) {
  add(`<path d="${d}" fill="none" stroke="#07101f" stroke-width="${width + 4}" stroke-linecap="round" stroke-linejoin="round" opacity=".9"/>`);
  add(`<path d="${d}" fill="none" stroke="${color}" stroke-width="${width}" stroke-linecap="round" stroke-linejoin="round" ${dash ? `stroke-dasharray="${dash}"` : ""} opacity="${opacity}" ${marker ? `marker-end="url(#arrow-${color.slice(1)})"` : ""}/>`);
}
function junction(x, y, color, r = 6) {
  add(`<circle cx="${x}" cy="${y}" r="${r + 4}" fill="#07101f"/><circle cx="${x}" cy="${y}" r="${r}" fill="#0a1222" stroke="${color}" stroke-width="2"/>`);
}
function note(x, y, n, title, detail, color) {
  add(`<circle cx="${x}" cy="${y}" r="15" fill="#0a1222" stroke="${color}" stroke-width="1.7"/>`);
  text(x, y + 5, n, 11, color, 800, "middle");
  text(x + 25, y + 2, title, 12, "#e8effc", 700);
  text(x + 25, y + 18, detail, 10.5, "#92a6c5", 500);
}

add(`<?xml version="1.0" encoding="UTF-8"?>`);
add(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2400 1500" width="2400" height="1500"><defs>
  <filter id="softShadow" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="5" stdDeviation="6" flood-color="#000814" flood-opacity=".4"/></filter>
  ${["31c7d4","4f8cff","f3a629","ef5b5b","a06cff","35d07f"].map(c => `<marker id="arrow-${c}" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto"><path d="M0,0 L0,6 L8,3 z" fill="#${c}"/></marker>`).join("")}
</defs>`);

text(74, 72, "AirSend", 38, "#ffffff", 820); text(74, 107, "LOW-LEVEL ENGINEERING ARCHITECTURE", 15, "#a8b8d0", 700);
pill(1830, 54, 142, "Swift 6.2", "#4f8cff"); pill(1984, 54, 142, "Kotlin/JVM", "#35d07f"); pill(2138, 54, 180, "Rust + Tokio", "#f07947");
text(2320, 112, "repository-derived runtime map", 12, "#91a4c2", 600, "end");

// Platform silhouettes
add(`<g filter="url(#softShadow)"><rect x="64" y="155" width="710" height="1190" rx="36" fill="#0c1729" stroke="#4f8cff" stroke-width="2.2"/><rect x="88" y="190" width="662" height="1090" rx="20" fill="#0a1323" stroke="#274a80" stroke-width="1.3"/></g>`);
text(106, 235, "macOS NATIVE HUB", 20, "#8fb7ff", 800); text(106, 264, "single Swift/AppKit process · @MainActor orchestration", 12, "#89a6d2", 550);
add(`<g filter="url(#softShadow)"><rect x="1626" y="145" width="710" height="1210" rx="46" fill="#0b1827" stroke="#35d07f" stroke-width="2.2"/><rect x="1655" y="190" width="652" height="1105" rx="28" fill="#091421" stroke="#1e6549" stroke-width="1.3"/></g>`);
text(1680, 235, "ANDROID PRIVILEGED RUNTIME", 20, "#75e3ad", 800); text(1680, 264, "app process + system_server + root native daemon", 12, "#8bb7a3", 550);

// macOS runtime
text(106, 315, "EXPERIENCE + ORCHESTRATION", 12, "#567fbf", 800);
moduleNode(106,342,194,118,"AppDelegate",["lifecycle · registry","selection · restart"],"#4f8cff","⌘");
moduleNode(321,342,194,118,"Menu + DropZone",["NSStatusItem","drag · progress"],"#4f8cff","⇩");
moduleNode(536,342,194,118,"SwiftUI Settings",["compatibility mode","sync · launch"],"#4f8cff","⚙");
text(106,505,"CONCURRENT DATA SERVICES",12,"#567fbf",800);
moduleNode(106,532,194,130,"ClipboardService",["NSPasteboard poll","TIFF → PNG","anti-echo"],"#6da3ff","▣");
moduleNode(321,532,194,130,"FileSender actor",["prepare-upload","stream · cancel","directory zip"],"#6da3ff","⇧",true);
moduleNode(536,532,194,130,"ClipboardSender",["clipboard.txt / PNG","scheme preflight","bounded retry"],"#6da3ff","↗");
moduleNode(106,686,260,130,"HTTPTransferServer actor",["register · prepare · upload","streaming sink · cancel","conflict-safe rename"],"#4f8cff","⇣",true);
moduleNode(390,686,340,130,"Session / Security",["URLSession + curl transport fallback","TLS fingerprint challenge","X.509 P12 identity"],"#4f8cff","⌁");
text(106,860,"NETWORK ENGINES",12,"#567fbf",800);
smallNode(160,925,"Discovery","NWConnectionGroup","#31c7d4","◉"); smallNode(300,925,"/24 Probe","known-host reprobe","#31c7d4","⌖");
smallNode(440,925,"TLS Listener","NWListener :53318","#4f8cff","◆"); smallNode(580,925,"HTTP Compat","BSD socket :53318","#f3a629","◇"); smallNode(690,925,"UDP Fallback","≤1 MiB windows","#ef5b5b","⟲");
text(106,1038,"NATIVE FACILITIES",12,"#567fbf",800);
pill(106,1060,155,"NSPasteboard","#7c91b3"); pill(274,1060,155,"FileManager","#7c91b3"); pill(442,1060,155,"SMAppService","#7c91b3"); pill(610,1060,120,"OpenSSL","#7c91b3");
multiline(106,1135,["Device registry: grouped identities · remembered hosts · last-seen retention","Transport policy: HTTPS default · explicit HTTP mode · no silent downgrade","Resilience: streaming writes · cancellation cleanup · rotating logs"],13,"#92a6c5",24);

// Android runtime
add(`<path d="M1680 310 H2282" stroke="#35d07f" stroke-width="1.3" opacity=".4"/>`); pill(1680,292,180,"APP PROCESS","#35d07f","#0d2130");
moduleNode(1680,342,185,118,"AirSendService",["START_STICKY","GET_PEERS / 30s"],"#35d07f","☰");
moduleNode(1885,342,185,118,"Direct Share",["ShortcutManager","ShareTargetActivity"],"#35d07f","↗",true);
moduleNode(2090,342,185,118,"URI + Commands",["PathUtils","JSON IPC encoder"],"#35d07f","⌘");
add(`<path d="M1680 500 H2282" stroke="#a06cff" stroke-width="1.3" opacity=".4"/>`); pill(1680,482,230,"system_server · UID 1000","#a06cff","#17142d");
moduleNode(1680,532,185,126,"ClipboardHook",["Xposed API 82","setPrimaryClip hook"],"#a06cff","✦",true);
moduleNode(1885,532,185,126,"Loop Guard",["volatile write lock","500ms release"],"#a06cff","∞");
moduleNode(2090,532,185,126,"Reverse IPC",["@airsend_app_ipc","force clipboard write"],"#a06cff","⇣");
add(`<path d="M1680 748 H2282" stroke="#f07947" stroke-width="1.3" opacity=".4"/>`); pill(1680,730,255,"ROOT DAEMON · arm64-v8a","#f07947","#25172a");
moduleNode(1680,780,185,130,"Tokio Supervisor",["resilient init","network rebind","self restart"],"#f07947","◎");
moduleNode(1885,780,185,130,"UDS Broker",["@airsend_ipc","preferred target","JSON commands"],"#f07947","⇄",true);
moduleNode(2090,780,185,130,"inotify Watcher",["CLOSE_WRITE","rename · 1s settle","screenshots"],"#f07947","◌");
text(1680,965,"AIRSEND RUST TRANSFER ENGINE",12,"#b86a4c",800);
smallNode(1735,1030,"Discovery","Tokio UdpSocket","#31c7d4","◉"); smallNode(1870,1030,"Axum","HTTP / rustls","#4f8cff","⬡"); smallNode(2005,1030,"Reqwest","prepare / upload","#4f8cff","↗");
smallNode(2140,1030,"Sessions","tokens · routing","#f07947","⌘"); smallNode(2250,1030,"Fallback","window state","#ef5b5b","⟲");
multiline(1680,1135,["TLS: RSA-2048 · SHA-256 fingerprint · /data/adb/airsend","Storage: Downloads / Pictures · auto rename · MediaScanner broadcast","Network: interface detection · system route · neighbor pinning"],13,"#91b5a3",24);

// Central protocol core. Rings encode planes; no decorative glow filter.
add(`<circle cx="1200" cy="710" r="250" fill="#0b172b" stroke="#315f9f" stroke-width="2"/><circle cx="1200" cy="710" r="205" fill="#0d1b31" stroke="#31c7d4" stroke-width="1.5" stroke-dasharray="7 10" opacity=".8"/><circle cx="1200" cy="710" r="158" fill="#101e35" stroke="#4f8cff" stroke-width="2.5"/><circle cx="1200" cy="710" r="108" fill="#142746" stroke="#f3a629" stroke-width="2"/>`);
text(1200,675,"AirSend",30,"#ffffff",820,"middle"); text(1200,707,"RUNTIME CORE",15,"#83a6dc",750,"middle");
text(1200,744,"register · info · prepare",12,"#d1ddf1",600,"middle"); text(1200,765,"upload · cancel",12,"#d1ddf1",600,"middle");
pill(1080,414,240,"DISCOVERY PLANE · UDP 53317","#31c7d4","#0b1929");
pill(1025,842,350,"LOCALSEND-COMPATIBLE HTTP API","#4f8cff","#101a30");
pill(1035,972,330,"RECOVERY PLANE · PREFLIGHT + FALLBACK","#ef5b5b","#1c1425");
smallNode(1015,570,"Announce","multicast/broadcast","#31c7d4","◉"); smallNode(1385,570,"Register","identity + fingerprint","#31c7d4","⌁");
smallNode(1015,845,"HTTPS","default secure path","#4f8cff","◆"); smallNode(1385,845,"HTTP","manual compatibility","#f3a629","◇"); smallNode(1200,1055,"UDP Windows","600 B × 24 · ≤1 MiB","#ef5b5b","⟲");

// Dedicated cable lanes. Every crossing has a dark underlay and every path terminates outside node labels.
wire("M 720 925 H 790 V 570 H 987","#31c7d4",3.5,"9 8"); wire("M 1413 570 H 1570 V 1030 H 1707","#31c7d4",3.5,"9 8");
junction(790,925,"#31c7d4"); junction(1570,1030,"#31c7d4");
wire("M 730 605 H 820 V 845 H 987","#4f8cff",4); wire("M 1043 845 H 1090 Q 1120 845 1128 802","#4f8cff",4);
wire("M 1272 802 Q 1280 845 1310 845 H 1357","#4f8cff",4); wire("M 1413 845 H 1588 V 1030 H 1842","#4f8cff",4);
junction(820,605,"#4f8cff"); junction(1588,1030,"#4f8cff");
wire("M 580 925 H 770 V 875 H 1120","#f3a629",3.2,"10 8"); wire("M 1280 760 H 1510 V 845 H 1357","#f3a629",3.2,"10 8");
wire("M 690 925 H 805 V 1055 H 1172","#ef5b5b",3.2,"3 8"); wire("M 1228 1055 H 1598 V 1030 H 2222","#ef5b5b",3.2,"3 8");
junction(805,1055,"#ef5b5b"); junction(1598,1055,"#ef5b5b");

// Android IPC stays in right-side routing gutters.
wire("M 2182 460 V 492 H 2290 V 720 H 1977 V 780","#a06cff",2.7,"7 7");
wire("M 1772 658 H 1644 V 845 H 1885","#a06cff",2.7,"7 7");
wire("M 1977 910 V 940 H 2140 V 1002","#a06cff",2.7,"7 7");
text(2268,704,"abstract UDS · reverse system write",10.5,"#b999ed",650,"end");

// Small numbered engineering annotations replace floating flow pills.
note(800,548,"01","discovery lane","announce · /24 probe · register","#31c7d4");
note(800,650,"02","data-plane entry","Swift sender / receiver","#4f8cff");
note(1435,548,"03","identity commit","fingerprint + reachable address","#31c7d4");
note(1435,790,"04","transfer endpoint","Rust client / server","#4f8cff");
note(830,1038,"05","bounded retransmit","ACK/NACK · 24-chunk window","#ef5b5b");
note(1390,1038,"06","session binding","nonce + source address","#ef5b5b");

// Bottom operational ledger, kept rectangular and compact.
add(`<path d="M75 1360 H2325" stroke="#243b5f" stroke-width="1.5"/>`);
text(75,1405,"OPERATING CONSTRAINTS",12,"#8ca4ca",800);
pill(260,1384,250,"HTTPS stays default","#4f8cff"); pill(530,1384,290,"HTTP requires explicit mode","#f3a629"); pill(840,1384,300,"fallback payload ≤ 1 MiB","#ef5b5b");
pill(1160,1384,280,"AP isolation must be off","#31c7d4"); pill(1460,1384,320,"Root + Magisk/KernelSU + LSPosed","#a06cff"); pill(1800,1384,270,"two abstract UDS buses","#a06cff"); pill(2090,1384,230,"streaming file I/O","#35d07f");
text(75,1470,"Color key",12,"#8ca4ca",750); pill(155,1449,190,"Discovery","#31c7d4"); pill(360,1449,190,"HTTPS data","#4f8cff"); pill(565,1449,190,"HTTP compat","#f3a629"); pill(770,1449,190,"UDP fallback","#ef5b5b"); pill(975,1449,190,"Android IPC","#a06cff");
text(2320,1470,"source of truth: repository code",11,"#8aa0c2",600,"end");

add(`</svg>`);
fs.writeFileSync(out, parts.join("\n"));
console.log(out);
