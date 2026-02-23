//! Core bridge: tokio runtime + presage manager + MPSC channels.
//!
//! Incoming JSON requests are parsed and dispatched to presage operations on
//! a dedicated thread with a LocalSet (because presage uses thread-local RNG
//! internally). Results and unsolicited events are queued in an outbound
//! channel for `receive()` to return.

use crate::handlers;
use crate::types::AuthState;

use presage::libsignal_service::prelude::Uuid;
use presage::Manager;
use presage_store_sqlite::SqliteStore;

use std::cell::UnsafeCell;
use std::ffi::CString;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

/// Presage manager type alias once linked/registered.
pub type RegisteredManager = Manager<SqliteStore, presage::manager::Registered>;

/// State shared between the FFI thread and the tokio runtime.
pub struct SharedState {
    /// Presage manager (available after successful link/registration).
    pub manager: Mutex<Option<RegisteredManager>>,

    /// Current authentication state.
    pub auth_state: Mutex<AuthState>,

    /// Database directory path (set via setSignalParameters).
    pub db_path: Mutex<Option<PathBuf>>,

    /// Device name (set via setSignalParameters).
    pub device_name: Mutex<String>,

    /// Outbound channel sender — push events/responses here.
    pub out_tx: mpsc::UnboundedSender<String>,

    /// Our own UUID (ACI), set after successful link/registration.
    pub self_uuid: Mutex<Option<Uuid>>,
}

/// The bridge object held behind the opaque FFI pointer.
pub struct SignalBridge {
    /// Main tokio runtime (used for receive() blocking).
    runtime: Runtime,

    /// Inbound channel — FFI send() pushes JSON here, runtime consumes.
    in_tx: mpsc::UnboundedSender<String>,

    /// Outbound channel receiver — receive() pulls JSON from here.
    out_rx: Mutex<mpsc::UnboundedReceiver<String>>,

    /// Last response CString — kept alive so the returned *const c_char stays valid.
    last_response: UnsafeCell<Option<CString>>,

    /// Handle to the dispatch thread (for join on shutdown).
    _dispatch_thread: Option<std::thread::JoinHandle<()>>,
}

// SAFETY: SignalBridge is only accessed from one thread at a time via the C API.
// The UnsafeCell<Option<CString>> is only used in receive() which is single-threaded
// from the Dart isolate's perspective.
unsafe impl Send for SignalBridge {}
unsafe impl Sync for SignalBridge {}

impl SignalBridge {
    /// Create a new bridge with a fresh tokio runtime.
    pub fn new() -> Self {
        let runtime = Runtime::new().expect("failed to create tokio runtime");

        let (in_tx, in_rx) = mpsc::unbounded_channel::<String>();
        let (out_tx, out_rx) = mpsc::unbounded_channel::<String>();

        let state = Arc::new(SharedState {
            manager: Mutex::new(None),
            auth_state: Mutex::new(AuthState::Uninitialized),
            db_path: Mutex::new(None),
            device_name: Mutex::new("Geogram".to_string()),
            out_tx,
            self_uuid: Mutex::new(None),
        });

        // Spawn the dispatch loop on a dedicated thread with a LocalSet.
        // This is necessary because presage uses thread-local RNG (Rc-based)
        // which is not Send, so we can't use tokio::spawn directly.
        let state_clone = Arc::clone(&state);
        let dispatch_thread = std::thread::Builder::new()
            .name("signal-bridge-dispatch".into())
            .spawn(move || {
                let local_rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("failed to create dispatch runtime");
                let local = tokio::task::LocalSet::new();
                local.block_on(&local_rt, Self::dispatch_loop(state_clone, in_rx));
            })
            .expect("failed to spawn dispatch thread");

        SignalBridge {
            runtime,
            in_tx,
            out_rx: Mutex::new(out_rx),
            last_response: UnsafeCell::new(None),
            _dispatch_thread: Some(dispatch_thread),
        }
    }

