# AirSend Root Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Root-mode foundation that gives Android truthful daemon responses, versioned state, persistent configuration and history, bounded logs, and reboot-safe packaging.

**Architecture:** Split the Rust daemon's monolithic command handling into protocol, configuration, history, logging, state, and IPC units. Keep the patched LocalSend crate responsible for network transport while the daemon owns product state. Replace Android's direct fire-and-forget socket calls with a typed request client and immutable state flow.

**Tech Stack:** Rust 2021, Tokio, serde, rusqlite, tracing, Kotlin, kotlinx.serialization, coroutines, Koin, JUnit, Android LocalSocket, Gradle, cargo-ndk, ADB.

---

## File Map

### Rust daemon

- Create `Android/airsend_daemon/src/protocol.rs`: typed IPC envelopes, errors,
  events, legacy command compatibility, and protocol tests.
- Create `Android/airsend_daemon/src/config.rs`: versioned configuration,
  validation, atomic persistence, corrupt-file recovery, and tests.
- Create `Android/airsend_daemon/src/domain.rs`: shared peer, health, transfer,
  and history domain models.
- Create `Android/airsend_daemon/src/history.rs`: SQLite schema, retention,
  queries, deletion, and tests.
- Create `Android/airsend_daemon/src/logging.rs`: size rotation, repeated-error
  limiter, log clearing, and tests.
- Create `Android/airsend_daemon/src/events.rs`: ordered broadcast event hub.
- Create `Android/airsend_daemon/src/ipc.rs`: request dispatch and subscribed
  event delivery over the abstract Unix socket.
- Modify `Android/airsend_daemon/src/main.rs`: compose services and delegate IPC.
- Modify `Android/airsend_daemon/Cargo.toml`: align daemon version with AirSend
  `3.5.1`, then add SQLite and test dependencies.

### Android app

- Create `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendIpcModels.kt`:
  serializable protocol and snapshot models.
- Create `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendIpcClient.kt`:
  request and subscription contract.
- Create `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/LocalSocketAirSendIpcClient.kt`:
  reconnecting Android LocalSocket implementation.
- Modify `AirSendRuntimeRepositoryImpl.kt`, `AirSendRuntimeRepository.kt`, and
  `AirSendRuntimeState.kt`: consume daemon snapshots and truthful responses.
- Modify `SettingsModule.kt`: bind the IPC client.
- Modify `Android/app/build.gradle.kts`: add the coroutine test dependency used
  by repository behavior tests.
- Create behavioral tests under
  `Android/app/src/test/kotlin/com/rosan/installer/ui/page/airsend/runtime/`.

### Packaging

- Modify `magisk_module/service.sh`: compare version codes instead of APK hashes.
- Modify `build_magisk_payload.sh`: verify copied APK and daemon payloads.
- Create `tools/test_magisk_service_version_guard.sh`: shell regression tests.
- Modify `.github/workflows/ci.yml`: run the new shell test.

## Task 1: Versioned IPC Protocol

**Files:**
- Create: `Android/airsend_daemon/src/protocol.rs`
- Modify: `Android/airsend_daemon/src/main.rs`
- Test: `Android/airsend_daemon/src/protocol.rs`

- [ ] **Step 1: Write failing protocol tests**

Add tests that require request IDs, structured errors, event sequences, and
legacy payload preservation:

```rust
#[test]
fn parses_versioned_request_envelope() {
    let parsed = ParsedLine::parse(
        r#"{"id":"req-1","op":"hello","payload":{}}"#,
    ).unwrap();
    assert!(matches!(parsed, ParsedLine::Request(RequestEnvelope { id, op, .. })
        if id == "req-1" && op == "hello"));
}

#[test]
fn response_error_keeps_request_id() {
    let value = serde_json::to_value(ResponseEnvelope::error(
        "req-2",
        "target_offline",
        "Target is offline",
    )).unwrap();
    assert_eq!(value["id"], "req-2");
    assert_eq!(value["ok"], false);
    assert_eq!(value["error"]["code"], "target_offline");
}

#[test]
fn legacy_text_keeps_colons_and_whitespace() {
    let parsed = ParsedLine::parse("SEND_TEXT_TO:peer-1:  https://a:b  ").unwrap();
    assert!(matches!(parsed, ParsedLine::Legacy(LegacyCommand::SendText {
        target_id: Some(id), text
    }) if id == "peer-1" && text == "  https://a:b  "));
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
cd Android/airsend_daemon
cargo test protocol -- --nocapture
```

