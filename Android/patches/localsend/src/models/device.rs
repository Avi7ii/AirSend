use serde::{Deserialize, Serialize};
use uuid::Uuid;
use std::process::Command;

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "lowercase")]
pub enum DeviceType {
    Mobile,
    Desktop,
    Web,
    Headless,
    Server,
    Unknown,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub alias: String,
    pub version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_type: Option<DeviceType>,
    pub fingerprint: String,
    pub port: u16,
    pub protocol: String,
    #[serde(default)]
    pub download: bool,
    #[serde(default)]
    pub announce: Option<bool>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    Http,
    Https,
}

impl Default for DeviceInfo {
    fn default() -> Self {
        fn collapse_spaces(value: &str) -> String {
            value.split_whitespace().collect::<Vec<_>>().join(" ")
        }
        
        fn normalize_model_display(raw: &str) -> String {
            let mut value = collapse_spaces(raw.trim());
            if value.contains("一加") {
                value = value.replace("一加", "OnePlus");
            }
            if let Some(rest) = value.strip_prefix("OnePlus") {
                let rest = rest.trim();
                if !rest.is_empty() {
                    value = format!("OnePlus {}", rest);
                } else {
                    value = "OnePlus".to_string();
                }
            }
            value
        }
        
        fn read_prop(key: &str) -> Option<String> {
            Command::new("getprop")
                .arg(key)
                .output()
                .ok()
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .map(|s| normalize_model_display(&s))
                .filter(|s| {
                    !s.is_empty()
                        && !s.eq_ignore_ascii_case("unknown")
                        && !s.eq_ignore_ascii_case("null")
                })
        }
        
        fn codename_to_marketing_name(value: &str) -> Option<&'static str> {
            match value.trim().to_ascii_lowercase().as_str() {
                // OnePlus 13T codename
                "ossi" | "pkx110" | "op60f5l1" => Some("OnePlus 13T"),
                _ => None,
            }
        }
        
        fn is_likely_codename(value: &str) -> bool {
            let candidate = value.trim();
            if candidate.is_empty() || candidate.contains(' ') {
                return false;
            }
            candidate.len() >= 3
                && candidate.len() <= 12
                && candidate.chars().all(|c| c.is_ascii_lowercase() || c == '_' || c == '-')
        }
        
        fn detect_model_name() -> Option<String> {
            let preferred_keys = [
                "ro.vendor.oplus.market.name",
                "ro.oplus.market.name",
                "ro.vendor.oplus.marketname",
                "ro.oplus.marketname",
                "ro.vendor.oplus.display_name",
                "ro.oplus.display_name",
                "ro.product.marketname",
                "ro.product.vendor.marketname",
                "ro.vendor.product.marketname",
                "ro.product.odm.marketname",
            ];
            let fallback_keys = [
                "ro.product.vendor.model",
                "ro.product.model",
                "ro.vendor.product.model",
                "ro.product.odm.model",
                "ro.product.product.model",
                "ro.product.system.model",
                "ro.product.name",
                "ro.build.product",
                "ro.product.device",
                "ro.product.system.device",
            ];
            
            let mut codename_fallback: Option<String> = None;
            for key in preferred_keys.into_iter().chain(fallback_keys) {
                let Some(raw_value) = read_prop(key) else {
                    continue;
                };
                
                if let Some(mapped) = codename_to_marketing_name(&raw_value) {
                    return Some(mapped.to_string());
                }
                
                if is_likely_codename(&raw_value) {
                    codename_fallback.get_or_insert(raw_value);
                    continue;
                }
                
                return Some(raw_value);
            }
            
            codename_fallback.and_then(|value| codename_to_marketing_name(&value).map(str::to_string))
        }
        
        let model = detect_model_name();

        Self {
            alias: "AirSend Android Module".to_string(),
            version: "2.4.1".to_string(),
            device_model: model,
            device_type: Some(DeviceType::Headless),
            fingerprint: Uuid::new_v4().to_string(),
            port: 53317,
            protocol: "https".to_string(),
            download: true,
            announce: Some(true),
        }
    }
}

impl DeviceInfo {
    pub fn to_json(&self) -> crate::error::Result<String> {
        Ok(serde_json::to_string(self)?)
    }
}
