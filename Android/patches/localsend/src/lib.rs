pub mod campus_fallback;
pub mod discovery;
pub mod error;
pub mod models;
pub mod ports;
pub mod server;
pub mod transfer;

use crate::models::device::DeviceInfo;
use crate::ports::{DISCOVERY_PORT, TRANSFER_PORT};
use futures_util::{stream, StreamExt};
use socket2::SockRef;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4, UdpSocket as StdUdpSocket};
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use transfer::session::Session;
use transfer::upload::IncomingTransferHandler;

pub type PeerMap = Arc<Mutex<HashMap<String, (SocketAddr, DeviceInfo)>>>;

#[derive(Clone)]
pub struct TlsIdentity {
    pub cert_pem: Vec<u8>,
    pub key_pem: Vec<u8>,
}

#[derive(Clone)]
pub struct Client {
    pub device: DeviceInfo,
    pub socket: Arc<UdpSocket>,
    pub multicast_addr: SocketAddrV4,
    pub port: u16,
    pub discovery_port: u16,
    pub peers: PeerMap,
    pub sessions: Arc<Mutex<HashMap<String, Session>>>, // Session ID to Session
    pub http_client: reqwest::Client,
    pub download_dir: String,
    pub bind_interface: Option<String>,
    pub multicast_interface: Ipv4Addr,
    pub tls_identity: Option<TlsIdentity>,
    pub pinned_neighbors: Arc<Mutex<HashMap<String, String>>>,
    pub campus_fallback: Arc<Mutex<campus_fallback::CampusFallbackState>>,
    pub incoming_handler: Option<Arc<dyn IncomingTransferHandler>>,
}

#[derive(Default)]
struct NetworkBinding {
    interface: Option<String>,
    ipv4: Option<Ipv4Addr>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum AnnouncementLogDecision {
    Emit,
    Suppress,
    EmitSummary { suppressed: u64 },
}

struct AnnouncementLogGate {
    window: Duration,
    last_emit: Option<Instant>,
    suppressed: u64,
}

impl AnnouncementLogGate {
    fn new(window: Duration) -> Self {
        Self {
            window,
            last_emit: None,
            suppressed: 0,
        }
    }