Expected: compilation fails because `protocol` and its envelope types do not
exist.

- [ ] **Step 3: Implement protocol types and compatibility parser**

Create these public contracts:

```rust
pub const IPC_PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RequestEnvelope {
    pub id: String,
    pub op: String,
    #[serde(default)]
    pub payload: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct IpcError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ResponseEnvelope {
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<IpcError>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EventEnvelope {
    pub event: String,
    pub sequence: u64,
    pub data: serde_json::Value,
}
```

Move the current legacy command parser out of `main.rs`, preserving all current
legacy syntax exactly.

- [ ] **Step 4: Run protocol and daemon tests**

Run:

```bash
cd Android/airsend_daemon
cargo test --locked
```

Expected: all protocol and existing legacy tests pass.

- [ ] **Step 5: Commit protocol task**

```bash
git add Android/airsend_daemon/src/protocol.rs Android/airsend_daemon/src/main.rs
git commit -m "feat(android): add versioned daemon IPC protocol"
```

## Task 2: Persistent Runtime Configuration

**Files:**
- Create: `Android/airsend_daemon/src/config.rs`
- Modify: `Android/airsend_daemon/src/main.rs`
- Modify: `Android/airsend_daemon/Cargo.toml`
- Test: `Android/airsend_daemon/src/config.rs`

- [ ] **Step 1: Write failing configuration tests**

```rust
#[test]
fn round_trips_valid_config_atomically() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.json");
    let store = ConfigStore::new(path.clone());
    let mut config = AirSendConfig::default();
    config.clipboard_sync_enabled = false;
    config.receive_policy = ReceivePolicy::TrustedOnly;
    store.save(&config).unwrap();
    assert_eq!(store.load().unwrap(), config);
    assert!(!path.with_extension("json.tmp").exists());
}

#[test]
fn corrupt_config_is_preserved_and_defaults_are_loaded() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.json");
    std::fs::write(&path, b"not-json").unwrap();
    let outcome = ConfigStore::new(path).load_with_recovery().unwrap();
    assert_eq!(outcome.config, AirSendConfig::default());
    assert!(outcome.warning.is_some());
    assert!(temp.path().read_dir().unwrap().any(|entry| {
        entry.unwrap().file_name().to_string_lossy().contains("corrupt")
    }));
}
```

- [ ] **Step 2: Run tests and verify RED**

```bash
cd Android/airsend_daemon
cargo test config -- --nocapture
```

Expected: `ConfigStore` and `AirSendConfig` are missing.

- [ ] **Step 3: Implement validated config and atomic store**

