//! C-ABI JSON bridge for Geogram WASM module runtime.
//!
//! Exposes 5 functions that mirror the signal_bridge JSON client interface so
//! the Dart FFI layer can treat this identically.
//!
//! JSON request `@type` values:
//!   loadModule, unloadModule, listModules, moduleStatus, sendMessage
//!
//! JSON event `@type` values:
//!   moduleLoaded, moduleStopped, moduleLog, moduleMessage, moduleError

mod hal_impl;
pub mod kv;
mod probestack;
mod runtime;

use runtime::WasmBridge;

use libc::c_char;
use std::ffi::{CStr, CString};
use std::ptr;

/// Create a new WASM bridge client. Returns an opaque pointer.
///
/// # Safety
/// The returned pointer must be passed to `wasm_json_client_destroy` when done.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wasm_json_client_create() -> *mut libc::c_void {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("wasm_bridge=info".parse().unwrap()),
        )
        .try_init();

    let bridge = WasmBridge::new();
    let boxed = Box::new(bridge);
    Box::into_raw(boxed) as *mut libc::c_void
}

/// Send a JSON request to the client. Non-blocking.
///
/// # Safety
/// `client` must be a valid pointer from `wasm_json_client_create`.
/// `request` must be a valid null-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wasm_json_client_send(
    client: *mut libc::c_void,
    request: *const c_char,
) {
    if client.is_null() || request.is_null() {
        return;
    }

    let bridge = unsafe { &*(client as *const WasmBridge) };
    let c_str = unsafe { CStr::from_ptr(request) };

    let json_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => {
            tracing::error!("wasm_json_client_send: invalid UTF-8");
            return;
        }
    };

    bridge.send(json_str);
}

/// Receive the next JSON event/response. Blocks up to `timeout` seconds.
/// Returns null if no event is available within the timeout.
///
/// # Safety
/// `client` must be a valid pointer from `wasm_json_client_create`.
/// The returned string is valid until the next call to `receive` or `destroy`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wasm_json_client_receive(
    client: *mut libc::c_void,
    timeout: f64,
) -> *const c_char {
    if client.is_null() {
        return ptr::null();
    }

    let bridge = unsafe { &*(client as *const WasmBridge) };
    match bridge.receive(timeout) {
        Some(json) => bridge.set_last_response(json),
        None => ptr::null(),
    }
}

/// Execute a synchronous request. Returns immediately.
///
/// # Safety
/// `client` may be null for static queries.
/// `request` must be a valid null-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wasm_json_client_execute(
    _client: *mut libc::c_void,
    request: *const c_char,
) -> *const c_char {
    if request.is_null() {
        return ptr::null();
    }

    let c_str = unsafe { CStr::from_ptr(request) };
    let json_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return ptr::null(),
    };

    let response = match serde_json::from_str::<serde_json::Value>(json_str) {
        Ok(val) => {
            let req_type = val["@type"].as_str().unwrap_or("");
            match req_type {
                "getVersion" => serde_json::json!({
                    "@type": "version",
                    "version": env!("CARGO_PKG_VERSION"),
                }),
                _ => serde_json::json!({
                    "@type": "error",
                    "code": 400,
                    "message": format!("unknown synchronous request: {}", req_type),
                }),
            }
        }
        Err(e) => serde_json::json!({
            "@type": "error",
            "code": 400,
            "message": format!("invalid JSON: {}", e),
        }),
    };

    let s = CString::new(response.to_string()).unwrap_or_default();
    s.into_raw() as *const c_char
}

/// Destroy the client and free all resources.
///
/// # Safety
/// `client` must be a valid pointer from `wasm_json_client_create`, or null.
/// Must not be called more than once for the same pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wasm_json_client_destroy(client: *mut libc::c_void) {
    if client.is_null() {
        return;
    }

    let bridge = unsafe { Box::from_raw(client as *mut WasmBridge) };
    bridge.shutdown();
}
