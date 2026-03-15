use tokio::net::{UnixListener, UnixStream};
use tokio::io::{AsyncBufReadExt, BufReader, AsyncWriteExt};
use tracing::{info, error, warn, Level};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};
use notify::{Watcher, RecursiveMode, EventKind, event::ModifyKind, event::RenameMode, event::AccessKind, event::AccessMode};

use tracing_subscriber::fmt::format::FmtSpan;
use anyhow::{Result, Context};
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use localsend::{campus_fallback::MAX_FALLBACK_BYTES, current_network_binding, ports::{DISCOVERY_PORT, TRANSFER_PORT}, Client, TlsIdentity};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use localsend::models::file::FileMetadata;
use localsend::models::device::DeviceInfo;
use bytes::Bytes;
use std::time::Duration;
use std::process::Command;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use tokio::sync::mpsc;
use openssl::{
    asn1::Asn1Time,
    bn::{BigNum, MsbOption},
    hash::MessageDigest,
    nid::Nid,
    pkey::PKey,
    rsa::Rsa,
    x509::{
        extension::{AuthorityKeyIdentifier, BasicConstraints, ExtendedKeyUsage, KeyUsage, SubjectAlternativeName, SubjectKeyIdentifier},
        X509,
        X509NameBuilder,
    },
};

const UDS_PATH: &str = "\0airsend_ipc";

const LOG_PATH: &str = "/data/local/tmp";
const LOG_FILE: &str = "airsend_daemon.log";
const TLS_DIR: &str = "/data/adb/airsend";
const TLS_CERT_PATH: &str = "/data/adb/airsend/server-cert.pem";
const TLS_KEY_PATH: &str = "/data/adb/airsend/server-key.pem";
#[derive(Clone)]
struct PreparedTlsIdentity {
    cert_pem: Vec<u8>,
    key_pem: Vec<u8>,
    fingerprint: String,
}

fn fingerprint_for_cert(cert: &X509) -> Result<String> {
    let digest = cert.digest(MessageDigest::sha256())?;
    Ok(digest.iter().map(|byte| format!("{:02x}", byte)).collect())
}

fn write_private_file(path: &str, bytes: &[u8], mode: u32) -> Result<()> {
    fs::write(path, bytes).with_context(|| format!("Failed to write {}", path))?;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .with_context(|| format!("Failed to chmod {}", path))?;
    Ok(())
}

fn load_tls_identity() -> Result<PreparedTlsIdentity> {
    let cert_pem = fs::read(TLS_CERT_PATH).with_context(|| format!("Failed to read {}", TLS_CERT_PATH))?;
    let key_pem = fs::read(TLS_KEY_PATH).with_context(|| format!("Failed to read {}", TLS_KEY_PATH))?;
    let cert = X509::from_pem(&cert_pem).context("Failed to parse TLS certificate PEM")?;
    let fingerprint = fingerprint_for_cert(&cert)?;

    Ok(PreparedTlsIdentity {
        cert_pem,
        key_pem,
        fingerprint,
    })
}

