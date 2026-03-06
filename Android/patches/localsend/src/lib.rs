pub mod discovery;
pub mod error;
pub mod models;
pub mod server;
pub mod transfer;

use crate::models::device::DeviceInfo;
use socket2::SockRef;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4, UdpSocket as StdUdpSocket};
use std::process::Command;
use tokio::net::UdpSocket;
use tokio::task::JoinHandle;
use std::sync::Arc;
use tokio::sync::Mutex;
use transfer::session::Session;

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
    pub peers: Arc<Mutex<HashMap<String, (SocketAddr, DeviceInfo)>>>,
    pub sessions: Arc<Mutex<HashMap<String, Session>>>, // Session ID to Session
    pub http_client: reqwest::Client,
    pub download_dir: String,
    pub bind_interface: Option<String>,
    pub multicast_interface: Ipv4Addr,
    pub tls_identity: Option<TlsIdentity>,
}

#[derive(Default)]
struct NetworkBinding {
    interface: Option<String>,
    ipv4: Option<Ipv4Addr>,
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

fn detect_network_binding_from_ip(ipv4: Ipv4Addr) -> Option<NetworkBinding> {
    let output = Command::new("ip")
        .args(["-o", "-4", "addr", "show", "up", "scope", "global"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8(output.stdout).ok()?;
    for line in stdout.lines() {
        let mut parts = line.split_whitespace();
        let _index = parts.next()?;
        let interface = parts.next()?.trim_end_matches(':');
        if parts.next()? != "inet" {
            continue;
        }

        let candidate = parts
            .next()
            .and_then(|value| value.split('/').next())
            .and_then(|value| value.parse::<Ipv4Addr>().ok())?;
        if candidate == ipv4 && is_viable_lan_binding(interface, candidate) {
            return Some(NetworkBinding {
                interface: Some(interface.to_string()),
                ipv4: Some(candidate),
            });
        }
    }

    None
}

fn detect_network_binding_from_addrs() -> Option<NetworkBinding> {
    let output = Command::new("ip")
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
    let output = Command::new("ip")
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
                ipv4 = parts.next().and_then(|value| value.parse::<Ipv4Addr>().ok());
            }
            _ => {}
        }
    }

    match (interface, ipv4) {
        (Some(interface), Some(ipv4)) if is_viable_lan_binding(&interface, ipv4) => Some(NetworkBinding {
            interface: Some(interface),
            ipv4: Some(ipv4),
        }),
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

    ipv4.and_then(detect_network_binding_from_ip)
}

fn detect_network_binding() -> NetworkBinding {
    detect_network_binding_from_addrs()
        .or_else(detect_network_binding_from_route)
        .or_else(detect_network_binding_from_udp_probe)
        .unwrap_or_default()
}

impl Client {
    pub async fn default() -> crate::error::Result<Self> {
        let device = DeviceInfo::default();
        Self::with_config(device, 53317, "/sdcard/Download/AirSend".to_string()).await
    }

    pub async fn with_config(info: DeviceInfo, port: u16, download_dir: String) -> crate::error::Result<Self>{
        let binding = detect_network_binding();
        if binding.interface.is_none() || binding.ipv4.is_none() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AddrNotAvailable,
                "No viable LAN interface is ready yet",
            )
            .into());
        }
        let socket = UdpSocket::bind(format!("0.0.0.0:{}", port.clone())).await?;
        socket.set_multicast_loop_v4(true)?;
        socket.set_multicast_ttl_v4(255)?;
        let multicast_interface = binding.ipv4.unwrap_or(Ipv4Addr::new(0, 0, 0, 0));
        if !multicast_interface.is_unspecified() {
            SockRef::from(&socket).set_multicast_if_v4(&multicast_interface)?;
        }
        socket.join_multicast_v4(Ipv4Addr::new(224, 0, 0, 167), multicast_interface)?;
        let multicast_addr = SocketAddrV4::new(Ipv4Addr::new(224, 0, 0, 167), port.clone());
        let peers = Arc::new(Mutex::new(HashMap::new()));
        let http_client = reqwest::Client::new();
        let sessions = Arc::new(Mutex::new(HashMap::new()));

        Ok(Self {
            device: info,
            socket: socket.into(),
            multicast_addr,
            port,
            peers,
            http_client,
            sessions,
            download_dir,
            bind_interface: binding.interface,
            multicast_interface,
            tls_identity: None,
        })

    }

    pub async fn start(&self) -> crate::error::Result<(JoinHandle<()>, JoinHandle<()>, JoinHandle<()>)> {
        let server_handle = {
            let client = self.clone();
            tokio::spawn(async move {
                if let Err(e) = client.start_http_server().await {
                    eprintln!("HTTP server error: {}", e);
                }
            })
        };

        let udp_handle = {
            let client = self.clone();
            tokio::spawn(async move {
                if let Err(e) = client.listen_multicast().await {
                    eprintln!("UDP listener error: {}", e);
                }
            })
        };

        let announcement_handle = {
            let client = self.clone();
            tokio::spawn(async move {
                loop {
                    if let Err(e) = client.announce(None).await {
                        eprintln!("Announcement error: {}", e);
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                }
            })
        };

        Ok((server_handle, udp_handle, announcement_handle))
    }

    pub async fn refresh_peers(&self) {
        let mut peers = self.peers.lock().await;
        peers.clear();
    }
}