    fn record(&mut self, now: Instant) -> AnnouncementLogDecision {
        let Some(last_emit) = self.last_emit else {
            self.last_emit = Some(now);
            return AnnouncementLogDecision::Emit;
        };
        if now.duration_since(last_emit) < self.window {
            self.suppressed = self.suppressed.saturating_add(1);
            return AnnouncementLogDecision::Suppress;
        }
        self.last_emit = Some(now);
        let suppressed = std::mem::take(&mut self.suppressed);
        if suppressed == 0 {
            AnnouncementLogDecision::Emit
        } else {
            AnnouncementLogDecision::EmitSummary { suppressed }
        }
    }
}

fn is_private_lan_ipv4(ip: Ipv4Addr) -> bool {
    let [a, b, _, _] = ip.octets();
    matches!((a, b), (10, _) | (172, 16..=31) | (192, 168))
}

fn is_excluded_interface(interface: &str) -> bool {
    let lower = interface.to_ascii_lowercase();

    lower == "meta"
        || lower == "lo"
        || lower.starts_with("tun")
        || lower.starts_with("utun")
        || lower.starts_with("wg")
        || lower.starts_with("tailscale")
        || lower.starts_with("rmnet")
        || lower.starts_with("ccmni")
        || lower.starts_with("pdp")
        || lower.starts_with("wwan")
}

fn is_viable_lan_binding(interface: &str, ipv4: Ipv4Addr) -> bool {
    is_private_lan_ipv4(ipv4) && !is_excluded_interface(interface)
}

fn interface_priority(interface: &str, ipv4: Ipv4Addr) -> u8 {
    let lower = interface.to_ascii_lowercase();

    if !is_viable_lan_binding(interface, ipv4) {
        return 200;
    }

    if lower.starts_with("wlan") || lower.starts_with("ap") || lower.contains("wifi") {
        return 0;
    }
    if lower.starts_with("eth") || lower.starts_with("en") {
        return 10;
    }
    if lower.starts_with("usb") || lower.starts_with("rndis") {
        return 20;
    }
    if lower.starts_with("br") || lower.starts_with("bridge") {
        return 30;
    }
    40
}

fn ip_command() -> Command {
    if cfg!(target_os = "android") {
        Command::new("/system/bin/ip")
    } else {
        Command::new("ip")
    }
}

pub(crate) fn remember_peer_entry(
    peers: &mut HashMap<String, (SocketAddr, DeviceInfo)>,
    addr: SocketAddr,
    device: DeviceInfo,
) {
    let fingerprint = device.fingerprint.clone();
    peers.retain(|existing_fingerprint, (existing_addr, existing_info)| {
        if existing_fingerprint == &fingerprint {
            return true;
        }

        if existing_addr.ip() != addr.ip() || existing_addr.port() != addr.port() {
            return true;
        }

        if existing_info.alias != device.alias {
            return true;
        }

        matches!(
            (&existing_info.mac_address, &device.mac_address),
            (Some(existing_mac), Some(new_mac))
                if !existing_mac.eq_ignore_ascii_case(new_mac)
        )
    });

    peers.insert(fingerprint, (addr, device));
}

fn hardware_address_for_interface(interface: &str) -> Option<String> {
    let output = ip_command()
        .args(["link", "show", "dev", interface])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8(output.stdout).ok()?;
    for line in stdout.lines() {
        let mut parts = line.split_whitespace();
        while let Some(part) = parts.next() {
            if part == "link/ether" {
                return parts.next().map(|value| value.to_ascii_lowercase());
            }
        }
    }
    None
}

fn detect_network_binding_from_addrs() -> Option<NetworkBinding> {
    let output = ip_command()
        .args(["-o", "-4", "addr", "show", "up", "scope", "global"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8(output.stdout).ok()?;
    let mut best: Option<(u8, NetworkBinding)> = None;

    for line in stdout.lines() {
        let mut parts = line.split_whitespace();
        let _index = parts.next()?;
        let interface = parts.next()?.trim_end_matches(':');
        if parts.next()? != "inet" {
            continue;
        }
        let ipv4 = parts
            .next()
            .and_then(|value| value.split('/').next())
            .and_then(|value| value.parse::<Ipv4Addr>().ok())?;
        if !is_viable_lan_binding(interface, ipv4) {
            continue;
        }

        let priority = interface_priority(interface, ipv4);
        let binding = NetworkBinding {
            interface: Some(interface.to_string()),
            ipv4: Some(ipv4),
        };

        match &best {
            Some((best_priority, _)) if *best_priority <= priority => {}
            _ => best = Some((priority, binding)),
        }
    }

    best.map(|(_, binding)| binding)
}

fn detect_network_binding_from_route() -> Option<NetworkBinding> {
    let output = ip_command()
        .args(["-4", "route", "get", "1.1.1.1"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8(output.stdout).ok()?;
    let mut interface = None;
    let mut ipv4 = None;
    let mut parts = stdout.split_whitespace();

    while let Some(part) = parts.next() {
        match part {
            "dev" => {
                interface = parts.next().map(str::to_string);
            }
            "src" => {
                ipv4 = parts
                    .next()
                    .and_then(|value| value.parse::<Ipv4Addr>().ok());
            }
            _ => {}
        }
    }

    match (interface, ipv4) {
        (Some(interface), Some(ipv4)) if is_viable_lan_binding(&interface, ipv4) => {
            Some(NetworkBinding {
                interface: Some(interface),
                ipv4: Some(ipv4),
            })
        }
        _ => None,
    }
}

fn detect_network_binding_from_udp_probe() -> Option<NetworkBinding> {
    let socket = StdUdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("1.1.1.1:80").ok()?;
    let local_addr = socket.local_addr().ok()?;
    let ipv4 = match local_addr.ip() {
        IpAddr::V4(addr) => Some(addr),
        IpAddr::V6(_) => None,
    };

    ipv4
        .filter(|address| is_private_lan_ipv4(*address))
        .map(|address| NetworkBinding {
            interface: Some("system_route".to_string()),
            ipv4: Some(address),
        })
}

fn detect_network_binding() -> NetworkBinding {
    if std::env::var_os("AIRSEND_DATA_DIR").is_some() {
        return detect_network_binding_from_udp_probe().unwrap_or_default();
    }
    detect_network_binding_from_addrs()
        .or_else(detect_network_binding_from_route)
        .or_else(detect_network_binding_from_udp_probe)
        .unwrap_or_default()
}

fn subnet_probe_addresses(local: Ipv4Addr) -> Vec<SocketAddr> {
    let [a, b, c, local_host] = local.octets();
    let mut addresses = (1u8..=254)
        .filter(|host| *host != local_host)
        .flat_map(|host| {
            let ip = Ipv4Addr::new(a, b, c, host);
            [53318, TRANSFER_PORT]
                .into_iter()
                .map(move |port| SocketAddr::new(IpAddr::V4(ip), port))
        })
        .collect::<Vec<_>>();

    // Android Emulator exposes the development host at 10.0.2.2. Include it
    // explicitly because the Mac is not another guest on the emulator subnet.
    if [a, b, c] == [10, 0, 2] {
        let emulator_host = Ipv4Addr::new(10, 0, 2, 2);
        for port in [53318, TRANSFER_PORT] {
            let address = SocketAddr::new(IpAddr::V4(emulator_host), port);
            if !addresses.contains(&address) {
                addresses.push(address);
            }
        }
    }

    addresses
}

pub fn current_network_binding() -> Option<(String, Ipv4Addr)> {
    let binding = detect_network_binding();
    match (binding.interface, binding.ipv4) {
        (Some(interface), Some(ipv4)) => Some((interface, ipv4)),
        _ => None,
    }
}

impl Client {
    pub async fn default() -> crate::error::Result<Self> {
        let device = DeviceInfo::default();
        Self::with_config(
            device,
            TRANSFER_PORT,
            DISCOVERY_PORT,
            "/sdcard/Download/AirSend".to_string(),
        )
        .await
    }

    pub async fn with_config(
        info: DeviceInfo,
        transfer_port: u16,
        discovery_port: u16,
        download_dir: String,
    ) -> crate::error::Result<Self> {
        let binding = detect_network_binding();
        if binding.interface.is_none() || binding.ipv4.is_none() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AddrNotAvailable,
                "No viable LAN interface is ready yet",
            )
            .into());
        }
        let socket = UdpSocket::bind(format!("0.0.0.0:{}", discovery_port)).await?;
        socket.set_broadcast(true)?;
        socket.set_multicast_loop_v4(true)?;
        socket.set_multicast_ttl_v4(255)?;
        let multicast_interface = binding.ipv4.unwrap_or(Ipv4Addr::new(0, 0, 0, 0));
        if !multicast_interface.is_unspecified() {
            SockRef::from(&socket).set_multicast_if_v4(&multicast_interface)?;
        }
        socket.join_multicast_v4(Ipv4Addr::new(224, 0, 0, 167), multicast_interface)?;
        let multicast_addr = SocketAddrV4::new(Ipv4Addr::new(224, 0, 0, 167), discovery_port);
        let peers = Arc::new(Mutex::new(HashMap::new()));
        let http_client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(20))
            .pool_max_idle_per_host(0)
            .pool_idle_timeout(Duration::from_secs(1))
            .build()?;
        let sessions = Arc::new(Mutex::new(HashMap::new()));
        let pinned_neighbors = Arc::new(Mutex::new(HashMap::new()));
        let campus_fallback = Arc::new(Mutex::new(campus_fallback::CampusFallbackState::default()));
        let mut device = info;
        device.port = transfer_port;
        if device.mac_address.is_none() {
            if let Some(interface) = binding.interface.as_deref() {
                device.mac_address = hardware_address_for_interface(interface);
            }
        }
        Ok(Self {
            device,
            socket: socket.into(),
            multicast_addr,
            port: transfer_port,
            discovery_port,
            peers,
            http_client,
            sessions,
            download_dir,
            bind_interface: binding.interface,
            multicast_interface,
            tls_identity: None,
            pinned_neighbors,
            campus_fallback,
            incoming_handler: None,
        })
    }

    pub async fn start(
        &self,
    ) -> crate::error::Result<(JoinHandle<()>, JoinHandle<()>, JoinHandle<()>)> {
        let server_handle = {
            let client = self.clone();
            tokio::spawn(async move {
                if let Err(e) = client.start_http_server().await {
                    tracing::error!("HTTP server error: {}", e);
                }
            })
        };

        let udp_handle = {
            let client = self.clone();
            tokio::spawn(async move {
                if let Err(e) = client.listen_multicast().await {
                    tracing::error!("UDP listener error: {}", e);
                }
            })
        };

        let announcement_handle = {
            let client = self.clone();
            tokio::spawn(async move {
                let mut log_gate = AnnouncementLogGate::new(Duration::from_secs(30));
                let mut last_subnet_probe = Instant::now() - Duration::from_secs(30);
                loop {
                    if let Err(e) = client.announce(None).await {
                        match log_gate.record(Instant::now()) {
                            AnnouncementLogDecision::Emit => {
                                tracing::warn!("Announcement error: {}", e);
                            }
                            AnnouncementLogDecision::EmitSummary { suppressed } => {
                                tracing::warn!(
                                    "Announcement error: {} (suppressed {} repeats)",
                                    e,
                                    suppressed
                                );
                            }
                            AnnouncementLogDecision::Suppress => {}
                        }
                    }
                    let mut has_peers = !client.peers.lock().await.is_empty();
                    if !has_peers && last_subnet_probe.elapsed() >= Duration::from_secs(30) {
                        last_subnet_probe = Instant::now();
                        let discovered = client.discover_subnet_peers().await;
                        has_peers = discovered > 0;
                    }
                    let next_interval_secs = if has_peers { 30 } else { 5 };
                    tokio::time::sleep(std::time::Duration::from_secs(next_interval_secs)).await;
                }
            })
        };

        Ok((server_handle, udp_handle, announcement_handle))
    }

    pub async fn refresh_peers(&self) {
        let mut peers = self.peers.lock().await;
        peers.clear();
    }

    pub async fn discover_subnet_peers(&self) -> usize {
        if self.multicast_interface.is_unspecified()
            || !is_private_lan_ipv4(self.multicast_interface)
        {
            return 0;
        }

        let local_fingerprint = self.device.fingerprint.clone();
        let client = self.http_client.clone();
        let mut probes = stream::iter(subnet_probe_addresses(self.multicast_interface))
            .map(move |address| {
                let client = client.clone();
                async move {
                    let url = format!("https://{address}/api/localsend/v2/info");
                    let response = client
                        .get(&url)
                        .header("Connection", "close")
                        .timeout(Duration::from_millis(450))
                        .send()
                        .await
                        .ok()?
                        .error_for_status()
                        .ok()?;
                    let info = response.json::<DeviceInfo>().await.ok()?;
                    Some((address, info))
                }
            })
            .buffer_unordered(48);

        let mut discovered = 0usize;
        while let Some(result) = probes.next().await {
            let Some((candidate, info)) = result else {
                continue;
            };
            if info.fingerprint.eq_ignore_ascii_case(&local_fingerprint) {
                continue;
            }
            let mut address = candidate;
            address.set_port(info.port);
            let mut peers = self.peers.lock().await;
            remember_peer_entry(&mut peers, address, info);
            discovered = discovered.saturating_add(1);
        }
        if discovered > 0 {
            tracing::info!("Active subnet discovery found {} peer(s)", discovered);
        }
        discovered
    }

    pub async fn maybe_pin_peer_neighbor(&self, peer_ip: IpAddr, peer_mac: Option<&str>) {
        let IpAddr::V4(peer_ipv4) = peer_ip else {
            return;
        };
        let Some(interface) = self.bind_interface.clone() else {
            return;
        };
        let Some(mac_address) = peer_mac
            .map(str::trim)
            .filter(|value| is_valid_mac_address(value))
        else {
            return;
        };

        let peer_key = peer_ipv4.to_string();
        let pinned = self.pinned_neighbors.lock().await;
        if pinned.get(&peer_key).map(String::as_str) == Some(mac_address) {
            return;
        }
        drop(pinned);

        let interface_for_command = interface.clone();
        let peer_for_command = peer_key.clone();
        let mac_for_command = mac_address.to_string();
        let result = tokio::task::spawn_blocking(move || {
            Command::new("su")
                .args([
                    "-c",
                    &format!(
                        "ip neigh replace {} lladdr {} dev {} nud permanent",
                        peer_for_command, mac_for_command, interface_for_command
                    ),
                ])
                .output()
        })
        .await;

        match result {
            Ok(Ok(output)) if output.status.success() => {
                let mut pinned = self.pinned_neighbors.lock().await;
                pinned.insert(peer_key.clone(), mac_address.to_string());
                tracing::info!(
                    "Pinned peer neighbor {} -> {} on {}",
                    peer_key,
                    mac_address,
                    interface
                );
            }
            Ok(Ok(output)) => {
                let stderr = String::from_utf8_lossy(&output.stderr);
                tracing::warn!(
                    "Failed to pin neighbor {} -> {}: {}",
                    peer_key,
                    mac_address,
                    stderr.trim()
                );
            }
            Ok(Err(err)) => tracing::warn!("Failed to spawn ip neigh command: {}", err),
            Err(err) => tracing::warn!("Neighbor pin task failed: {}", err),
        }
    }
}

fn is_valid_mac_address(value: &str) -> bool {
    let parts: Vec<_> = value.split(':').collect();
    parts.len() == 6
        && parts
            .iter()
            .all(|part| part.len() == 2 && u8::from_str_radix(part, 16).is_ok())
}

#[cfg(test)]
mod announcement_log_tests {
    use super::{subnet_probe_addresses, AnnouncementLogDecision, AnnouncementLogGate};
    use std::net::Ipv4Addr;
    use std::time::{Duration, Instant};