fn generate_tls_identity() -> Result<PreparedTlsIdentity> {
    fs::create_dir_all(TLS_DIR).with_context(|| format!("Failed to create {}", TLS_DIR))?;
    fs::set_permissions(TLS_DIR, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("Failed to chmod {}", TLS_DIR))?;

    let rsa = Rsa::generate(2048).context("Failed to generate RSA key")?;
    let pkey = PKey::from_rsa(rsa).context("Failed to wrap RSA key")?;

    let mut name_builder = X509NameBuilder::new().context("Failed to create X509NameBuilder")?;
    name_builder
        .append_entry_by_nid(Nid::COMMONNAME, "AirSend Android Module")
        .context("Failed to set certificate CN")?;
    let name = name_builder.build();

    let mut serial = BigNum::new().context("Failed to create serial bignum")?;
    serial
        .rand(64, MsbOption::MAYBE_ZERO, false)
        .context("Failed to randomize certificate serial")?;
    let serial = serial.to_asn1_integer().context("Failed to encode certificate serial")?;

    let mut builder = X509::builder().context("Failed to create X509 builder")?;
    builder.set_version(2).context("Failed to set X509 version")?;
    builder
        .set_serial_number(&serial)
        .context("Failed to set certificate serial")?;
    builder
        .set_subject_name(&name)
        .context("Failed to set subject name")?;
    builder
        .set_issuer_name(&name)
        .context("Failed to set issuer name")?;
    builder.set_pubkey(&pkey).context("Failed to set public key")?;

    let not_before = Asn1Time::days_from_now(0).context("Failed to set not_before")?;
    builder
        .set_not_before(not_before.as_ref())
        .context("Failed to apply not_before")?;
    let not_after = Asn1Time::days_from_now(3650).context("Failed to set not_after")?;
    builder
        .set_not_after(not_after.as_ref())
        .context("Failed to apply not_after")?;

    let basic_constraints = BasicConstraints::new()
        .critical()
        .build()
        .context("Failed to build BasicConstraints")?;
    builder
        .append_extension(basic_constraints)
        .context("Failed to append BasicConstraints")?;

    let key_usage = KeyUsage::new()
        .digital_signature()
        .key_encipherment()
        .build()
        .context("Failed to build KeyUsage")?;
    builder
        .append_extension(key_usage)
        .context("Failed to append KeyUsage")?;

    let extended_key_usage = ExtendedKeyUsage::new()
        .server_auth()
        .build()
        .context("Failed to build ExtendedKeyUsage")?;
    builder
        .append_extension(extended_key_usage)
        .context("Failed to append ExtendedKeyUsage")?;

    let subject_key_identifier = SubjectKeyIdentifier::new()
        .build(&builder.x509v3_context(None, None))
        .context("Failed to build SubjectKeyIdentifier")?;
    builder
        .append_extension(subject_key_identifier)
        .context("Failed to append SubjectKeyIdentifier")?;

    let authority_key_identifier = AuthorityKeyIdentifier::new()
        .keyid(true)
        .build(&builder.x509v3_context(None, None))
        .context("Failed to build AuthorityKeyIdentifier")?;
    builder
        .append_extension(authority_key_identifier)
        .context("Failed to append AuthorityKeyIdentifier")?;

    let subject_alt_name = SubjectAlternativeName::new()
        .dns("localhost")
        .ip("127.0.0.1")
        .build(&builder.x509v3_context(None, None))
        .context("Failed to build SubjectAlternativeName")?;
    builder
        .append_extension(subject_alt_name)
        .context("Failed to append SubjectAlternativeName")?;

    builder
        .sign(&pkey, MessageDigest::sha256())
        .context("Failed to sign certificate")?;

    let cert = builder.build();
    let cert_pem = cert.to_pem().context("Failed to encode certificate PEM")?;
    let key_pem = pkey
        .private_key_to_pem_pkcs8()
        .context("Failed to encode private key PEM")?;
    let fingerprint = fingerprint_for_cert(&cert)?;

    write_private_file(TLS_CERT_PATH, &cert_pem, 0o644)?;
    write_private_file(TLS_KEY_PATH, &key_pem, 0o600)?;

    Ok(PreparedTlsIdentity {
        cert_pem,
        key_pem,
        fingerprint,
    })
}

