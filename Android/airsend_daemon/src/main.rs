use notify::{
    event::AccessKind, event::AccessMode, event::ModifyKind, event::RenameMode, EventKind,
    RecursiveMode, Watcher,
};
use tokio::io::AsyncWriteExt;
use tokio::net::{UnixListener, UnixStream};
use tracing::{error, info, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use anyhow::{Context, Result};
use localsend::models::device::DeviceInfo;
use localsend::{
    current_network_binding,
    ports::{DISCOVERY_PORT, TRANSFER_PORT},
    Client, TlsIdentity,
};
use openssl::{
    asn1::Asn1Time,
    bn::{BigNum, MsbOption},
    hash::MessageDigest,
    nid::Nid,
    pkey::PKey,
    rsa::Rsa,
    x509::{
        extension::{
            AuthorityKeyIdentifier, BasicConstraints, ExtendedKeyUsage, KeyUsage,
            SubjectAlternativeName, SubjectKeyIdentifier,
        },
        X509NameBuilder, X509,
    },
};
use std::fs;
use std::net::Ipv4Addr;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, Mutex};

mod config;
mod domain;
mod events;
mod history;
mod ipc;
mod logging;
mod protocol;
mod transfers;

use config::ConfigStore;
use domain::TransferSource;
use history::HistoryStore;
use ipc::DaemonServices;
use logging::{LogDecision, RepeatedErrorLimiter, SizeRotatingWriter};
use protocol::LegacyCommand;

const UDS_PATH: &str = "\0airsend_ipc";

const LOG_FILE: &str = "airsend_daemon.log";
const DEFAULT_DATA_DIR: &str = "/data/adb/airsend";
const DEFAULT_LOG_DIR: &str = "/data/local/tmp";
const LOG_MAX_BYTES: u64 = 4 * 1024 * 1024;
const LOG_BACKUP_COUNT: usize = 3;
const CLIPBOARD_PUSH_DEDUP_WINDOW: Duration = Duration::from_secs(3);
static LAST_CLIPBOARD_PUSH: OnceLock<Mutex<Option<(String, Instant)>>> = OnceLock::new();
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