    /// Push a JSON request into the inbound channel.
    pub fn send(&self, json: &str) {
        if let Err(e) = self.in_tx.send(json.to_string()) {
            tracing::error!("send failed (channel closed): {}", e);
        }
    }

    /// Pull the next JSON event/response, blocking up to `timeout` seconds.
    pub fn receive(&self, timeout: f64) -> Option<String> {
        let dur = Duration::from_secs_f64(timeout.max(0.0).min(60.0));
        let mut rx = self.out_rx.lock().unwrap();

        // Use the runtime to block on the async recv with timeout
        self.runtime.block_on(async {
            match tokio::time::timeout(dur, rx.recv()).await {
                Ok(Some(json)) => Some(json),
                _ => None,
            }
        })
    }

    /// Store the last response CString and return a pointer to it.
    /// The pointer is valid until the next call to this method or destroy.
    pub fn set_last_response(&self, json: String) -> *const libc::c_char {
        let cstring = CString::new(json).unwrap_or_default();
        let ptr = cstring.as_ptr();
        // SAFETY: single-threaded access from the Dart receive isolate
        unsafe {
            *self.last_response.get() = Some(cstring);
        }
        ptr
    }

    /// Shut down the runtime and all tasks.
    pub fn shutdown(self) {
        drop(self.in_tx); // close inbound channel → dispatch loop exits
        self.runtime.shutdown_timeout(Duration::from_secs(5));
    }

    /// Main dispatch loop: reads JSON requests from inbound channel,
    /// parses `@type`, and routes to the appropriate handler.
    /// Runs on a LocalSet to support !Send futures from presage.
    async fn dispatch_loop(
        state: Arc<SharedState>,
        mut in_rx: mpsc::UnboundedReceiver<String>,
    ) {
        while let Some(json) = in_rx.recv().await {
            Self::handle_request(&state, &json).await;
        }
        tracing::info!("dispatch loop exited");
    }

    /// Parse a JSON request and route by `@type`.
    async fn handle_request(state: &Arc<SharedState>, json: &str) {
        let val: serde_json::Value = match serde_json::from_str(json) {
            Ok(v) => v,
            Err(e) => {
                Self::emit_error(state, None, 400, &format!("invalid JSON: {}", e));
                return;
            }
        };

        let req_type = val["@type"].as_str().unwrap_or("");
        let extra = val.get("@extra").cloned();

        tracing::info!("request: @type={}", req_type);

        match req_type {
            "setSignalParameters" => {
                handlers::set_signal_parameters(state, &val, extra).await;
            }
            "requestLinkDevice" => {
                handlers::request_link_device(state.clone(), extra).await;
            }
            "getConversations" => {
                handlers::get_conversations(state, extra).await;
            }
            "getMessages" => {
                handlers::get_messages(state, &val, extra).await;
            }
            "sendMessage" => {
                handlers::send_message(state, &val, extra).await;
            }
            "sendAttachment" => {
                handlers::send_attachment(state, &val, extra).await;
            }
            "sendReaction" => {
                handlers::send_reaction(state, &val, extra).await;
            }
            "getContact" => {
                handlers::get_contact(state, &val, extra).await;
            }
            "unlinkDevice" => {
                handlers::unlink_device(state, extra).await;
            }
            _ => {
                Self::emit_error(
                    state,
                    extra,
                    404,
                    &format!("unknown request type: {}", req_type),
                );
            }
        }
    }

    /// Push an error response to the outbound channel.
    fn emit_error(
        state: &SharedState,
        extra: Option<serde_json::Value>,
        code: i32,
        message: &str,
    ) {
        let mut resp = serde_json::json!({
            "@type": "error",
            "code": code,
            "message": message,
        });
        if let Some(e) = extra {
            resp["@extra"] = e;
        }
        let _ = state.out_tx.send(resp.to_string());
    }
}