fn load_or_create_tls_identity() -> Result<PreparedTlsIdentity> {
    match load_tls_identity() {
        Ok(identity) => Ok(identity),
        Err(err) => {
            warn!("现有 TLS 证书不可用，准备重建: {err:#}");
            generate_tls_identity()
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    // 1. 强制绕过代理（保持此逻辑）
    std::env::set_var("NO_PROXY", "*");
    std::env::set_var("no_proxy", "*");
    std::env::remove_var("HTTP_PROXY");
    std::env::remove_var("http_proxy");
    std::env::remove_var("HTTPS_PROXY");
    std::env::remove_var("https_proxy");
    std::env::remove_var("ALL_PROXY");
    std::env::remove_var("all_proxy");

    let _log_guard = init_logging()?;
    info!("AirSend Daemon 启动 (LocalSend v0.2.2 兼容模式)");

    // 1. 强制前置：优先向内核注册 UDS，建立 IPC 物理接收端点
    let listener = UnixListener::bind(UDS_PATH)
        .context(format!("Failed to bind abstract UDS: {:?}", UDS_PATH))?;
    info!("🚀 Successfully bound to UDS: {}", UDS_PATH);

    let tls_identity = load_or_create_tls_identity().context("Failed to initialize TLS identity")?;
    info!("🔐 TLS 设备指纹: {}", tls_identity.fingerprint);
    let device_info = DeviceInfo::headless_with_identity(tls_identity.fingerprint.clone(), "http");

    // 2. 🛡️ 引入韧性轮询：等待系统网络底层设备 (wlan0/tun0) 挂载完成
    let mut client = loop {
        match Client::with_config(
            device_info.clone(),
            TRANSFER_PORT,
            DISCOVERY_PORT,
            "/sdcard/Download/AirSend".to_string(),
        )
        .await
        {
            Ok(c) => {
                tracing::info!("🌐 网络设备就绪，LocalSend 客户端初始化成功！");
                break c;
            }
            Err(error) => {
                tracing::warn!("等待局域网接口就绪: {}... 2秒后重试", error);
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
        }
    };

    // 原有的构建 HTTP Client 逻辑保持不变
    let mut http_client_builder = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .no_proxy(); // 🔪 彻底物理切断所有内置代理探测逻辑

    // Android 热点/网络切换后，固定绑定旧的源 IP 或网卡会让 reqwest 持续报
    // "Cannot assign requested address"，导致 Android -> Mac 的主动发送失效。
    // 这里让内核按当前路由自行选择出口；UDP 发现 socket 仍然保持独立的 LAN 绑定。
    if let Some(interface) = client.bind_interface.as_deref() {
        tracing::info!(
            "🌐 出站 HTTP 走系统路由（当前检测到 {} / {}）",
            interface,
            client.multicast_interface
        );
    } else if !client.multicast_interface.is_unspecified() {
        tracing::info!(
            "🌐 出站 HTTP 走系统路由（当前检测到 {}）",
            client.multicast_interface
        );
    } else {
        tracing::info!("🌐 出站 HTTP 走系统路由（未固定源地址）");
    }

    client.http_client = http_client_builder
        .build()
        .context("Failed to build insecure HTTP client")?;
    client.tls_identity = None;

    let state = Arc::new(AppState {
        client,
        preferred_target: Mutex::new(None),
    });

    // 🚀 点火：启动底层物理监控协程
    spawn_physical_watcher(state.clone());

    // 3. 启动协议栈：必须扔进 tokio 的并发调度池，决不能阻塞主任务！

    let state_for_server = state.clone();
    tokio::spawn(async move {
        if let Err(e) = state_for_server.client.start().await {
            error!("LocalSend protocol stack crashed: {:?}", e);
        }
    });
    info!("LocalSend 协议栈已在后台并发运行");

    spawn_network_rebind_watcher((
        state.client.bind_interface.clone(),
        state.client.multicast_interface,
    ));

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let state_clone = state.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_client(stream, state_clone).await {
                        error!("IPC Error: {:?}", e);
                    }
                });
            }
            Err(e) => error!("Accept error: {:?}", e),
        }
    }
}

struct AppState {
    client: Client,
    preferred_target: Mutex<Option<String>>,
}

fn spawn_network_rebind_watcher(initial_binding: (Option<String>, Ipv4Addr)) {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(3)).await;

            let Some((interface, ipv4)) = current_network_binding() else {
                continue;
            };

            let binding_changed = initial_binding.0.as_deref() != Some(interface.as_str())
                || initial_binding.1 != ipv4;
            if !binding_changed {
                continue;
            }

            warn!(
                "🔄 检测到网络绑定变化: {:?}/{:?} -> {}/{}. 准备重启 daemon 以重绑局域网 socket",
                initial_binding.0,
                initial_binding.1,
                interface,
                ipv4
            );

            if let Err(err) = schedule_self_restart() {
                error!("❌ 计划重启 daemon 失败: {err:#}");
                continue;
            }

            warn!("♻️ 旧 daemon 退出，等待新进程接管");
            std::process::exit(0);
        }
    });
}

