use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const IPC_PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RequestEnvelope {
    pub id: String,
    pub op: String,
    #[serde(default = "empty_object")]
    pub payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IpcError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ResponseEnvelope {
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<IpcError>,
}

impl ResponseEnvelope {
    pub fn success(id: impl Into<String>, data: Value) -> Self {
        Self {
            id: id.into(),
            ok: true,
            data: Some(data),
            error: None,
        }
    }

    pub fn error(
        id: impl Into<String>,
        code: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            ok: false,
            data: None,
            error: Some(IpcError {
                code: code.into(),
                message: message.into(),
            }),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EventEnvelope {
    pub event: String,
    pub sequence: u64,
    pub data: Value,
}

impl EventEnvelope {
    pub fn new(event: impl Into<String>, sequence: u64, data: Value) -> Self {
        Self {
            event: event.into(),
            sequence,
            data,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LegacyCommand {
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

#[derive(Debug, Clone, PartialEq)]
pub enum ParsedLine {
    Request(RequestEnvelope),
    Legacy(LegacyCommand),
}

#[derive(Debug, Deserialize)]
struct LegacyJsonCommand {
    op: String,
    #[serde(default, rename = "targetId")]
    target_id: Option<String>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    path: Option<String>,
}

impl ParsedLine {
    pub fn parse(raw: &str) -> Result<Self> {
        if let Ok(request) = serde_json::from_str::<RequestEnvelope>(raw) {
            return Ok(Self::Request(request));
        }

        if let Ok(command) = serde_json::from_str::<LegacyJsonCommand>(raw) {
            return parse_legacy_json(command).map(Self::Legacy);
        }

        parse_legacy_text(raw).map(Self::Legacy)
    }
}

fn parse_legacy_json(command: LegacyJsonCommand) -> Result<LegacyCommand> {
    match command.op.as_str() {
        "get_peers" => Ok(LegacyCommand::GetPeers),
        "send_text" => Ok(LegacyCommand::SendText {
            target_id: command.target_id,
            text: command
                .text
                .ok_or_else(|| anyhow!("Missing text payload"))?,
        }),
        "send_file" => Ok(LegacyCommand::SendFile {
            target_id: command.target_id,
            path: command
                .path
                .ok_or_else(|| anyhow!("Missing path payload"))?,
        }),
        _ => Err(anyhow!("Unknown IPC op: {}", command.op)),
    }
}

fn parse_legacy_text(raw: &str) -> Result<LegacyCommand> {
    if raw == "GET_PEERS" {
        return Ok(LegacyCommand::GetPeers);
    }

    if let Some(text) = raw.strip_prefix("SEND_TEXT:") {
        return Ok(LegacyCommand::SendText {
            target_id: None,
            text: text.to_string(),
        });
    }

    if let Some(rest) = raw.strip_prefix("SEND_TEXT_TO:") {
        let (target_id, text) = rest
            .split_once(':')
            .ok_or_else(|| anyhow!("Malformed SEND_TEXT_TO command"))?;
        return Ok(LegacyCommand::SendText {
            target_id: Some(target_id.to_string()),
            text: text.to_string(),
        });
    }

    if let Some(path) = raw.strip_prefix("SEND_FILE:") {
        return Ok(LegacyCommand::SendFile {
            target_id: None,
            path: path.to_string(),
        });
    }

    if let Some(rest) = raw.strip_prefix("SEND_FILE_TO:") {
        let (target_id, path) = rest
            .split_once(':')
            .ok_or_else(|| anyhow!("Malformed SEND_FILE_TO command"))?;
        return Ok(LegacyCommand::SendFile {
            target_id: Some(target_id.to_string()),
            path: path.to_string(),
        });
    }

    Err(anyhow!("Unknown IPC command"))
}

fn empty_object() -> Value {
    Value::Object(serde_json::Map::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_versioned_request_envelope() {
        let parsed = ParsedLine::parse(r#"{"id":"req-1","op":"hello","payload":{}}"#).unwrap();

        assert!(matches!(
            parsed,
            ParsedLine::Request(RequestEnvelope { id, op, .. })
                if id == "req-1" && op == "hello"
        ));
    }

    #[test]
    fn response_error_keeps_request_id() {
        let value = serde_json::to_value(ResponseEnvelope::error(
            "req-2",
            "target_offline",
            "Target is offline",
        ))
        .unwrap();

        assert_eq!(value["id"], "req-2");
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "target_offline");
    }

    #[test]
    fn event_envelope_keeps_sequence_and_payload() {
        let event = EventEnvelope::new("state_changed", 7, serde_json::json!({"reachable": true}));
        let value = serde_json::to_value(event).unwrap();

        assert_eq!(value["event"], "state_changed");
        assert_eq!(value["sequence"], 7);
        assert_eq!(value["data"]["reachable"], true);
    }

    #[test]
    fn legacy_text_keeps_colons_and_whitespace() {
        let parsed = ParsedLine::parse("SEND_TEXT_TO:peer-1:  https://a:b  ").unwrap();

        assert!(matches!(
            parsed,
            ParsedLine::Legacy(LegacyCommand::SendText {
                target_id: Some(id),
                text,
            }) if id == "peer-1" && text == "  https://a:b  "
        ));
    }

    #[test]
    fn legacy_json_without_request_id_still_parses() {
        let parsed =
            ParsedLine::parse(r#"{"op":"send_file","targetId":"peer-2","path":"/sdcard/a:b.txt"}"#)
                .unwrap();

        assert!(matches!(
            parsed,
            ParsedLine::Legacy(LegacyCommand::SendFile {
                target_id: Some(id),
                path,
            }) if id == "peer-2" && path == "/sdcard/a:b.txt"
        ));
    }

    #[test]
    fn legacy_json_text_keeps_multiline_payload() {
        let parsed =
            ParsedLine::parse(r#"{"op":"send_text","targetId":"peer-1","text":"line1\nline2\n "}"#)
                .unwrap();

        assert_eq!(
            parsed,
            ParsedLine::Legacy(LegacyCommand::SendText {
                target_id: Some("peer-1".to_string()),
                text: "line1\nline2\n ".to_string(),
            })
        );
    }
}