    #[test]
    fn repeated_announcement_errors_are_suppressed_and_summarized() {
        let now = Instant::now();
        let mut gate = AnnouncementLogGate::new(Duration::from_secs(30));

        assert_eq!(gate.record(now), AnnouncementLogDecision::Emit);
        assert_eq!(
            gate.record(now + Duration::from_secs(5)),
            AnnouncementLogDecision::Suppress
        );
        assert_eq!(
            gate.record(now + Duration::from_secs(31)),
            AnnouncementLogDecision::EmitSummary { suppressed: 1 }
        );
    }

    #[test]
    fn subnet_probe_covers_both_transfer_ports_and_skips_self() {
        let addresses = subnet_probe_addresses(Ipv4Addr::new(10, 90, 97, 52));
        assert_eq!(addresses.len(), 506);
        assert!(!addresses
            .iter()
            .any(|address| address.ip().to_string() == "10.90.97.52"));
        assert!(addresses
            .iter()
            .any(|address| address.to_string() == "10.90.97.254:53318"));
        assert!(addresses
            .iter()
            .any(|address| address.to_string() == "10.90.97.254:53319"));
    }

    #[test]
    fn subnet_probe_includes_android_emulator_host() {
        let addresses = subnet_probe_addresses(Ipv4Addr::new(10, 0, 2, 16));

        assert!(addresses
            .iter()
            .any(|address| address.to_string() == "10.0.2.2:53318"));
        assert!(addresses
            .iter()
            .any(|address| address.to_string() == "10.0.2.2:53319"));
    }
}
