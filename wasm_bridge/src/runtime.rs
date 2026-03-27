//! Wasmer-based WASM module runtime.
//!
//! Manages module lifecycle: load → init → tick → destroy.
//! Each module gets its own Wasmer instance with HAL imports.
//! Supports two module kinds: App (tick loop) and Library (callable functions).

use crate::hal_impl;
use crate::kv::{FileKvBackend, KvBackend};

use libc::c_char;
use std::cell::UnsafeCell;
use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use wasmer::*;

/// Module kind: app (tick loop) or library (callable functions).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModuleKind {
    App = 0,
    Library = 1,
}

// ── Manifest ──

/// Module manifest read from manifest.json alongside the .wasm file.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Manifest {
    pub id: String,
    pub version: String,
    pub kind: String,
    #[serde(default)]
    pub description: String,
    /// Longer text about the wapp (markdown ok).
    #[serde(default)]
    pub summary: Option<String>,
    /// Relative path to an icon file (SVG preferred).
    #[serde(default)]
    pub icon: Option<String>,
    /// Relative paths to screenshot images.
    #[serde(default)]
    pub screenshots: Vec<String>,
    /// Category tags (e.g. "system", "music", "games").
    #[serde(default)]
    pub tags: Vec<String>,
    pub tick_interval_ms: Option<u32>,
    #[serde(default)]
    pub provides: ManifestProvides,
    #[serde(default)]
    pub requires: ManifestRequires,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ManifestProvides {
    #[serde(default)]
    pub functions: Vec<serde_json::Value>,
    #[serde(default)]
    pub events: Vec<String>,
    #[serde(default)]
    pub variables: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ManifestRequires {
    #[serde(default)]
    pub hal: Vec<String>,
    #[serde(default)]
    pub events: Vec<String>,
    #[serde(default)]
    pub libraries: Vec<String>,
    #[serde(default)]
    pub variables: Vec<String>,
}

// ── Event Router ──

/// Topic-based pub/sub router for inter-module and host communication.
pub struct EventRouter {
    /// topic → set of subscribed module IDs
    subscriptions: HashMap<String, HashSet<String>>,
}

impl EventRouter {
    pub fn new() -> Self {
        Self {
            subscriptions: HashMap::new(),
        }
    }

    pub fn subscribe(&mut self, topic: &str, module_id: &str) {
        self.subscriptions
            .entry(topic.to_string())
            .or_default()
            .insert(module_id.to_string());
    }

    pub fn unsubscribe(&mut self, topic: &str, module_id: &str) -> bool {
        if let Some(subs) = self.subscriptions.get_mut(topic) {
            let removed = subs.remove(module_id);
            if subs.is_empty() {
                self.subscriptions.remove(topic);
            }
            removed
        } else {
            false
        }
    }

    /// Get all subscribers for a topic, optionally excluding one module.
    pub fn subscribers(&self, topic: &str, exclude_id: Option<&str>) -> Vec<String> {
        self.subscriptions
            .get(topic)
            .map(|subs| {
                subs.iter()
                    .filter(|id| exclude_id.map_or(true, |ex| *id != ex))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Remove all subscriptions for a module (called on unload).
    pub fn remove_module(&mut self, module_id: &str) {
        self.subscriptions.retain(|_, subs| {
            subs.remove(module_id);
            !subs.is_empty()
        });
    }
}

/// A loaded WASM module instance.
pub struct ModuleInstance {
    pub id: String,
    pub path: String,
    pub store: Store,
    pub instance: Instance,
    pub env: FunctionEnv<HalState>,
    pub tick_interval_ms: u32,
    pub running: bool,
    pub kind: ModuleKind,
    pub api_schema: Option<String>,
    pub manifest: Option<Manifest>,
}

/// Scratch memory offset for host-initiated WASM calls (schema, invoke).
/// Must be within the module's linear memory. Default WASM memory is 1 page
/// (64KB). We use 32KB which is above typical data sections but within page 1.
/// For larger operations, the runtime grows memory first.
const SCRATCH_OFFSET: u32 = 32 * 1024; // 32KB offset

/// State shared with HAL import functions via FunctionEnv.
pub struct HalState {
    /// Module ID for scoped storage and log prefixing
    pub module_id: String,
    /// Base directory for module storage
    pub storage_dir: String,
    /// Monotonic start time
    pub start_time: std::time::Instant,
    /// Outbound channel for events to Dart
    pub out_tx: std::sync::mpsc::Sender<String>,
    /// WASM linear memory — set after instantiation
    pub memory: Option<Memory>,
    /// Inbound message queue (host -> module)
    pub msg_queue: Vec<Vec<u8>>,
    /// KV storage backend (shared, thread-safe)
    pub kv_backend: Arc<dyn KvBackend>,
    /// Shared reference to the modules map for hal_lib_call
    pub modules_ref: Arc<Mutex<HashMap<String, ModuleInstance>>>,
    /// This module's event subscriptions (local tracking)
    pub event_subscriptions: HashSet<String>,
    /// Inbound event queue (topic, data)
    pub event_queue: Vec<(String, Vec<u8>)>,
    /// Shared event router
    pub event_router: Arc<Mutex<EventRouter>>,
}

/// The bridge object held behind the opaque FFI pointer.
pub struct WasmBridge {
    modules: Arc<Mutex<HashMap<String, ModuleInstance>>>,
    event_router: Arc<Mutex<EventRouter>>,
    kv_backend: Arc<dyn KvBackend>,
    in_tx: std::sync::mpsc::Sender<String>,
    in_rx: Mutex<std::sync::mpsc::Receiver<String>>,
    out_rx: Mutex<std::sync::mpsc::Receiver<String>>,
    out_tx: std::sync::mpsc::Sender<String>,
    last_response: UnsafeCell<Option<CString>>,
}

// SAFETY: WasmBridge is only accessed from one thread at a time via the C API.
// The UnsafeCell<Option<CString>> is only used in receive() which is single-threaded.
unsafe impl Send for WasmBridge {}
unsafe impl Sync for WasmBridge {}

impl WasmBridge {
    pub fn new() -> Self {
        let (in_tx, in_rx) = std::sync::mpsc::channel::<String>();
        let (out_tx, out_rx) = std::sync::mpsc::channel::<String>();

        WasmBridge {
            modules: Arc::new(Mutex::new(HashMap::new())),
            event_router: Arc::new(Mutex::new(EventRouter::new())),
            kv_backend: Arc::new(FileKvBackend::new(
                format!("{}/geogram_cli", std::env::temp_dir().display()),
            )),
            in_tx,
            in_rx: Mutex::new(in_rx),
            out_rx: Mutex::new(out_rx),
            out_tx,
            last_response: UnsafeCell::new(None),
        }
    }

    pub fn send(&self, json: &str) {
        let _ = self.in_tx.send(json.to_string());
        self.process_pending();
    }

    pub fn receive(&self, timeout: f64) -> Option<String> {
        let rx = self.out_rx.lock().ok()?;
        let dur = Duration::from_secs_f64(timeout.max(0.001));
        rx.recv_timeout(dur).ok()
    }

    pub fn set_last_response(&self, json: String) -> *const c_char {
        let cstring = match CString::new(json) {
            Ok(s) => s,
            Err(_) => return std::ptr::null(),
        };
        let ptr = cstring.as_ptr();
        unsafe {
            *self.last_response.get() = Some(cstring);
        }
        ptr
    }

    pub fn shutdown(self) {
        if let Ok(mut modules) = self.modules.lock() {
            let ids: Vec<String> = modules.keys().cloned().collect();
            for id in ids {
                if let Some(mut m) = modules.remove(&id) {
                    Self::call_destroy(&mut m);
                }
            }
        }
        tracing::info!("WasmBridge: shutdown complete");
    }

    fn process_pending(&self) {
        let rx = match self.in_rx.lock() {
            Ok(rx) => rx,
            Err(_) => return,
        };
        while let Ok(json_str) = rx.try_recv() {
            self.dispatch(&json_str);
        }
    }

    fn dispatch(&self, json_str: &str) {
        let val: serde_json::Value = match serde_json::from_str(json_str) {
            Ok(v) => v,
            Err(e) => {
                self.emit_error(&format!("invalid JSON: {}", e), None);
                return;
            }
        };

        let req_type = val["@type"].as_str().unwrap_or("");
        let extra = val["@extra"].clone();

        match req_type {
            "loadModule" => self.handle_load_module(&val, &extra),
            "unloadModule" => self.handle_unload_module(&val, &extra),
            "listModules" => self.handle_list_modules(&extra),
            "moduleStatus" => self.handle_module_status(&val, &extra),
            "sendMessage" => self.handle_send_message(&val, &extra),
            "tickModule" => self.handle_tick_module(&val, &extra),
            "invokeFunction" => self.handle_invoke_function(&val, &extra),
            "getSchema" => self.handle_get_schema(&val, &extra),
            "publishEvent" => self.handle_publish_event(&val, &extra),
            _ => {
                self.emit_json(serde_json::json!({
                    "@type": "error",
                    "@extra": extra,
                    "code": 400,
                    "message": format!("unknown request type: {}", req_type),
                }));
            }
        }
    }

    /// Read manifest.json from the same directory as the .wasm file.
    fn read_manifest(wasm_path: &str) -> Option<Manifest> {
        let wasm = std::path::Path::new(wasm_path);
        let manifest_path = wasm.parent()?.join("manifest.json");
        let data = std::fs::read_to_string(&manifest_path).ok()?;
        serde_json::from_str(&data).ok()
    }

    /// Validate that all required libraries are loaded. Returns list of unmet deps.
    fn validate_dependencies(
        requires: &ManifestRequires,
        modules: &HashMap<String, ModuleInstance>,
    ) -> Vec<String> {
        let mut unmet = Vec::new();
        for lib_id in &requires.libraries {
            let found = modules.values().any(|m| {
                m.manifest
                    .as_ref()
                    .map(|mf| mf.id == *lib_id)
                    .unwrap_or(false)
                    || m.id == *lib_id
            });
            if !found {
                unmet.push(lib_id.clone());
            }
        }
        unmet
    }

    fn handle_load_module(&self, val: &serde_json::Value, extra: &serde_json::Value) {
        let path = match val["path"].as_str() {
            Some(p) => p.to_string(),
            None => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 400, "message": "loadModule requires 'path'",
                }));
                return;
            }
        };

        let id = val["id"]
            .as_str()
            .map(|s| s.to_string())
            .unwrap_or_else(|| {
                std::path::Path::new(&path)
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("unknown")
                    .to_string()
            });

        let storage_dir = val["storageDir"]
            .as_str()
            .unwrap_or("/tmp/geogram_wasm")
            .to_string();

        // Read manifest (optional — backward compat)
        let manifest = Self::read_manifest(&path);

        // Validate dependencies if manifest declares them
        if let Some(ref mf) = manifest {
            if let Ok(modules) = self.modules.lock() {
                let unmet = Self::validate_dependencies(&mf.requires, &modules);
                if !unmet.is_empty() {
                    self.emit_json(serde_json::json!({
                        "@type": "error", "@extra": extra,
                        "code": 424, "message": format!("unmet dependencies: {}", unmet.join(", ")),
                        "unmet": unmet,
                    }));
                    return;
                }
            }
        }

        let wasm_bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 500, "message": format!("failed to read {}: {}", path, e),
                }));
                return;
            }
        };

        let mut store = Store::default();
        let module = match Module::new(&store, &wasm_bytes) {
            Ok(m) => m,
            Err(e) => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 500, "message": format!("failed to compile WASM: {}", e),
                }));
                return;
            }
        };

        let hal_state = HalState {
            module_id: id.clone(),
            storage_dir,
            start_time: std::time::Instant::now(),
            out_tx: self.out_tx.clone(),
            memory: None, // Set after instantiation
            msg_queue: Vec::new(),
            kv_backend: Arc::clone(&self.kv_backend),
            modules_ref: Arc::clone(&self.modules),
            event_subscriptions: HashSet::new(),
            event_queue: Vec::new(),
            event_router: Arc::clone(&self.event_router),
        };

        let env = FunctionEnv::new(&mut store, hal_state);
        let imports = hal_impl::build_imports(&mut store, &env);

        let instance = match Instance::new(&mut store, &module, &imports) {
            Ok(i) => i,
            Err(e) => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 500, "message": format!("failed to instantiate WASM: {}", e),
                }));
                return;
            }
        };

        // Store memory reference in HalState so HAL imports can access it
        if let Ok(memory) = instance.exports.get_memory("memory") {
            env.as_mut(&mut store).memory = Some(memory.clone());
        }

        // Call module_init
        if let Ok(init_fn) = instance.exports.get_function("module_init") {
            if let Err(e) = init_fn.call(&mut store, &[]) {
                tracing::warn!("module_init failed for {}: {}", id, e);
            }
        }

        // Detect module kind: manifest.kind takes precedence, else probe module_type() export
        let kind = manifest
            .as_ref()
            .map(|mf| {
                if mf.kind == "library" {
                    ModuleKind::Library
                } else {
                    ModuleKind::App
                }
            })
            .unwrap_or_else(|| {
                instance
                    .exports
                    .get_function("module_type")
                    .ok()
                    .and_then(|f| f.call(&mut store, &[]).ok())
                    .and_then(|r| r.first().map(|v| v.unwrap_i32() as u32))
                    .map(|v| if v == 1 { ModuleKind::Library } else { ModuleKind::App })
                    .unwrap_or(ModuleKind::App)
            });

        // For libraries, read the API schema
        let api_schema = if kind == ModuleKind::Library {
            Self::read_api_schema(&instance, &mut store, &env)
        } else {
            None
        };

        // Tick interval: manifest takes precedence, else probe export, else 1000ms
        let tick_interval_ms = manifest
            .as_ref()
            .and_then(|mf| mf.tick_interval_ms)
            .unwrap_or_else(|| {
                instance
                    .exports
                    .get_function("module_tick_interval_ms")
                    .ok()
                    .and_then(|f| f.call(&mut store, &[]).ok())
                    .and_then(|r| r.first().map(|v| v.unwrap_i32() as u32))
                    .unwrap_or(1000)
            });

        let kind_str = match kind {
            ModuleKind::App => "app",
            ModuleKind::Library => "library",
        };

        let manifest_json = manifest
            .as_ref()
            .and_then(|mf| serde_json::to_value(mf).ok());

        let mi = ModuleInstance {
            id: id.clone(),
            path: path.clone(),
            store,
            instance,
            env,
            tick_interval_ms,
            running: true,
            kind,
            api_schema,
            manifest,
        };

        if let Ok(mut modules) = self.modules.lock() {
            if let Some(mut old) = modules.remove(&id) {
                Self::call_destroy(&mut old);
            }
            modules.insert(id.clone(), mi);
        }

        let mut response = serde_json::json!({
            "@type": "moduleLoaded",
            "@extra": extra,
            "id": id,
            "path": path,
            "kind": kind_str,
            "tick_interval_ms": tick_interval_ms,
        });
        if let Some(mj) = manifest_json {
            response["manifest"] = mj;
        }
        self.emit_json(response);

        tracing::info!("Loaded {} '{}' from {}", kind_str, id, path);
    }

    /// Read API schema from a library module by calling module_api_schema().
    fn read_api_schema(
        instance: &Instance,
        store: &mut Store,
        env: &FunctionEnv<HalState>,
    ) -> Option<String> {
        let schema_fn = instance
            .exports
            .get_function("module_api_schema")
            .ok()?;

        let memory = env.as_ref(store).memory.as_ref()?.clone();

        // Ensure memory is large enough for scratch area
        let buf_ptr = SCRATCH_OFFSET;
        let buf_len: u32 = 8192;
        let needed_pages = ((buf_ptr + buf_len) as u64 + 65535) / 65536;
        let current_pages = memory.view(store).size().0 as u64;
        if current_pages < needed_pages {
            let _ = memory.grow(store, (needed_pages - current_pages) as u32);
        }

        let result = schema_fn
            .call(
                store,
                &[Value::I32(buf_ptr as i32), Value::I32(buf_len as i32)],
            )
            .ok()?;

        let bytes_written = result.first()?.unwrap_i32() as u32;
        if bytes_written == 0 || bytes_written > buf_len {
            return None;
        }

        let view = memory.view(store);
        let mut buf = vec![0u8; bytes_written as usize];
        view.read(buf_ptr as u64, &mut buf).ok()?;

        String::from_utf8(buf).ok()
    }

    fn handle_unload_module(&self, val: &serde_json::Value, extra: &serde_json::Value) {
        let id = match val["id"].as_str() {
            Some(s) => s.to_string(),
            None => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 400, "message": "unloadModule requires 'id'",
                }));
                return;
            }
        };

        let removed = if let Ok(mut modules) = self.modules.lock() {
            modules.remove(&id).map(|mut m| {
                Self::call_destroy(&mut m);
            })
        } else {
            None
        };

        if removed.is_some() {
            // Clean up event subscriptions
            if let Ok(mut router) = self.event_router.lock() {
                router.remove_module(&id);
            }
            self.emit_json(serde_json::json!({
                "@type": "moduleStopped", "@extra": extra, "id": id,
            }));
            tracing::info!("Unloaded module '{}'", id);
        } else {
            self.emit_json(serde_json::json!({
                "@type": "error", "@extra": extra,
                "code": 404, "message": format!("module '{}' not found", id),
            }));
        }
    }

    fn handle_list_modules(&self, extra: &serde_json::Value) {
        let list = if let Ok(modules) = self.modules.lock() {
            modules
                .values()
                .map(|m| {
                    let kind_str = match m.kind {
                        ModuleKind::App => "app",
                        ModuleKind::Library => "library",
                    };
                    let mut entry = serde_json::json!({
                        "id": m.id, "path": m.path,
                        "running": m.running, "tick_interval_ms": m.tick_interval_ms,
                        "kind": kind_str,
                    });
                    if let Some(ref mf) = m.manifest {
                        if let Ok(mj) = serde_json::to_value(mf) {
                            entry["manifest"] = mj;
                        }
                    }
                    entry
                })
                .collect::<Vec<_>>()
        } else {
            vec![]
        };

        self.emit_json(serde_json::json!({
            "@type": "moduleList", "@extra": extra, "modules": list,
        }));
    }

    fn handle_module_status(&self, val: &serde_json::Value, extra: &serde_json::Value) {
        let id = match val["id"].as_str() {
            Some(s) => s,
            None => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 400, "message": "moduleStatus requires 'id'",
                }));
                return;
            }
        };

        if let Ok(modules) = self.modules.lock() {
            if let Some(m) = modules.get(id) {
                let kind_str = match m.kind {
                    ModuleKind::App => "app",
                    ModuleKind::Library => "library",
                };
                let mut response = serde_json::json!({
                    "@type": "moduleStatusResult", "@extra": extra,
                    "id": m.id, "path": m.path,
                    "running": m.running, "tick_interval_ms": m.tick_interval_ms,
                    "kind": kind_str,
                });
                if let Some(ref mf) = m.manifest {
                    if let Ok(mj) = serde_json::to_value(mf) {
                        response["manifest"] = mj;
                    }
                }
                self.emit_json(response);
            } else {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 404, "message": format!("module '{}' not found", id),
                }));
            }
        }
    }

    fn handle_send_message(&self, val: &serde_json::Value, extra: &serde_json::Value) {
        let id = match val["moduleId"].as_str() {
            Some(s) => s.to_string(),
            None => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 400, "message": "sendMessage requires 'moduleId'",
                }));
                return;
            }
        };

        let data = val["data"].to_string();

        // Take-execute-put-back: remove module from map before WASM call
        let mut module = if let Ok(mut modules) = self.modules.lock() {
            match modules.remove(&id) {
                Some(m) => m,
                None => {
                    self.emit_json(serde_json::json!({
                        "@type": "error", "@extra": extra,
                        "code": 404, "message": format!("module '{}' not found", id),
                    }));
                    return;
                }
            }
        } else {
            return;
        };

        // Push message into HalState's queue
        module
            .env
            .as_mut(&mut module.store)
            .msg_queue
            .push(data.into_bytes());

        // Call module_handle_event so it can read via hal_msg_recv
        if let Ok(handle_fn) = module
            .instance
            .exports
            .get_function("module_handle_event")
        {
            if let Err(e) = handle_fn.call(&mut module.store, &[]) {
                tracing::warn!("module_handle_event failed for {}: {}", id, e);
            }
        }

        // Put module back
        if let Ok(mut modules) = self.modules.lock() {
            modules.insert(id.clone(), module);
        }

        self.emit_json(serde_json::json!({ "@type": "ok", "@extra": extra }));
    }

    fn handle_tick_module(&self, val: &serde_json::Value, extra: &serde_json::Value) {
        let id = match val["id"].as_str() {
            Some(s) => s.to_string(),
            None => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 400, "message": "tickModule requires 'id'",
                }));
                return;
            }
        };

        // Take-execute-put-back: remove module from map before WASM call
        let mut module = if let Ok(mut modules) = self.modules.lock() {
            match modules.remove(&id) {
                Some(m) => m,
                None => {
                    self.emit_json(serde_json::json!({
                        "@type": "error", "@extra": extra,
                        "code": 404, "message": format!("module '{}' not found", id),
                    }));
                    return;
                }
            }
        } else {
            return;
        };

        // Skip tick for library modules
        if module.kind != ModuleKind::Library {
            if let Ok(tick_fn) = module.instance.exports.get_function("module_tick") {
                if let Err(e) = tick_fn.call(&mut module.store, &[]) {
                    tracing::warn!("module_tick failed for {}: {}", id, e);
                }
            }
        }

        // Put module back
        if let Ok(mut modules) = self.modules.lock() {
            modules.insert(id.clone(), module);
        }

        self.emit_json(serde_json::json!({ "@type": "ok", "@extra": extra }));
    }

    /// Invoke a function on a library module.
    fn handle_invoke_function(&self, val: &serde_json::Value, extra: &serde_json::Value) {
        let library_id = match val["libraryId"].as_str() {
            Some(s) => s.to_string(),
            None => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 400, "message": "invokeFunction requires 'libraryId'",
                }));
                return;
            }
        };

        let fn_name = match val["function"].as_str() {
            Some(s) => s.to_string(),
            None => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 400, "message": "invokeFunction requires 'function'",
                }));
                return;
            }
        };

        let args = val["args"].to_string();

        // Take-execute-put-back
        let mut module = if let Ok(mut modules) = self.modules.lock() {
            match modules.remove(&library_id) {
                Some(m) => m,
                None => {
                    self.emit_json(serde_json::json!({
                        "@type": "error", "@extra": extra,
                        "code": 404, "message": format!("library '{}' not found", library_id),
                    }));
                    return;
                }
            }
        } else {
            return;
        };

        if module.kind != ModuleKind::Library {
            // Put back before returning error
            if let Ok(mut modules) = self.modules.lock() {
                modules.insert(library_id.clone(), module);
            }
            self.emit_json(serde_json::json!({
                "@type": "error", "@extra": extra,
                "code": 400, "message": format!("'{}' is not a library module", library_id),
            }));
            return;
        }

        let result = Self::invoke_on_module(&mut module, &fn_name, &args);

        // Put module back
        if let Ok(mut modules) = self.modules.lock() {
            modules.insert(library_id.clone(), module);
        }

        match result {
            Ok(result_str) => {
                // Try to parse as JSON; if it is, embed as object; otherwise as string
                let result_val: serde_json::Value =
                    serde_json::from_str(&result_str).unwrap_or(serde_json::Value::String(result_str));
                self.emit_json(serde_json::json!({
                    "@type": "invokeResult", "@extra": extra,
                    "libraryId": library_id,
                    "function": fn_name,
                    "result": result_val,
                }));
            }
            Err(code) => {
                let msg = match code {
                    -1 => "unknown function",
                    -2 => "bad arguments",
                    -3 => "result buffer too small",
                    -4 => "internal error in module",
                    _ => "invoke failed",
                };
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 500, "message": format!("{} (code {})", msg, code),
                }));
            }
        }
    }

    /// Call module_invoke on a module instance. Returns Ok(result_string) or Err(error_code).
    pub fn invoke_on_module(
        m: &mut ModuleInstance,
        fn_name: &str,
        args: &str,
    ) -> Result<String, i32> {
        let invoke_fn = m
            .instance
            .exports
            .get_function("module_invoke")
            .map_err(|_| -4)?;

        let memory = m
            .env
            .as_ref(&m.store)
            .memory
            .as_ref()
            .ok_or(-4)?
            .clone();

        let fn_name_bytes = fn_name.as_bytes();
        let args_bytes = args.as_bytes();

        // Layout in scratch memory:
        // [fn_name | args | result_buf]
        let fn_name_ptr = SCRATCH_OFFSET;
        let fn_name_len = fn_name_bytes.len() as u32;
        let args_ptr = fn_name_ptr + fn_name_len;
        let args_len = args_bytes.len() as u32;
        let result_ptr = args_ptr + args_len;
        let result_len: u32 = 8192;

        // Ensure memory is large enough
        let total_needed = result_ptr + result_len;
        let needed_pages = (total_needed as u64 + 65535) / 65536;
        let current_pages = memory.view(&m.store).size().0 as u64;
        if current_pages < needed_pages {
            let _ = memory.grow(&mut m.store, (needed_pages - current_pages) as u32);
        }

        // Write fn_name and args into WASM memory
        let view = memory.view(&m.store);
        view.write(fn_name_ptr as u64, fn_name_bytes).map_err(|_| -4)?;
        view.write(args_ptr as u64, args_bytes).map_err(|_| -4)?;

        // Call module_invoke
        let wasm_result = invoke_fn
            .call(
                &mut m.store,
                &[
                    Value::I32(fn_name_ptr as i32),
                    Value::I32(fn_name_len as i32),
                    Value::I32(args_ptr as i32),
                    Value::I32(args_len as i32),
                    Value::I32(result_ptr as i32),
                    Value::I32(result_len as i32),
                ],
            )
            .map_err(|_| -4)?;

        let bytes_written = wasm_result
            .first()
            .map(|v| v.unwrap_i32())
            .unwrap_or(-4);

        if bytes_written < 0 {
            return Err(bytes_written);
        }

        // Read result from WASM memory
        let view = memory.view(&m.store);
        let mut result_buf = vec![0u8; bytes_written as usize];
        view.read(result_ptr as u64, &mut result_buf).map_err(|_| -4)?;

        String::from_utf8(result_buf).map_err(|_| -4)
    }

    /// Get cached schema for a library module.
    fn handle_get_schema(&self, val: &serde_json::Value, extra: &serde_json::Value) {
        let library_id = match val["libraryId"].as_str() {
            Some(s) => s,
            None => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 400, "message": "getSchema requires 'libraryId'",
                }));
                return;
            }
        };

        if let Ok(modules) = self.modules.lock() {
            if let Some(m) = modules.get(library_id) {
                if m.kind != ModuleKind::Library {
                    self.emit_json(serde_json::json!({
                        "@type": "error", "@extra": extra,
                        "code": 400, "message": format!("'{}' is not a library module", library_id),
                    }));
                    return;
                }
                let schema_val: serde_json::Value = m
                    .api_schema
                    .as_ref()
                    .and_then(|s| serde_json::from_str(s).ok())
                    .unwrap_or(serde_json::Value::Null);
                self.emit_json(serde_json::json!({
                    "@type": "schemaResult", "@extra": extra,
                    "libraryId": library_id,
                    "schema": schema_val,
                }));
            } else {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 404, "message": format!("library '{}' not found", library_id),
                }));
            }
        }
    }

    /// Host publishes an event to all subscribed modules.
    fn handle_publish_event(&self, val: &serde_json::Value, extra: &serde_json::Value) {
        let topic = match val["topic"].as_str() {
            Some(t) => t.to_string(),
            None => {
                self.emit_json(serde_json::json!({
                    "@type": "error", "@extra": extra,
                    "code": 400, "message": "publishEvent requires 'topic'",
                }));
                return;
            }
        };

        let data = val["data"].as_str().unwrap_or("").as_bytes().to_vec();

        // Get subscribers from router
        let subscribers = if let Ok(router) = self.event_router.lock() {
            router.subscribers(&topic, None)
        } else {
            vec![]
        };

        // Push event into each subscriber's queue
        let count = if let Ok(mut modules) = self.modules.lock() {
            let mut delivered = 0;
            for sub_id in &subscribers {
                if let Some(m) = modules.get_mut(sub_id) {
                    m.env
                        .as_mut(&mut m.store)
                        .event_queue
                        .push((topic.clone(), data.clone()));
                    delivered += 1;
                }
            }
            delivered
        } else {
            0
        };

        self.emit_json(serde_json::json!({
            "@type": "ok", "@extra": extra,
            "topic": topic, "subscribers_notified": count,
        }));
    }

    fn call_destroy(m: &mut ModuleInstance) {
        if let Ok(destroy_fn) = m.instance.exports.get_function("module_destroy") {
            if let Err(e) = destroy_fn.call(&mut m.store, &[]) {
                tracing::warn!("module_destroy failed for {}: {}", m.id, e);
            }
        }
        m.running = false;
    }

    fn emit_json(&self, val: serde_json::Value) {
        let _ = self.out_tx.send(val.to_string());
    }

    fn emit_error(&self, message: &str, extra: Option<&serde_json::Value>) {
        let mut val = serde_json::json!({
            "@type": "error", "code": 500, "message": message,
        });
        if let Some(e) = extra {
            val["@extra"] = e.clone();
        }
        self.emit_json(val);
    }
}