Define:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReceivePolicy { Ask, TrustedOnly, Off }

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TransportPreference { Https, HttpCompatibility }

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AirSendConfig {
    pub version: u32,
    pub preferred_target: Option<String>,
    pub manual_peers: Vec<ManualPeer>,
    pub trusted_peer_fingerprints: Vec<String>,
    pub receive_policy: ReceivePolicy,
    pub clipboard_sync_enabled: bool,
    pub screenshot_sync_enabled: bool,
    pub startup_enabled: bool,
    pub download_destination: String,
    pub media_destination: String,
    pub transport_preference: TransportPreference,
}
```

Validate absolute shared-storage destinations, normalize duplicate peers and
fingerprints, write a same-directory temporary file, `sync_all`, rename, and
apply mode `0600`.

- [ ] **Step 4: Run tests and formatting**

```bash
cd Android/airsend_daemon
cargo fmt --check
cargo test config -- --nocapture
```

Expected: configuration tests pass.

- [ ] **Step 5: Commit configuration task**

```bash
git add Android/airsend_daemon/Cargo.toml Android/airsend_daemon/Cargo.lock Android/airsend_daemon/src/config.rs Android/airsend_daemon/src/main.rs
git commit -m "feat(android): persist daemon runtime configuration"
```

## Task 3: Persistent Transfer History

**Files:**
- Create: `Android/airsend_daemon/src/domain.rs`
- Create: `Android/airsend_daemon/src/history.rs`
- Modify: `Android/airsend_daemon/Cargo.toml`
- Modify: `Android/airsend_daemon/src/main.rs`
- Test: `Android/airsend_daemon/src/history.rs`

- [ ] **Step 1: Write failing history tests**

```rust
#[test]
fn inserts_queries_deletes_and_caps_history() {
    let temp = tempfile::tempdir().unwrap();
    let store = HistoryStore::open(temp.path().join("history.db"), 3).unwrap();
    for index in 0..5 {
        store.insert(&HistoryRecord::completed_for_test(index)).unwrap();
    }
    let records = store.list(20).unwrap();
    assert_eq!(records.len(), 3);
    assert!(records[0].started_at_ms > records[1].started_at_ms);
    store.delete(&records[0].id).unwrap();
    assert_eq!(store.list(20).unwrap().len(), 2);
    store.clear().unwrap();
    assert!(store.list(20).unwrap().is_empty());
}
```

- [ ] **Step 2: Run tests and verify RED**

```bash
cd Android/airsend_daemon
cargo test history -- --nocapture
```

Expected: history types are missing.

- [ ] **Step 3: Implement domain records and SQLite store**

Add `rusqlite = { version = "0.32", features = ["bundled"] }` and define a
terminal record with stable ID, direction, source, peer identity, serialized
file summaries, byte totals, status, timestamps, saved paths, and structured
error fields. Create schema version `1`, parameterized SQL only, newest-first
queries, and retention deletion inside the insert transaction.

Add `tempfile = "3"` under `[dev-dependencies]`; it must not ship in the daemon
binary. Set the daemon package version to `3.5.1` so `hello.daemonVersion` and
the module/App release line do not describe different products.

- [ ] **Step 4: Run history tests**

```bash
cd Android/airsend_daemon
cargo test history -- --nocapture
```

Expected: schema, retention, delete, and clear tests pass.

- [ ] **Step 5: Commit history task**

```bash
git add Android/airsend_daemon/Cargo.toml Android/airsend_daemon/Cargo.lock Android/airsend_daemon/src/domain.rs Android/airsend_daemon/src/history.rs Android/airsend_daemon/src/main.rs
git commit -m "feat(android): persist daemon transfer history"
```

## Task 4: Bounded and Rate-limited Daemon Logs

**Files:**
- Create: `Android/airsend_daemon/src/logging.rs`
- Modify: `Android/airsend_daemon/src/main.rs`
- Test: `Android/airsend_daemon/src/logging.rs`

- [ ] **Step 1: Write failing rotation and limiter tests**

```rust
#[test]
fn rotates_existing_and_new_log_bytes() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("airsend.log");
    std::fs::write(&path, vec![b'x'; 80]).unwrap();
    let mut writer = SizeRotatingWriter::new(path.clone(), 100, 2).unwrap();
    writer.write_all(&vec![b'y'; 40]).unwrap();
    assert!(path.with_extension("log.1").exists());
    assert!(std::fs::metadata(path).unwrap().len() <= 100);
}

#[test]
fn repeated_error_is_summarized_after_window() {
    let mut limiter = RepeatedErrorLimiter::new(Duration::from_secs(30));
    assert_eq!(limiter.record("network_unreachable", Instant::now()), LogDecision::Emit);
    assert_eq!(limiter.record("network_unreachable", Instant::now()), LogDecision::Suppress);
    assert_eq!(limiter.suppressed("network_unreachable"), 1);
}
```

- [ ] **Step 2: Run tests and verify RED**

```bash
cd Android/airsend_daemon
cargo test logging -- --nocapture
```

- [ ] **Step 3: Implement four-by-four-MiB rotation and limiter**

Use one mutex-protected writer implementing `std::io::Write`; rotate before a
write would cross `4 * 1024 * 1024`, retain `.1` through `.3`, and rotate an
oversized pre-existing log during initialization. Replace unbounded
`tracing_appender::rolling::never`. Apply the limiter to announcement and
network-rebind loops and emit one summary when a suppressed key becomes
eligible again.

- [ ] **Step 4: Run logging and daemon tests**

```bash
cd Android/airsend_daemon
cargo test --locked
```

Expected: all tests pass and no test log exceeds its configured cap.

- [ ] **Step 5: Commit logging task**

```bash
git add Android/airsend_daemon/src/logging.rs Android/airsend_daemon/src/main.rs
git commit -m "fix(android): bound and rate-limit daemon logs"
```

## Task 5: Event Hub and Request Dispatcher

**Files:**
- Create: `Android/airsend_daemon/src/events.rs`
- Create: `Android/airsend_daemon/src/ipc.rs`
- Modify: `Android/airsend_daemon/src/main.rs`
- Test: `Android/airsend_daemon/src/events.rs`
- Test: `Android/airsend_daemon/src/ipc.rs`

- [ ] **Step 1: Write failing dispatcher tests**

```rust
#[tokio::test]
async fn hello_returns_versions_and_capabilities() {
    let harness = IpcHarness::new().await;
    let response = harness.request("hello", json!({})).await;
    assert!(response.ok);
    assert_eq!(response.data.unwrap()["protocolVersion"], IPC_PROTOCOL_VERSION);
}