fn schedule_self_restart() -> Result<()> {
    let daemon_bin = std::env::current_exe()
        .context("failed to resolve current daemon path")?;
    let log_file = format!("{}/{}", LOG_PATH, LOG_FILE);
    let script = format!(
        "sleep 1; nohup '{}' >> '{}' 2>&1 &",
        daemon_bin.display(),
        log_file
    );

    Command::new("sh")
        .args(["-c", &script])
        .spawn()
        .context("failed to spawn daemon restart helper")?;

    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum IpcCommand {
    GetPeers,
    SendText {
        target_id: Option<String>,
        text: String,
    },
    SendFile {
        target_id: Option<String>,
        path: String,
    },
}

#[derive(Debug, serde::Deserialize)]
struct JsonIpcCommand {
    op: String,
    #[serde(default, rename = "targetId")]
    target_id: Option<String>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    path: Option<String>,
}

fn parse_ipc_command(raw: &str) -> Result<IpcCommand> {
    if let Ok(command) = serde_json::from_str::<JsonIpcCommand>(raw) {
        return match command.op.as_str() {
            "get_peers" => Ok(IpcCommand::GetPeers),
            "send_text" => Ok(IpcCommand::SendText {
                target_id: command.target_id,
                text: command.text.ok_or_else(|| anyhow::anyhow!("Missing text payload"))?,
            }),
            "send_file" => Ok(IpcCommand::SendFile {
                target_id: command.target_id,
                path: command.path.ok_or_else(|| anyhow::anyhow!("Missing path payload"))?,
            }),
            _ => Err(anyhow::anyhow!("Unknown IPC op: {}", command.op)),
        };
    }

    if raw == "GET_PEERS" {
        return Ok(IpcCommand::GetPeers);
    }

    if let Some(text) = raw.strip_prefix("SEND_TEXT:") {
        return Ok(IpcCommand::SendText {
            target_id: None,
            text: text.to_string(),
        });
    }

    if let Some(rest) = raw.strip_prefix("SEND_TEXT_TO:") {
        let (target_id, text) = rest
            .split_once(':')
            .ok_or_else(|| anyhow::anyhow!("Malformed SEND_TEXT_TO command"))?;
        return Ok(IpcCommand::SendText {
            target_id: Some(target_id.to_string()),
            text: text.to_string(),
        });
    }

    if let Some(path) = raw.strip_prefix("SEND_FILE:") {
        return Ok(IpcCommand::SendFile {
            target_id: None,
            path: path.to_string(),
        });
    }

    if let Some(rest) = raw.strip_prefix("SEND_FILE_TO:") {
        let (target_id, path) = rest
            .split_once(':')
            .ok_or_else(|| anyhow::anyhow!("Malformed SEND_FILE_TO command"))?;
        return Ok(IpcCommand::SendFile {
            target_id: Some(target_id.to_string()),
            path: path.to_string(),
        });
    }

    Err(anyhow::anyhow!("Unknown IPC command"))
}

// 确保你传入了包含 LocalSend 客户端的 state
pub fn spawn_physical_watcher(state: Arc<AppState>) {
    // 1. 创建 Tokio 原生的异步 Channel，桥接同步内核中断与异步运行时
    let (tx, mut rx) = mpsc::unbounded_channel();

    // 2. 将 notify 的事件回调闭包安全推入异步 Channel
    let mut watcher = notify::recommended_watcher(move |res| {
        let _ = tx.send(res);
    }).expect("Failed to create inotify watcher");

    // 3. 穷举双端火力覆盖：应对 AOSP 原生与国内 OEM (如 MIUI/HyperOS/ColorOS) 的魔改路径
    let target_paths = [
        "/data/media/0/Pictures/Screenshots", 
        "/data/media/0/DCIM/Screenshots",     
    ];

    for watch_path in target_paths {
        // 同步创建目录，确保探针挂载不报错
        let _ = std::fs::create_dir_all(watch_path); 
        
        if let Err(e) = watcher.watch(Path::new(watch_path), RecursiveMode::NonRecursive) {
            tracing::warn!("⚠️ 无法绑定 inotify 至 {}: {:?}", watch_path, e);
        } else {
            tracing::info!("👁️ 物理 EXT4 探针已深深扎入: {}", watch_path);
        }
    }

    // 4. 启动真正的 Tokio 异步消费协程，绝不阻塞主线程
    tokio::spawn(async move {
        // 核心：死死锁住 watcher 的生命周期，防止文件句柄被内核强制回收
        let _keep_watcher_alive = watcher;

        while let Some(res) = rx.recv().await {
            match res {
                Ok(event) => {
                    // 匹配系统截图落盘的真实物理动作 (关闭写入或重命名 .pending)
                    let is_target_event = match event.kind {
                        EventKind::Access(AccessKind::Close(AccessMode::Write)) => true,
                        EventKind::Modify(ModifyKind::Name(RenameMode::To)) => true,
                        EventKind::Modify(ModifyKind::Name(RenameMode::Both)) => true,
                        _ => false,
                    };

                    if is_target_event {
                        if let Some(path_buf) = event.paths.first() {
                            let path_str = path_buf.to_string_lossy().to_string();
                            
                            // 强力过滤系统 IO 碎片文件
                            if path_str.ends_with(".tmp") || path_str.ends_with(".pending") || path_buf.file_name().unwrap_or_default().to_string_lossy().starts_with(".") {
                                continue;
                            }
                            
                            tracing::info!("📸 底层捕获截图物理落盘: {}", path_str);
                            
                            let state_clone = state.clone();
                            tokio::spawn(async move {
                                // 🔋 灵魂延时：等待 EXT4 Page Cache 刷盘，彻底消灭 0 字节鬼影文件
                                tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
                                
                                tracing::info!("🚀 正在绕过 App 层，直接向 Mac 发射物理路径: {}", path_str);
                                
                                // 直接调用 Daemon 内部的 HTTPS 发送引擎
                                if let Err(e) = send_data(&state_clone, None, &path_str, false).await {
                                    tracing::error!("❌ 截图底层直发失败: {:?}", e);
                                }
                            });
                        }
                    }
                },
                Err(e) => tracing::error!("inotify watch error: {:?}", e),
            }
        }
    });
}


fn notify_android_system(file_path: &str) {
    let _ = Command::new("am")
        .args(&["broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", &format!("file://{}", file_path)])
        .spawn();
    let filename = Path::new(file_path).file_name().and_then(|s| s.to_str()).unwrap_or("新文件");
    let notification_cmd = format!("cmd notification post -S bigtext -t 'AirSend' 'airsend_rec' '已收到文件: {}'", filename);
    let _ = Command::new("sh").args(&["-c", &notification_cmd]).spawn();
}

fn init_logging() -> Result<tracing_appender::non_blocking::WorkerGuard> {
    let file_appender = tracing_appender::rolling::never(LOG_PATH, LOG_FILE);
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);
    
    // 允许使用 RUST_LOG=trace 从环境变量动态控制级别
    let env_filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::registry()
        .with(env_filter)
        // 输出到文件 (无颜色)
        .with(tracing_subscriber::fmt::layer().with_writer(non_blocking).with_ansi(false))
        // 🔋 后台守护进程无需终端输出（service.sh 已将 stdout 重定向到日志文件）
        .init();

    Ok(guard)
}

