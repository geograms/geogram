//! Shared types for the Signal bridge.

use serde::{Deserialize, Serialize};

/// Authentication state machine.
/// Mirrors the states emitted to Dart via `updateAuthState`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AuthState {
    /// Bridge created but not yet configured.
    Uninitialized,
    /// Parameters set, ready to link.
    WaitingLink,
    /// QR code provisioning URL available for scanning.
    WaitingQrScan { provisioning_url: String },
    /// Device successfully linked, syncing.
    Linked,
    /// Fully operational.
    Ready,
    /// Error during authentication.
    Error { message: String },
    /// Closing / destroyed.
    Closed,
}

impl AuthState {
    /// String representation for JSON `@type` of `updateAuthState`.
    pub fn as_str(&self) -> &'static str {
        match self {
            AuthState::Uninitialized => "uninitialized",
            AuthState::WaitingLink => "waitingLink",
            AuthState::WaitingQrScan { .. } => "waitingQrScan",
            AuthState::Linked => "linked",
            AuthState::Ready => "ready",
            AuthState::Error { .. } => "error",
            AuthState::Closed => "closed",
        }
    }

    /// Convert to JSON value for emission.
    pub fn to_json(&self) -> serde_json::Value {
        let mut obj = serde_json::json!({
            "state": self.as_str(),
        });
        match self {
            AuthState::WaitingQrScan { provisioning_url } => {
                obj["provisioning_url"] = serde_json::Value::String(provisioning_url.clone());
            }
            AuthState::Error { message } => {
                obj["error_message"] = serde_json::Value::String(message.clone());
            }
            _ => {}
        }
        obj
    }
}