#[tokio::test]
async fn invalid_operation_returns_structured_error() {
    let harness = IpcHarness::new().await;
    let response = harness.request("not_real", json!({})).await;
    assert!(!response.ok);
    assert_eq!(response.error.unwrap().code, "unknown_operation");
}

#[tokio::test]
async fn subscribed_events_are_ordered() {
    let hub = EventHub::new(16);
    let mut receiver = hub.subscribe();
    hub.publish("state_changed", json!({"value": 1}));
    hub.publish("state_changed", json!({"value": 2}));
    assert_eq!(receiver.recv().await.unwrap().sequence, 1);
    assert_eq!(receiver.recv().await.unwrap().sequence, 2);
}
```

- [ ] **Step 2: Run tests and verify RED**

```bash
cd Android/airsend_daemon
cargo test ipc -- --nocapture
cargo test events -- --nocapture
```

- [ ] **Step 3: Implement service composition and dispatch**

`DaemonServices` owns `ConfigStore`, `RwLock<AirSendConfig>`, `HistoryStore`,
`EventHub`, and health warnings. `ipc::handle_client` wraps the write half in
`Arc<tokio::sync::Mutex<_>>`, responds to every versioned request, and starts
one event-forwarding task after `subscribe`. Foundation operations are
`hello`, `subscribe`, `get_state`, `get_peers`, `get_config`, `set_config`,
`get_history`, `delete_history`, `clear_history`, `get_logs`, `clear_logs`, and
existing send operations. `get_logs` returns a bounded tail and never loads an
entire rotated file into memory. Legacy commands call the same internal
handlers.

New `send_text` and `send_file` requests await network completion and return an
error if transfer fails. They do not emit a success before `send_data` returns.

- [ ] **Step 4: Run daemon tests and Clippy**

```bash
cd Android/airsend_daemon
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
```

Expected: tests and Clippy pass without warnings.

- [ ] **Step 5: Commit dispatcher task**

```bash
git add Android/airsend_daemon/src/events.rs Android/airsend_daemon/src/ipc.rs Android/airsend_daemon/src/main.rs
git commit -m "feat(android): expose daemon state through request IPC"
```

## Task 6: Typed Android IPC Client

**Files:**
- Create: `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendIpcModels.kt`
- Create: `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendIpcClient.kt`
- Create: `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/LocalSocketAirSendIpcClient.kt`
- Modify: `Android/app/build.gradle.kts`
- Test: `Android/app/src/test/kotlin/com/rosan/installer/ui/page/airsend/runtime/AirSendIpcProtocolTest.kt`

- [ ] **Step 1: Write failing Kotlin protocol tests**

```kotlin
class AirSendIpcProtocolTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun requestUsesStableEnvelope() {
        val encoded = json.encodeToString(
            AirSendIpcRequest(id = "req-1", op = "hello")
        )
        assertEquals(
            "{\"id\":\"req-1\",\"op\":\"hello\",\"payload\":{}}",
            encoded
        )
    }

    @Test
    fun daemonErrorIsNotDecodedAsSuccess() {
        val response = json.decodeFromString<AirSendIpcResponse>(
            """{"id":"req-2","ok":false,"error":{"code":"offline","message":"Offline"}}"""
        )
        assertFalse(response.ok)
        assertEquals("offline", response.error?.code)
    }
}
```

- [ ] **Step 2: Run test and verify RED**

```bash
cd Android
./gradlew :app:testDebugUnitTest --tests '*AirSendIpcProtocolTest'
```

- [ ] **Step 3: Implement serializable models and client contract**

```kotlin
@Serializable
data class AirSendIpcRequest(
    val id: String,
    val op: String,
    val payload: JsonObject = buildJsonObject {}
)

@Serializable
data class AirSendIpcError(val code: String, val message: String)

@Serializable
data class AirSendIpcResponse(
    val id: String,
    val ok: Boolean,
    val data: JsonElement? = null,
    val error: AirSendIpcError? = null
)