fn data_dir() -> PathBuf {
    std::env::var_os("AIRSEND_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_DATA_DIR))
}

fn log_dir() -> PathBuf {
    std::env::var_os("AIRSEND_LOG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_LOG_DIR))
}

fn write_private_file(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    fs::write(path, bytes).with_context(|| format!("Failed to write {}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .with_context(|| format!("Failed to chmod {}", path.display()))?;
    Ok(())
}

fn load_tls_identity() -> Result<PreparedTlsIdentity> {
    let cert_path = data_dir().join("server-cert.pem");
    let key_path = data_dir().join("server-key.pem");
    let cert_pem =
        fs::read(&cert_path).with_context(|| format!("Failed to read {}", cert_path.display()))?;
    let key_pem =
        fs::read(&key_path).with_context(|| format!("Failed to read {}", key_path.display()))?;
    let cert = X509::from_pem(&cert_pem).context("Failed to parse TLS certificate PEM")?;
    let fingerprint = fingerprint_for_cert(&cert)?;

    Ok(PreparedTlsIdentity {
        cert_pem,
        key_pem,
        fingerprint,
    })
}

fn generate_tls_identity() -> Result<PreparedTlsIdentity> {
    let data_dir = data_dir();
    fs::create_dir_all(&data_dir)
        .with_context(|| format!("Failed to create {}", data_dir.display()))?;
    fs::set_permissions(&data_dir, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("Failed to chmod {}", data_dir.display()))?;

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
    let serial = serial
        .to_asn1_integer()
        .context("Failed to encode certificate serial")?;

    let mut builder = X509::builder().context("Failed to create X509 builder")?;
    builder
        .set_version(2)
        .context("Failed to set X509 version")?;
    builder
        .set_serial_number(&serial)
        .context("Failed to set certificate serial")?;
    builder
        .set_subject_name(&name)
        .context("Failed to set subject name")?;
    builder
        .set_issuer_name(&name)
        .context("Failed to set issuer name")?;
    builder
        .set_pubkey(&pkey)
        .context("Failed to set public key")?;

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

    write_private_file(&data_dir.join("server-cert.pem"), &cert_pem, 0o644)?;
    write_private_file(&data_dir.join("server-key.pem"), &key_pem, 0o600)?;

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

    let (_log_guard, log_writer) = init_logging()?;
    info!("AirSend Daemon 启动 (LocalSend v0.2.2 兼容模式)");

    let data_dir = data_dir();
    fs::create_dir_all(&data_dir)
        .with_context(|| format!("Failed to create {}", data_dir.display()))?;
    let config_store = ConfigStore::new(data_dir.join("config.json"));
    let config_outcome = config_store
        .load_with_recovery()
        .context("Failed to load AirSend configuration")?;
    if let Some(warning) = config_outcome.warning.as_deref() {
        warn!("{warning}");
    }
    config_store
        .save(&config_outcome.config)
        .context("Failed to persist normalized AirSend configuration")?;
    let runtime_config = config_outcome.config;
    let health_warnings = config_outcome.warning.into_iter().collect::<Vec<_>>();
    let history_store = Arc::new(
        HistoryStore::open(
            data_dir.join("history.db"),
            runtime_config.history_limit_per_direction,
        )
        .context("Failed to open AirSend transfer history")?,
    );

    // 1. 强制前置：优先向内核注册 UDS，建立 IPC 物理接收端点
    let listener = UnixListener::bind(UDS_PATH)
        .context(format!("Failed to bind abstract UDS: {:?}", UDS_PATH))?;
    info!("🚀 Successfully bound to UDS: {}", UDS_PATH);

    let tls_identity =
        load_or_create_tls_identity().context("Failed to initialize TLS identity")?;
    info!("🔐 TLS 设备指纹: {}", tls_identity.fingerprint);
    let device_info = DeviceInfo::headless_with_identity(tls_identity.fingerprint.clone(), "https");
    let services = Arc::new(DaemonServices::new(
        config_store,
        runtime_config.clone(),
        history_store,
        log_writer,
        health_warnings,
        tls_identity.fingerprint.clone(),
        "https",
    ));

    // 2. 🛡️ 引入韧性轮询：等待系统网络底层设备 (wlan0/tun0) 挂载完成
    let mut startup_error_limiter = RepeatedErrorLimiter::new(Duration::from_secs(30));
    let mut client = loop {
        match Client::with_config(
            device_info.clone(),
            TRANSFER_PORT,
            DISCOVERY_PORT,
            runtime_config.download_destination.clone(),
        )
        .await
        {
            Ok(c) => {
                tracing::info!("🌐 网络设备就绪，LocalSend 客户端初始化成功！");
                break c;
            }
            Err(error) => {
                match startup_error_limiter.record("network_not_ready", Instant::now()) {
                    LogDecision::Emit => {
                        tracing::warn!("等待局域网接口就绪: {}... 2秒后重试", error);
                    }
                    LogDecision::EmitSummary { suppressed } => {
                        tracing::warn!(
                            "等待局域网接口就绪: {}（过去 30 秒抑制 {} 条重复错误）",
                            error,
                            suppressed
                        );
                    }
                    LogDecision::Suppress => {}
                }
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
        }
    };

    // 原有的构建 HTTP Client 逻辑保持不变
    let http_client_builder = reqwest::Client::builder()
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
    client.tls_identity = Some(TlsIdentity {
        cert_pem: tls_identity.cert_pem,
        key_pem: tls_identity.key_pem,
    });
    client.incoming_handler = Some(services.clone());

    let state = Arc::new(AppState { client, services });

    // 🚀 点火：启动底层物理监控协程
    if std::env::var_os("AIRSEND_DATA_DIR").is_none() {
        spawn_physical_watcher(state.clone());
    } else {
        info!("应用沙箱模式使用 Android MediaStore 截图观察器");
    }

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
                    if let Err(e) = ipc::handle_client(stream, state_clone).await {
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
    services: Arc<DaemonServices>,
}

fn spawn_network_rebind_watcher(initial_binding: (Option<String>, Ipv4Addr)) {
    tokio::spawn(async move {
        let mut pending_binding: Option<((String, Ipv4Addr), u8)> = None;
        loop {
            tokio::time::sleep(Duration::from_secs(3)).await;

            let Some((interface, ipv4)) = current_network_binding() else {
                continue;
            };
            if interface == "system_route" {
                continue;
            }

            let binding_changed = initial_binding.0.as_deref() != Some(interface.as_str())
                || initial_binding.1 != ipv4;
            if !binding_changed {
                pending_binding = None;
                continue;
            }

            let candidate = (interface.clone(), ipv4);
            let confirmations = match pending_binding.as_mut() {
                Some((pending, confirmations)) if *pending == candidate => {
                    *confirmations = confirmations.saturating_add(1);
                    *confirmations
                }
                _ => {
                    pending_binding = Some((candidate, 1));
                    1
                }
            };
            if confirmations < 3 {
                tracing::debug!(
                    "等待网络绑定稳定: {}/{}（{}/3）",
                    interface,
                    ipv4,
                    confirmations
                );
                continue;
            }

            warn!(
                "🔄 网络绑定已连续稳定确认: {:?}/{:?} -> {}/{}. 准备重启 daemon 以重绑局域网 socket",
                initial_binding.0, initial_binding.1, interface, ipv4
            );

            if supervisor_owns_lifecycle() {
                warn!("♻️ root supervisor 将接管 daemon 重启");
            } else if let Err(err) = schedule_self_restart() {
                error!("❌ 计划重启 daemon 失败: {err:#}");
                continue;
            }

            warn!("♻️ 旧 daemon 退出，等待生命周期管理者接管");
            std::process::exit(0);
        }
    });
}

pub(crate) fn supervisor_owns_lifecycle() -> bool {
    std::env::var_os("AIRSEND_DATA_DIR").is_none()
}

pub(crate) fn schedule_self_restart() -> Result<()> {
    if supervisor_owns_lifecycle() {
        return Ok(());
    }
    let daemon_bin = std::env::current_exe().context("failed to resolve current daemon path")?;
    let log_file = log_dir().join(LOG_FILE);
    let script = format!(
        "sleep 1; nohup '{}' >> '{}' 2>&1 &",
        daemon_bin.display(),
        log_file.display()
    );

    let shell = if cfg!(target_os = "android") {
        "/system/bin/sh"
    } else {
        "sh"
    };
    Command::new(shell)
        .args(["-c", &script])
        .spawn()
        .context("failed to spawn daemon restart helper")?;

    Ok(())
}

// 确保你传入了包含 LocalSend 客户端的 state
fn spawn_physical_watcher(state: Arc<AppState>) {
    // 1. 创建 Tokio 原生的异步 Channel，桥接同步内核中断与异步运行时
    let (tx, mut rx) = mpsc::unbounded_channel();

    // 2. 将 notify 的事件回调闭包安全推入异步 Channel
    let mut watcher = notify::recommended_watcher(move |res| {
        let _ = tx.send(res);
    })
    .expect("Failed to create inotify watcher");

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
                    let is_target_event = matches!(
                        event.kind,
                        EventKind::Access(AccessKind::Close(AccessMode::Write))
                            | EventKind::Modify(ModifyKind::Name(RenameMode::To))
                            | EventKind::Modify(ModifyKind::Name(RenameMode::Both))
                    );

                    if is_target_event {
                        if let Some(path_buf) = event.paths.first() {
                            let path_str = path_buf.to_string_lossy().to_string();

                            // 强力过滤系统 IO 碎片文件
                            if path_str.ends_with(".tmp")
                                || path_str.ends_with(".pending")
                                || path_buf
                                    .file_name()
                                    .unwrap_or_default()
                                    .to_string_lossy()
                                    .starts_with(".")
                            {
                                continue;
                            }

                            tracing::info!("📸 底层捕获截图物理落盘: {}", path_str);

                            let state_clone = state.clone();
                            tokio::spawn(async move {
                                // 🔋 灵魂延时：等待 EXT4 Page Cache 刷盘，彻底消灭 0 字节鬼影文件
                                tokio::time::sleep(std::time::Duration::from_millis(1000)).await;

                                let config = state_clone.services.config().await;
                                if !config.screenshot_sync_enabled {
                                    tracing::debug!("截图同步已关闭，忽略 {}", path_str);
                                    return;
                                }
                                let Some(target_id) =
                                    trusted_automatic_target(&state_clone, config.preferred_target)
                                        .await
                                else {
                                    tracing::warn!("截图同步未发送：没有可信的默认目标");
                                    return;
                                };

                                tracing::info!("🚀 正在向可信默认目标发送截图: {}", path_str);

                                if let Err(error) = ipc::queue_background_file(
                                    &state_clone,
                                    target_id,
                                    PathBuf::from(&path_str),
                                    TransferSource::Screenshot,
                                )
                                .await
                                {
                                    tracing::error!("❌ 截图发送入队失败: {error:#}");
                                }
                            });
                        }
                    }
                }
                Err(e) => tracing::error!("inotify watch error: {:?}", e),
            }
        }
    });
}

fn init_logging() -> Result<(
    tracing_appender::non_blocking::WorkerGuard,
    SizeRotatingWriter,
)> {
    let log_path = log_dir().join(LOG_FILE);
    let writer = SizeRotatingWriter::new(log_path, LOG_MAX_BYTES, LOG_BACKUP_COUNT)?;
    let (non_blocking, guard) = tracing_appender::non_blocking(writer.clone());

    // 允许使用 RUST_LOG=trace 从环境变量动态控制级别
    let env_filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::registry()
        .with(env_filter)
        // 输出到文件 (无颜色)
        .with(
            tracing_subscriber::fmt::layer()
                .with_writer(non_blocking)
                .with_ansi(false),
        )
        // 🔋 后台守护进程无需终端输出（service.sh 已将 stdout 重定向到日志文件）
        .init();

    Ok((guard, writer))
}

pub(crate) async fn process_command(command: LegacyCommand, state: &Arc<AppState>) -> Result<()> {
    match command {
        LegacyCommand::GetPeers => {}
        LegacyCommand::SendText {
            target_id,
            text,
            source,
        } => {
            if text.trim().is_empty() {
                tracing::debug!("Ignoring an empty text transfer");
                return Ok(());
            }
            let source = legacy_transfer_source(source.as_deref(), TransferSource::Clipboard);
            let target_id = if target_id.is_some() {
                target_id
            } else {
                let config = state.services.config().await;
                if source == TransferSource::Clipboard && !config.clipboard_sync_enabled {
                    tracing::debug!("剪贴板自动同步已关闭");
                    return Ok(());
                }
                trusted_automatic_target(state, config.preferred_target).await
            };
            let Some(target_id) = target_id else {
                tracing::warn!("剪贴板同步未发送：没有可信的默认目标");
                return Ok(());
            };
            ipc::queue_background_text(state, target_id, text, source).await?;
        }
        LegacyCommand::SendFile {
            target_id,
            path,
            source,
        } => {
            let source = legacy_transfer_source(source.as_deref(), TransferSource::Screenshot);
            let target_id = if target_id.is_some() {
                target_id
            } else {
                let config = state.services.config().await;
                if source == TransferSource::Screenshot && !config.screenshot_sync_enabled {
                    tracing::debug!("截图自动同步已关闭");
                    return Ok(());
                }
                trusted_automatic_target(state, config.preferred_target).await
            };
            let Some(target_id) = target_id else {
                tracing::warn!("自动文件同步未发送：没有可信的默认目标");
                return Ok(());
            };
            ipc::queue_background_file(state, target_id, PathBuf::from(path), source).await?;
        }
    }
    Ok(())
}

fn legacy_transfer_source(source: Option<&str>, fallback: TransferSource) -> TransferSource {
    match source {
        Some("app_picker") => TransferSource::AppPicker,
        Some("clipboard") => TransferSource::Clipboard,
        Some("share_sheet") => TransferSource::ShareSheet,
        Some("screenshot") => TransferSource::Screenshot,
        _ => fallback,
    }
}

async fn trusted_automatic_target(state: &AppState, target_id: Option<String>) -> Option<String> {
    let target_id = target_id?.trim().to_string();
    if target_id.is_empty() {
        return None;
    }
    let peer_fingerprint = state
        .client
        .peers
        .lock()
        .await
        .get(&target_id)
        .map(|(_, peer)| peer.fingerprint.clone())
        .unwrap_or_else(|| target_id.clone());
    let trusted = state
        .services
        .config()
        .await
        .trusted_peer_fingerprints
        .iter()
        .any(|fingerprint| fingerprint.eq_ignore_ascii_case(&peer_fingerprint));
    trusted.then_some(target_id)
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

// 逆向推送管道：将接收到的文本击穿回 Android App 层
pub async fn push_text_to_app(text: &str) -> anyhow::Result<()> {
    let last_push = LAST_CLIPBOARD_PUSH.get_or_init(|| Mutex::new(None));
    let mut last_push = last_push.lock().await;
    let now = Instant::now();
    if last_push.as_ref().is_some_and(|(previous, pushed_at)| {
        previous == text && now.duration_since(*pushed_at) < CLIPBOARD_PUSH_DEDUP_WINDOW
    }) {
        tracing::debug!("忽略短时间内重复的剪贴板推送");
        return Ok(());
    }

    tracing::info!("🔄 准备向 Android App 推送剪贴板数据...");

    // 连接到 App 侧建立的抽象命名空间 Socket
    let mut stream = UnixStream::connect("\0airsend_app_ipc")
        .await
        .context("Failed to connect to App's reverse IPC socket (\\0airsend_app_ipc)")?;

    stream.write_all(text.as_bytes()).await?;
    stream.shutdown().await?; // 显式关闭发送端，触发 App 侧的 readText() 结束
    *last_push = Some((text.to_string(), now));

    tracing::info!("✅ 成功将文本推送到 Android App");
    Ok(())
}