async fn handle_client(stream: UnixStream, state: Arc<AppState>) -> Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut buf_reader = BufReader::new(reader);
    let mut line = String::new();
    while buf_reader.read_line(&mut line).await? != 0 {
        let cmd = line.strip_suffix('\n').unwrap_or(&line);
        let cmd = cmd.strip_suffix('\r').unwrap_or(cmd);
        if !cmd.is_empty() {
            match parse_ipc_command(cmd) {
                Ok(IpcCommand::GetPeers) => {
                #[derive(serde::Serialize)]
                struct PeerDto { id: String, alias: String, device_model: String }
                
                let peers = state.client.peers.lock().await;
                let mut peer_list = Vec::new();
                for (id, (_, info)) in peers.iter() {
                    peer_list.push(PeerDto {
                        id: id.clone(),
                        alias: info.alias.clone(),
                        device_model: info.device_model.clone().unwrap_or_else(|| "Unknown".to_string()),
                    });
                }
                if let Ok(json) = serde_json::to_string(&peer_list) {
                    let response = format!("{}\n", json);
                    if let Err(e) = writer.write_all(response.as_bytes()).await {
                        error!("Write GET_PEERS error: {:?}", e);
                    }
                }
                }
                Ok(command) => {
                    let state_ref = state.clone();
                    tokio::spawn(async move {
                        if let Err(e) = process_command(command, &state_ref).await {
                            error!("Command failed: {:?}", e);
                        }
                    });
                }
                Err(e) => warn!("Invalid IPC command {:?}: {}", cmd, e),
            }
        }
        line.clear();
    }
    Ok(())
}