interface AirSendIpcClient {
    suspend fun request(op: String, payload: JsonObject = buildJsonObject {}): JsonElement
    fun events(): Flow<AirSendIpcEvent>
}
```

The LocalSocket implementation uses a unique UUID request ID, one newline per
message, exact response-ID matching, structured exceptions, bounded response
size, timeouts, and a reconnecting subscription socket.

Add `testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")`
for `runTest`; keep production coroutine APIs on the versions already resolved
through the existing Android/Koin dependency graph.

- [ ] **Step 4: Run Kotlin protocol tests**

```bash
cd Android
./gradlew :app:testDebugUnitTest --tests '*AirSendIpcProtocolTest'
```

- [ ] **Step 5: Commit Android client task**

```bash
git add Android/app/build.gradle.kts Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendIpcModels.kt Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendIpcClient.kt Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/LocalSocketAirSendIpcClient.kt Android/app/src/test/kotlin/com/rosan/installer/ui/page/airsend/runtime/AirSendIpcProtocolTest.kt
git commit -m "feat(android): add typed daemon IPC client"
```

## Task 7: Truthful Runtime Repository

**Files:**
- Modify: `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeRepository.kt`
- Modify: `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeRepositoryImpl.kt`
- Modify: `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeState.kt`
- Modify: `Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeViewModel.kt`
- Modify: `Android/app/src/main/java/com/rosan/installer/di/SettingsModule.kt`
- Test: `Android/app/src/test/kotlin/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeRepositoryTest.kt`

- [ ] **Step 1: Write failing repository behavior tests**

Use a fake `AirSendIpcClient` and a small injectable Android state reader:

```kotlin
@Test
fun refreshMapsDaemonVersionsAndWarnings() = runTest {
    val client = FakeAirSendIpcClient().apply {
        respond("hello", helloFixture(protocolVersion = 1, daemonVersion = "3.5.1"))
        respond("get_state", stateFixture(warnings = listOf("config_recovered")))
    }
    val repository = AirSendRuntimeRepositoryImpl(client, FakeAndroidRuntimeReader())
    repository.refresh()
    assertEquals(1, repository.state.value.protocolVersion)
    assertEquals("3.5.1", repository.state.value.daemonVersion)
    assertEquals(listOf("config_recovered"), repository.state.value.healthWarnings)
}

@Test
fun sendFailureIsPropagatedInsteadOfShowingSuccess() = runTest {
    val client = FakeAirSendIpcClient().apply {
        fail("send_text", code = "target_offline", message = "Target is offline")
    }
    val repository = AirSendRuntimeRepositoryImpl(client, FakeAndroidRuntimeReader())
    assertFailsWith<AirSendIpcException> { repository.sendText("hello", "peer") }
}
```

- [ ] **Step 2: Run test and verify RED**

```bash
cd Android
./gradlew :app:testDebugUnitTest --tests '*AirSendRuntimeRepositoryTest'
```

- [ ] **Step 3: Refactor repository around typed IPC**

Split Android-only checks into `AndroidRuntimeReader`; map `hello`, `get_state`,
and `get_peers` responses into one immutable state. Send methods await daemon
responses and throw structured failures. Events trigger snapshot refresh until
the later transfer-state task consumes detailed events directly. Remove raw
`JSONArray`, `OutputStreamWriter`, and direct LocalSocket code from the
repository.

- [ ] **Step 4: Run AirSend runtime tests**

```bash
cd Android
./gradlew :app:testDebugUnitTest --tests 'com.rosan.installer.ui.page.airsend.runtime.*'
```

- [ ] **Step 5: Commit repository task**

```bash
git add Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime Android/app/src/main/java/com/rosan/installer/di/SettingsModule.kt Android/app/src/test/kotlin/com/rosan/installer/ui/page/airsend/runtime
git commit -m "refactor(android): drive AirSend state from daemon responses"
```

## Task 8: Reboot-safe Module Payload

**Files:**
- Modify: `magisk_module/service.sh`
- Modify: `build_magisk_payload.sh`
- Create: `tools/test_magisk_service_version_guard.sh`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write failing shell regression test**

The test sources version comparison helpers in test mode and proves the exact
policy:

```bash
assert_eq "install" "$(decide_apk_sync missing 351)"
assert_eq "install" "$(decide_apk_sync 350 351)"
assert_eq "keep" "$(decide_apk_sync 351 351)"
assert_eq "keep" "$(decide_apk_sync 352 351)"
```

- [ ] **Step 2: Run test and verify RED**

