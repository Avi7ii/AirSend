use tokio::net::{UnixListener, UnixStream};
use tokio::io::{AsyncBufReadExt, BufReader, AsyncWriteExt};
use tracing::{info, error, warn, Level};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};
use notify::{Watcher, RecursiveMode, EventKind, event::ModifyKind, event::RenameMode, event::AccessKind, event::AccessMode};

use tracing_subscriber::fmt::format::FmtSpan;
use anyhow::{Result, Context};
use std::path::{Path, PathBuf};
use localsend::Client;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use localsend::models::file::FileMetadata;
use bytes::Bytes;
use std::time::Duration;
use std::process::Command;
use tokio::sync::mpsc;

const UDS_PATH: &str = "\0airsend_ipc";

const LOG_PATH: &str = "/data/local/tmp";
const LOG_FILE: &str = "airsend_daemon.log";

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

    // 2. 🛡️ 引入韧性轮询：等待系统网络底层设备 (wlan0/tun0) 挂载完成
    let mut client = loop {
        match Client::default().await {
            Ok(c) => {
                tracing::info!("🌐 网络设备就绪，LocalSend 客户端初始化成功！");
                break c;
            }
            Err(_) => {
                tracing::warn!("等待网络硬件驱动就绪 (os error 19)... 2秒后重试");
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
        }
    };

    // 原有的构建 HTTP Client 逻辑保持不变
    client.http_client = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .no_proxy() // 🔪 彻底物理切断所有内置代理探测逻辑
        .build()
        .context("Failed to build insecure HTTP client")?;

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
        let cmd = line.trim();
        if !cmd.is_empty() {
            let state_ref = state.clone();
            let cmd_owned = cmd.to_string();
            
            if cmd_owned == "GET_PEERS" {
                #[derive(serde::Serialize)]
                struct PeerDto { id: String, alias: String, device_model: String }
                
                let peers = state_ref.client.peers.lock().await;
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
            } else {
                tokio::spawn(async move {
                    if let Err(e) = process_command(&cmd_owned, &state_ref).await {
                        error!("Command failed: {} -> {:?}", cmd_owned, e);
                    }
                });
            }
        }
        line.clear();
    }
    Ok(())
}

async fn process_command(cmd: &str, state: &AppState) -> Result<()> {
    if let Some(text) = cmd.strip_prefix("SEND_TEXT:") {
        send_data(state, None, text, true).await?;
    } else if let Some(rest) = cmd.strip_prefix("SEND_TEXT_TO:") {
        if let Some(idx) = rest.find(':') {
            let target_id = &rest[..idx];
            let text = &rest[idx+1..];
            send_data(state, Some(target_id.to_string()), text, true).await?;
        }
    } else if let Some(path) = cmd.strip_prefix("SEND_FILE:") {
        send_data(state, None, path, false).await?;
    } else if let Some(rest) = cmd.strip_prefix("SEND_FILE_TO:") {
        if let Some(idx) = rest.find(':') {
            let target_id = &rest[..idx];
            let path = &rest[idx+1..];
            send_data(state, Some(target_id.to_string()), path, false).await?;
        }
    }
    Ok(())
}

async fn send_data(state: &AppState, target_id_opt: Option<String>, data: &str, is_text: bool) -> Result<()> {
    let mut retries = 0;
    // 💡 提取出 target_id 和 target_addr
    let (target_id, target_addr) = loop {
        {
            let peers = state.client.peers.lock().await;
            if let Some(tid) = &target_id_opt {
                if let Some((addr, _)) = peers.get(tid) {
                    tracing::info!("🔍 指定发送: [{}] {}", tid, addr);
                    break (tid.clone(), addr.to_string());
                }
            } else {
                if let Some((id, (addr, _))) = peers.iter().next() {
                    tracing::info!("🔍 UDP 缓存命中! 发现目标自动抓取: [{}] {}", id, addr);
                    break (id.clone(), addr.to_string());
                }
            }
        }
        if retries >= 10 { anyhow::bail!("No target found"); }
        tokio::time::sleep(Duration::from_millis(500)).await;
        retries += 1;
    };

    if is_text {
        tracing::info!("🚀 正在向 [{}] {} 发起 HTTPS 握手...", target_id, target_addr);
        // 🚨 关键修复 1：传入 target_id 而不是 target_addr
        if let Err(e) = send_text_protocol(&state.client, &target_id, data).await {
            tracing::error!("❌ HTTPS 发送彻底失败，底层错误链:\n{:#?}", e);
            return Err(e.into());
        }
    } else {
        // 🚨 关键修复 2：send_file 同样需要 target_id 作为参数
        state.client.send_file(target_id, PathBuf::from(data)).await?;
    }
    tracing::info!("✅ 发送成功！");
    Ok(())
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