async fn process_command(command: IpcCommand, state: &AppState) -> Result<()> {
    match command {
        IpcCommand::GetPeers => {}
        IpcCommand::SendText { target_id, text } => {
            send_data(state, target_id, &text, true).await?;
        }
        IpcCommand::SendFile { target_id, path } => {
            send_data(state, target_id, &path, false).await?;
        }
    }
    Ok(())
}

async fn send_data(state: &AppState, target_id_opt: Option<String>, data: &str, is_text: bool) -> Result<()> {
    if let Some(tid) = target_id_opt {
        let mut retries = 0;
        let (target_id, target_addr) = loop {
            {
                let peers = state.client.peers.lock().await;
                if let Some((addr, _)) = peers.get(&tid) {
                    tracing::info!("🔍 指定发送: [{}] {}", tid, addr);
                    break (tid.clone(), addr.to_string());
                }
            }
            if retries >= 10 {
                anyhow::bail!("Target not found: {}", tid);
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
            retries += 1;
        };
        return send_to_target(state, &target_id, &target_addr, data, is_text).await;
    }

    // 自动模式：遍历所有候选 peer，避免卡死在陈旧 IP 上。
    let mut rounds = 0;
    let mut last_error: Option<anyhow::Error> = None;
    loop {
        let candidates: Vec<(String, String)> = {
            let peers = state.client.peers.lock().await;
            peers
                .iter()
                .map(|(id, (addr, _))| (id.clone(), addr.to_string()))
                .collect()
        };

        if candidates.is_empty() {
            if rounds >= 10 {
                anyhow::bail!("No target found");
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
            rounds += 1;
            continue;
        }

        tracing::info!("🔎 自动发送候选数量: {}", candidates.len());
        for (target_id, target_addr) in candidates {
            tracing::info!("🔍 UDP 缓存命中! 自动尝试目标: [{}] {}", target_id, target_addr);
            match send_to_target(state, &target_id, &target_addr, data, is_text).await {
                Ok(_) => return Ok(()),
                Err(err) => {
                    tracing::warn!("⚠️ 目标 [{}] 发送失败: {}", target_id, err);
                    last_error = Some(err);
                    // 清理失效目标，避免后续继续命中老 IP。
                    let mut peers = state.client.peers.lock().await;
                    peers.remove(&target_id);
                }
            }
        }

        if rounds >= 2 {
            return Err(last_error.unwrap_or_else(|| anyhow::anyhow!("No reachable target found")));
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
        rounds += 1;
    }
}

async fn send_to_target(
    state: &AppState,
    target_id: &str,
    target_addr: &str,
    data: &str,
    is_text: bool,
) -> Result<()> {
    if is_text {
        tracing::info!("🚀 正在向 [{}] {} 发起直连握手...", target_id, target_addr);
        if let Err(e) = send_text_protocol(&state.client, target_id, data).await {
            tracing::warn!("⚠️ 直连文本发送失败，切换 Campus 组播 fallback: {:#?}", e);
            if let Err(fallback_err) = state.client.send_campus_text(target_id, data).await {
                tracing::error!("❌ Campus 组播文本 fallback 也失败了:\n{:#?}", fallback_err);
                return Err(fallback_err.into());
            }
        }
    } else {
        let path = PathBuf::from(data);
        if let Err(e) = state.client.send_file(target_id.to_string(), path.clone()).await {
            tracing::warn!("⚠️ 直连文件发送失败，切换 Campus 组播 fallback: {:#?}", e);
            let metadata = tokio::fs::metadata(&path).await?;
            if metadata.len() > MAX_FALLBACK_BYTES as u64 {
                return Err(anyhow::anyhow!(
                    "Direct file send failed and campus fallback only supports files up to {} bytes",
                    MAX_FALLBACK_BYTES
                ));
            }
            let bytes = tokio::fs::read(&path).await?;
            let file_name = path
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("CampusTransfer.bin");
            let file_type = infer_campus_mime_type(&path);
            if let Err(fallback_err) = state
                .client
                .send_campus_file(target_id, file_name, &file_type, &bytes)
                .await
            {
                tracing::error!("❌ Campus 组播文件 fallback 也失败了:\n{:#?}", fallback_err);
                return Err(fallback_err.into());
            }
        }
    }
    tracing::info!("✅ 发送成功！");
    Ok(())
}

fn infer_campus_mime_type(path: &Path) -> String {
    let ext = path
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase());

    match ext.as_deref() {
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("heic") => "image/heic",
        Some("mp4") => "video/mp4",
        Some("mov") => "video/quicktime",
        Some("txt") => "text/plain",
        Some("json") => "application/json",
        Some("pdf") => "application/pdf",
        _ => "application/octet-stream",
    }
    .to_string()
}

// 🚨 关键修复 3：参数名改为 peer_id，并在方法内准确传递给 prepare_upload
async fn send_text_protocol(client: &Client, peer_id: &str, text: &str) -> Result<()> {
    let text_bytes = text.as_bytes();
    let file_id = format!("sync_{}", uuid::Uuid::new_v4());
    let mut files = HashMap::new();
    files.insert(file_id.clone(), FileMetadata {
        id: file_id.clone(),
        file_name: "clipboard.txt".to_string(),
        size: text_bytes.len() as u64,
        file_type: "text/plain".to_string(),
        sha256: None,
        preview: None,
        metadata: None,
    });
    
    tracing::info!("🔄 正在执行 prepare_upload 握手...");
    // 🚨 关键修复 4：把正确的设备指纹 (peer_id) 传给底层 API
    let response = client.prepare_upload(peer_id.to_string(), files).await?;
    tracing::info!("✅ 握手通过，拿到 Session ID: {}", response.session_id);
    
    if let Some(token) = response.files.get(&file_id) {
        client.upload(response.session_id, file_id, token.clone(), Bytes::copy_from_slice(text_bytes)).await?;
    }
    Ok(())
}

// 逆向推送管道：将接收到的文本击穿回 Android App 层
pub async fn push_text_to_app(text: &str) -> anyhow::Result<()> {
    tracing::info!("🔄 准备向 Android App 推送剪贴板数据...");
    
    // 连接到 App 侧建立的抽象命名空间 Socket
    let mut stream = UnixStream::connect("\0airsend_app_ipc").await
        .context("Failed to connect to App's reverse IPC socket (\\0airsend_app_ipc)")?;
        
    stream.write_all(text.as_bytes()).await?;
    stream.shutdown().await?; // 显式关闭发送端，触发 App 侧的 readText() 结束
    
    tracing::info!("✅ 成功将文本推送到 Android App");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{parse_ipc_command, IpcCommand};

    #[test]
    fn parses_json_text_command_with_multiline_payload() {
        let raw = r#"{"op":"send_text","targetId":"peer-1","text":"line1\nline2\n "}"#;

        let command = parse_ipc_command(raw).unwrap();

        assert_eq!(
            command,
            IpcCommand::SendText {
                target_id: Some("peer-1".to_string()),
                text: "line1\nline2\n ".to_string(),
            }
        );
    }

    #[test]
    fn parses_legacy_text_command_without_trimming_payload() {
        let command = parse_ipc_command("SEND_TEXT:  padded text  ").unwrap();

        assert_eq!(
            command,
            IpcCommand::SendText {
                target_id: None,
                text: "  padded text  ".to_string(),
            }
        );
    }

    #[test]
    fn parses_legacy_targeted_text_command_with_colons() {
        let command = parse_ipc_command("SEND_TEXT_TO:peer-1:https://example.com:a").unwrap();

        assert_eq!(
            command,
            IpcCommand::SendText {
                target_id: Some("peer-1".to_string()),
                text: "https://example.com:a".to_string(),
            }
        );
    }
}