```bash
bash tools/test_magisk_service_version_guard.sh
```

Expected: `decide_apk_sync` is missing.

- [ ] **Step 3: Implement version-code guard and payload verification**

`service.sh` reads installed version code with `dumpsys package` and reads the
payload version from the colocated module's `module.prop`; it installs only
when the app is missing or older. Android is not assumed to provide `aapt2`.
`build_magisk_payload.sh` uses the host SDK's `aapt2 dump badging` (or `apkanalyzer
manifest version-code`) to prove the built APK version code equals the module
`versionCode` before packaging. Test mode exposes pure helpers without starting
the daemon or package manager.

After `build_magisk_payload.sh` copies artifacts, verify:

```bash
test "$(shasum -a 256 "$daemon_src" | awk '{print $1}')" = \
     "$(shasum -a 256 "$DAEMON_DST" | awk '{print $1}')"
test "$(shasum -a 256 "$apk_src" | awk '{print $1}')" = \
     "$(shasum -a 256 "$APK_DST" | awk '{print $1}')"
```

- [ ] **Step 4: Run shell checks**

```bash
bash -n magisk_module/service.sh
bash -n build_magisk_payload.sh
bash tools/test_magisk_service_version_guard.sh
```

- [ ] **Step 5: Commit packaging task**

```bash
git add magisk_module/service.sh build_magisk_payload.sh tools/test_magisk_service_version_guard.sh .github/workflows/ci.yml
git commit -m "fix(android): keep newer same-version development APKs"
```

## Task 9: Foundation Verification and Root-device Installation

**Files:**
- Modify: `magisk_module/system/bin/airsend_daemon`
- Modify: `magisk_module/system/app/AirSend/AirSend.apk`
- Generate: `AirSend_Magisk_v3.5.1.zip`

The APK and zip are verification artifacts, not source commits. Only the
tracked daemon payload is staged after its device hash has been verified.

- [ ] **Step 1: Run complete source verification**

```bash
cd Android/airsend_daemon
cargo fmt --check
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings

cd ../patches/localsend
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings

cd ../../
ANDROID_HOME=/Users/thom/Library/Android/sdk \
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
./gradlew --no-daemon --max-workers=2 :app:testDebugUnitTest :app:assembleDebug
```

Expected: all commands pass.

- [ ] **Step 2: Build synchronized Root payload**

```bash
cd /Users/thom/Desktop/Localsend\ X
APK_VARIANT=debug ./build_magisk_payload.sh
```

Expected: daemon, APK, and zip are rebuilt and hash verification passes.

- [ ] **Step 3: Locate and update the installed Root module**

```bash
adb -s 6e9d5adf shell su -c \
  'find /data/adb/modules -maxdepth 2 -name module.prop -exec grep -H "id=airsend_daemon" {} \;'
```

Push the verified daemon and APK to the matching module directory, preserving
modes `0755` and `0644`, then restart only the daemon process. Do not reboot
until the app and daemon respond to protocol version `1`.

- [ ] **Step 4: Install and launch Android app**

```bash
adb -s 6e9d5adf install -r -d Android/app/build/outputs/apk/debug/app-debug.apk
adb -s 6e9d5adf shell am force-stop com.airsend
adb -s 6e9d5adf shell am start -W \
  -a android.intent.action.MAIN \
  -c android.intent.category.LAUNCHER \
  -n com.airsend/com.rosan.installer.ui.activity.LauncherAlias
adb -s 6e9d5adf shell pidof com.airsend
```

- [ ] **Step 5: Verify runtime evidence**

Verify:

```bash
adb -s 6e9d5adf shell su -c 'ps -A | grep airsend_daemon'
adb -s 6e9d5adf shell su -c 'ls -lh /data/local/tmp/airsend_daemon.log*'
adb -s 6e9d5adf logcat -d -t 1200 | \
  rg -i 'FATAL EXCEPTION|AndroidRuntime|am_crash|AirSendIpc|com\.airsend'
```

Acceptance for this checkpoint:

- app launches without crash
- daemon process uses the newly built hash
- Android state reports protocol version `1`
- an offline send returns a visible structured failure, not success
- config and history files are created with restrictive permissions
- the previous 105 MiB log is rotated and active logs remain bounded
- same-version APK decision is `keep`

- [ ] **Step 6: Stop for user verification**

Per `AGENTS.md`, report the installed foundation checkpoint and wait for user
verification before beginning outgoing transfer sessions and target selection.
