//! HAL import implementations for Wasmer.
//!
//! Each hal_* function from geogram_wasm_hal.h gets a Rust implementation
//! here, registered as WASM imports under the "hal" module namespace.

use crate::runtime::{HalState, ModuleKind, WasmBridge};

use wasmer::*;

/// Build the import object with all HAL functions and WASI stubs.
pub fn build_imports(store: &mut Store, env: &FunctionEnv<HalState>) -> Imports {
    imports! {
        // WASI stubs — wasi-sdk modules import these even with -nostartfiles
        "wasi_snapshot_preview1" => {
            "random_get" => Function::new_typed(store, wasi_random_get),
            "args_get" => Function::new_typed(store, wasi_stub_ii_i),
            "args_sizes_get" => Function::new_typed(store, wasi_stub_ii_i),
            "environ_get" => Function::new_typed(store, wasi_stub_ii_i),
            "environ_sizes_get" => Function::new_typed(store, wasi_stub_ii_i),
            "clock_time_get" => Function::new_typed(store, wasi_stub_iji_i),
            "proc_exit" => Function::new_typed(store, wasi_proc_exit),
            "fd_close" => Function::new_typed(store, wasi_stub_i_i),
            "fd_write" => Function::new_typed(store, wasi_stub_iiii_i),
            "fd_read" => Function::new_typed(store, wasi_stub_iiii_i),
            "fd_seek" => Function::new_typed(store, wasi_stub_iiji_i),
            "fd_fdstat_get" => Function::new_typed(store, wasi_stub_ii_i),
        },
        "hal" => {
            "time_ms" => Function::new_typed_with_env(store, env, hal_time_ms),
            "time_epoch" => Function::new_typed_with_env(store, env, hal_time_epoch),
            "log" => Function::new_typed_with_env(store, env, hal_log),
            "yield" => Function::new_typed_with_env(store, env, hal_yield),
            "platform" => Function::new_typed_with_env(store, env, hal_platform),
            "heap_free" => Function::new_typed_with_env(store, env, hal_heap_free),
            "kv_get" => Function::new_typed_with_env(store, env, hal_kv_get),
            "kv_set" => Function::new_typed_with_env(store, env, hal_kv_set),
            "kv_delete" => Function::new_typed_with_env(store, env, hal_kv_delete),
            "kv_list" => Function::new_typed_with_env(store, env, hal_kv_list),
            "kv_exists" => Function::new_typed_with_env(store, env, hal_kv_exists),
            "kv_size" => Function::new_typed_with_env(store, env, hal_kv_size),
            "file_open" => Function::new_typed_with_env(store, env, hal_file_open),
            "file_read" => Function::new_typed_with_env(store, env, hal_file_read),
            "file_write" => Function::new_typed_with_env(store, env, hal_file_write),
            "file_close" => Function::new_typed_with_env(store, env, hal_file_close),
            "http_request" => Function::new_typed_with_env(store, env, hal_http_request),
            "http_poll" => Function::new_typed_with_env(store, env, hal_http_poll),
            "http_read_response" => Function::new_typed_with_env(store, env, hal_http_read_response),
            "http_status" => Function::new_typed_with_env(store, env, hal_http_status),
            "http_free" => Function::new_typed_with_env(store, env, hal_http_free),
            "lora_available_hw" => Function::new_typed_with_env(store, env, hal_lora_available_hw),
            "lora_send" => Function::new_typed_with_env(store, env, hal_lora_send),
            "lora_available" => Function::new_typed_with_env(store, env, hal_lora_available),
            "lora_recv" => Function::new_typed_with_env(store, env, hal_lora_recv),
            "ble_scan_start" => Function::new_typed_with_env(store, env, hal_ble_scan_start),
            "ble_scan_stop" => Function::new_typed_with_env(store, env, hal_ble_scan_stop),
            "ble_scan_read" => Function::new_typed_with_env(store, env, hal_ble_scan_read),
            "ble_advertise" => Function::new_typed_with_env(store, env, hal_ble_advertise),
            "ble_advertise_stop" => Function::new_typed_with_env(store, env, hal_ble_advertise_stop),
            "sensor_temperature" => Function::new_typed_with_env(store, env, hal_sensor_temperature),
            "sensor_humidity" => Function::new_typed_with_env(store, env, hal_sensor_humidity),
            "sensor_battery" => Function::new_typed_with_env(store, env, hal_sensor_battery),
            "sensor_gps_lat" => Function::new_typed_with_env(store, env, hal_sensor_gps_lat),
            "sensor_gps_lon" => Function::new_typed_with_env(store, env, hal_sensor_gps_lon),
            "display_width" => Function::new_typed_with_env(store, env, hal_display_width),
            "display_height" => Function::new_typed_with_env(store, env, hal_display_height),
            "display_clear" => Function::new_typed_with_env(store, env, hal_display_clear),
            "display_text" => Function::new_typed_with_env(store, env, hal_display_text),
            "display_pixel" => Function::new_typed_with_env(store, env, hal_display_pixel),
            "display_rect" => Function::new_typed_with_env(store, env, hal_display_rect),
            "display_flush" => Function::new_typed_with_env(store, env, hal_display_flush),
            "gpio_mode" => Function::new_typed_with_env(store, env, hal_gpio_mode),
            "gpio_read" => Function::new_typed_with_env(store, env, hal_gpio_read),
            "gpio_write" => Function::new_typed_with_env(store, env, hal_gpio_write),
            "msg_send" => Function::new_typed_with_env(store, env, hal_msg_send),
            "msg_available" => Function::new_typed_with_env(store, env, hal_msg_available),
            "msg_recv" => Function::new_typed_with_env(store, env, hal_msg_recv),
            "lib_call" => Function::new_typed_with_env(store, env, hal_lib_call),
            "event_subscribe" => Function::new_typed_with_env(store, env, hal_event_subscribe),
            "event_unsubscribe" => Function::new_typed_with_env(store, env, hal_event_unsubscribe),
            "event_publish" => Function::new_typed_with_env(store, env, hal_event_publish),
            "event_available" => Function::new_typed_with_env(store, env, hal_event_available),
            "event_recv" => Function::new_typed_with_env(store, env, hal_event_recv),
        }
    }
}

// ── Memory helpers ──

fn read_string(env: &FunctionEnvMut<HalState>, ptr: u32, len: u32) -> String {
    let mem = match env.data().memory.as_ref() {
        Some(m) => m,
        None => return String::new(),
    };
    let view = mem.view(&env);
    let mut buf = vec![0u8; len as usize];
    if view.read(ptr as u64, &mut buf).is_ok() {
        String::from_utf8_lossy(&buf).to_string()
    } else {
        String::new()
    }
}

fn write_bytes(env: &FunctionEnvMut<HalState>, ptr: u32, data: &[u8], max_len: u32) -> u32 {
    let mem = match env.data().memory.as_ref() {
        Some(m) => m,
        None => return 0,
    };
    let view = mem.view(&env);
    let n = data.len().min(max_len as usize);
    if view.write(ptr as u64, &data[..n]).is_ok() {
        n as u32
    } else {
        0
    }
}

fn read_bytes(env: &FunctionEnvMut<HalState>, ptr: u32, len: u32) -> Vec<u8> {
    let mem = match env.data().memory.as_ref() {
        Some(m) => m,
        None => return vec![],
    };
    let view = mem.view(&env);
    let mut buf = vec![0u8; len as usize];
    if view.read(ptr as u64, &mut buf).is_ok() {
        buf
    } else {
        vec![]
    }
}

// ── System ──

fn hal_time_ms(env: FunctionEnvMut<HalState>) -> u64 {
    env.data().start_time.elapsed().as_millis() as u64
}

fn hal_time_epoch(_env: FunctionEnvMut<HalState>) -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn hal_log(env: FunctionEnvMut<HalState>, level: i32, msg_ptr: u32, msg_len: u32) {
    let msg = read_string(&env, msg_ptr, msg_len);
    let module_id = env.data().module_id.clone();
    let log_msg = format!("[wasm:{}] {}", module_id, msg);

    match level {
        0 => tracing::debug!("{}", log_msg),
        1 => tracing::info!("{}", log_msg),
        2 => tracing::warn!("{}", log_msg),
        3 => tracing::error!("{}", log_msg),
        _ => tracing::info!("{}", log_msg),
    }

    // Emit moduleLog event for Dart
    let event = serde_json::json!({
        "@type": "moduleLog",
        "moduleId": module_id,
        "level": level,
        "message": msg,
    });
    let _ = env.data().out_tx.send(event.to_string());
}

fn hal_yield(_env: FunctionEnvMut<HalState>) {
    std::thread::yield_now();
}

fn hal_platform(env: FunctionEnvMut<HalState>, buf_ptr: u32, buf_len: u32) -> u32 {
    let platform = b"linux-desktop";
    write_bytes(&env, buf_ptr, platform, buf_len)
}

fn hal_heap_free(_env: FunctionEnvMut<HalState>) -> u32 {
    64 * 1024 * 1024 // 64MB — desktop has plenty
}

// ── Storage (KV) — pluggable backend ──

fn hal_kv_get(env: FunctionEnvMut<HalState>, key_ptr: u32, key_len: u32, val_ptr: u32, val_len: u32) -> u32 {
    let key = read_string(&env, key_ptr, key_len);
    let module_id = env.data().module_id.clone();
    let backend = env.data().kv_backend.clone();
    if let Some(val) = backend.get(&module_id, &key) {
        write_bytes(&env, val_ptr, &val, val_len)
    } else {
        0
    }
}

fn hal_kv_set(env: FunctionEnvMut<HalState>, key_ptr: u32, key_len: u32, val_ptr: u32, val_len: u32) -> i32 {
    let key = read_string(&env, key_ptr, key_len);
    let val = read_bytes(&env, val_ptr, val_len);
    let module_id = env.data().module_id.clone();
    let backend = env.data().kv_backend.clone();
    backend.set(&module_id, &key, &val);
    0
}

fn hal_kv_delete(env: FunctionEnvMut<HalState>, key_ptr: u32, key_len: u32) -> i32 {
    let key = read_string(&env, key_ptr, key_len);
    let module_id = env.data().module_id.clone();
    let backend = env.data().kv_backend.clone();
    if backend.delete(&module_id, &key) { 0 } else { -1 }
}

fn hal_kv_list(env: FunctionEnvMut<HalState>, prefix_ptr: u32, prefix_len: u32, buf_ptr: u32, buf_len: u32) -> u32 {
    let prefix = read_string(&env, prefix_ptr, prefix_len);
    let module_id = env.data().module_id.clone();
    let backend = env.data().kv_backend.clone();
    let keys = backend.list_keys(&module_id, &prefix);
    if keys.is_empty() {
        return 0;
    }
    // Write null-separated key list, return count of keys
    let joined = keys.join("\0");
    write_bytes(&env, buf_ptr, joined.as_bytes(), buf_len);
    keys.len() as u32
}

fn hal_kv_exists(env: FunctionEnvMut<HalState>, key_ptr: u32, key_len: u32) -> i32 {
    let key = read_string(&env, key_ptr, key_len);
    let module_id = env.data().module_id.clone();
    let backend = env.data().kv_backend.clone();
    if backend.exists(&module_id, &key) { 1 } else { 0 }
}

fn hal_kv_size(env: FunctionEnvMut<HalState>, key_ptr: u32, key_len: u32) -> u32 {
    let key = read_string(&env, key_ptr, key_len);
    let module_id = env.data().module_id.clone();
    let backend = env.data().kv_backend.clone();
    backend.size(&module_id, &key).unwrap_or(0) as u32
}

// ── Storage (File) — stubs ──

fn hal_file_open(_env: FunctionEnvMut<HalState>, _path_ptr: u32, _path_len: u32, _mode: i32) -> i32 { -1 }
fn hal_file_read(_env: FunctionEnvMut<HalState>, _handle: i32, _buf_ptr: u32, _buf_len: u32) -> i32 { -1 }
fn hal_file_write(_env: FunctionEnvMut<HalState>, _handle: i32, _buf_ptr: u32, _buf_len: u32) -> i32 { -1 }
fn hal_file_close(_env: FunctionEnvMut<HalState>, _handle: i32) {}

// ── Network — stubs ──

fn hal_http_request(_env: FunctionEnvMut<HalState>, _method: i32, _url_ptr: u32, _url_len: u32, _body_ptr: u32, _body_len: u32) -> i32 { -1 }
fn hal_http_poll(_env: FunctionEnvMut<HalState>, _req_id: i32) -> i32 { -1 }
fn hal_http_read_response(_env: FunctionEnvMut<HalState>, _req_id: i32, _buf_ptr: u32, _buf_len: u32) -> i32 { 0 }
fn hal_http_status(_env: FunctionEnvMut<HalState>, _req_id: i32) -> i32 { -1 }
fn hal_http_free(_env: FunctionEnvMut<HalState>, _req_id: i32) {}

// ── LoRa — no hardware on desktop ──

fn hal_lora_available_hw(_env: FunctionEnvMut<HalState>) -> i32 { 0 }
fn hal_lora_send(_env: FunctionEnvMut<HalState>, _data_ptr: u32, _data_len: u32) -> i32 { -1 }
fn hal_lora_available(_env: FunctionEnvMut<HalState>) -> u32 { 0 }
fn hal_lora_recv(_env: FunctionEnvMut<HalState>, _buf_ptr: u32, _buf_len: u32) -> u32 { 0 }

// ── BLE — no hardware on desktop ──

fn hal_ble_scan_start(_env: FunctionEnvMut<HalState>) -> i32 { -1 }
fn hal_ble_scan_stop(_env: FunctionEnvMut<HalState>) {}
fn hal_ble_scan_read(_env: FunctionEnvMut<HalState>, _buf_ptr: u32, _buf_len: u32) -> u32 { 0 }
fn hal_ble_advertise(_env: FunctionEnvMut<HalState>, _data_ptr: u32, _data_len: u32) -> i32 { -1 }
fn hal_ble_advertise_stop(_env: FunctionEnvMut<HalState>) {}

// ── Sensors — unavailable on desktop ──

fn hal_sensor_temperature(_env: FunctionEnvMut<HalState>) -> i32 { i32::MIN }
fn hal_sensor_humidity(_env: FunctionEnvMut<HalState>) -> i32 { i32::MIN }
fn hal_sensor_battery(_env: FunctionEnvMut<HalState>) -> i32 { i32::MIN }
fn hal_sensor_gps_lat(_env: FunctionEnvMut<HalState>) -> i32 { i32::MIN }
fn hal_sensor_gps_lon(_env: FunctionEnvMut<HalState>) -> i32 { i32::MIN }

// ── Display — no display on desktop/CLI ──

fn hal_display_width(_env: FunctionEnvMut<HalState>) -> u32 { 0 }
fn hal_display_height(_env: FunctionEnvMut<HalState>) -> u32 { 0 }
fn hal_display_clear(_env: FunctionEnvMut<HalState>) {}
fn hal_display_text(_env: FunctionEnvMut<HalState>, _x: i32, _y: i32, _color: i32, _text_ptr: u32, _text_len: u32) {}
fn hal_display_pixel(_env: FunctionEnvMut<HalState>, _x: i32, _y: i32, _color: i32) {}
fn hal_display_rect(_env: FunctionEnvMut<HalState>, _x: i32, _y: i32, _w: i32, _h: i32, _color: i32) {}
fn hal_display_flush(_env: FunctionEnvMut<HalState>) {}

// ── GPIO — no-op on desktop ──

fn hal_gpio_mode(_env: FunctionEnvMut<HalState>, _pin: i32, _mode: i32) {}
fn hal_gpio_read(_env: FunctionEnvMut<HalState>, _pin: i32) -> i32 { 0 }
fn hal_gpio_write(_env: FunctionEnvMut<HalState>, _pin: i32, _value: i32) {}

// ── Messages (host <-> module) ──

fn hal_msg_send(env: FunctionEnvMut<HalState>, json_ptr: u32, json_len: u32) {
    let msg = read_string(&env, json_ptr, json_len);
    let module_id = env.data().module_id.clone();
    let event = serde_json::json!({
        "@type": "moduleMessage",
        "moduleId": module_id,
        "data": msg,
    });
    let _ = env.data().out_tx.send(event.to_string());
}

fn hal_msg_available(env: FunctionEnvMut<HalState>) -> u32 {
    env.data()
        .msg_queue
        .first()
        .map(|m| m.len() as u32)
        .unwrap_or(0)
}

fn hal_msg_recv(mut env: FunctionEnvMut<HalState>, buf_ptr: u32, buf_len: u32) -> u32 {
    // Pop first message from queue
    let msg = if env.data().msg_queue.is_empty() {
        None
    } else {
        Some(env.data_mut().msg_queue.remove(0))
    };

    if let Some(data) = msg {
        write_bytes(&env, buf_ptr, &data, buf_len)
    } else {
        0
    }
}

// ── Events (topic-based pub/sub) ──

fn hal_event_subscribe(mut env: FunctionEnvMut<HalState>, topic_ptr: u32, topic_len: u32) -> i32 {
    let topic = read_string(&env, topic_ptr, topic_len);
    let module_id = env.data().module_id.clone();
    let router = env.data().event_router.clone();

    if let Ok(mut router) = router.lock() {
        router.subscribe(&topic, &module_id);
    }
    env.data_mut().event_subscriptions.insert(topic);
    0
}

fn hal_event_unsubscribe(mut env: FunctionEnvMut<HalState>, topic_ptr: u32, topic_len: u32) -> i32 {
    let topic = read_string(&env, topic_ptr, topic_len);
    let module_id = env.data().module_id.clone();
    let router = env.data().event_router.clone();

    let removed = if let Ok(mut router) = router.lock() {
        router.unsubscribe(&topic, &module_id)
    } else {
        false
    };
    env.data_mut().event_subscriptions.remove(&topic);
    if removed { 0 } else { -1 }
}

fn hal_event_publish(
    env: FunctionEnvMut<HalState>,
    topic_ptr: u32,
    topic_len: u32,
    data_ptr: u32,
    data_len: u32,
) -> i32 {
    let topic = read_string(&env, topic_ptr, topic_len);
    let data = read_bytes(&env, data_ptr, data_len);
    let module_id = env.data().module_id.clone();
    let router = env.data().event_router.clone();
    let modules_ref = env.data().modules_ref.clone();
    let out_tx = env.data().out_tx.clone();

    // Get subscribers (excluding publisher)
    let subscribers = if let Ok(router) = router.lock() {
        router.subscribers(&topic, Some(&module_id))
    } else {
        return 0;
    };

    // Push event into each subscriber's queue
    let mut count = 0i32;
    if let Ok(mut modules) = modules_ref.lock() {
        for sub_id in &subscribers {
            if let Some(m) = modules.get_mut(sub_id) {
                m.env
                    .as_mut(&mut m.store)
                    .event_queue
                    .push((topic.clone(), data.clone()));
                count += 1;
            }
        }
    }

    // Emit moduleEvent to Dart
    let event = serde_json::json!({
        "@type": "moduleEvent",
        "moduleId": module_id,
        "topic": topic,
        "data": String::from_utf8_lossy(&data).to_string(),
    });
    let _ = out_tx.send(event.to_string());

    count
}

fn hal_event_available(env: FunctionEnvMut<HalState>) -> u32 {
    env.data()
        .event_queue
        .first()
        .map(|(topic, data)| (topic.len() + data.len()) as u32)
        .unwrap_or(0)
}

fn hal_event_recv(
    mut env: FunctionEnvMut<HalState>,
    topic_buf_ptr: u32,
    topic_buf_len: u32,
    data_buf_ptr: u32,
    data_buf_len: u32,
) -> u32 {
    let event = if env.data().event_queue.is_empty() {
        None
    } else {
        Some(env.data_mut().event_queue.remove(0))
    };

    if let Some((topic, data)) = event {
        write_bytes(&env, topic_buf_ptr, topic.as_bytes(), topic_buf_len);
        write_bytes(&env, data_buf_ptr, &data, data_buf_len)
    } else {
        0
    }
}

// ── WASI stubs (for wasi-sdk compiled modules) ──

fn wasi_random_get(_buf: i32, _buf_len: i32) -> i32 { 0 }
fn wasi_proc_exit(_code: i32) {}
fn wasi_stub_i_i(_a: i32) -> i32 { 8 } // EBADF
fn wasi_stub_ii_i(_a: i32, _b: i32) -> i32 { 0 }
fn wasi_stub_iji_i(_a: i32, _b: i64, _c: i32) -> i32 { 0 }
fn wasi_stub_iiii_i(_a: i32, _b: i32, _c: i32, _d: i32) -> i32 { 0 }
fn wasi_stub_iiji_i(_a: i32, _b: i32, _c: i64, _d: i32) -> i32 { 0 }

// ── Library calls (cross-module RPC) ──

/// hal_lib_call: Call a function in a loaded library module.
///
/// Reads lib_id, fn_name, and args from the caller's WASM memory.
/// Finds the library in the shared modules map, invokes module_invoke
/// on it, and writes the result back to the caller's memory.
///
/// Returns bytes written on success, or negative error code:
///   -1 = library not found, -2 = function not found (mapped from module_invoke),
///   -3 = buffer too small, -4 = internal error.
fn hal_lib_call(
    env: FunctionEnvMut<HalState>,
    lib_id_ptr: u32,
    lib_id_len: u32,
    fn_name_ptr: u32,
    fn_name_len: u32,
    args_ptr: u32,
    args_len: u32,
    result_ptr: u32,
    result_len: u32,
) -> i32 {
    // Read arguments from caller's WASM memory
    let lib_id = read_string(&env, lib_id_ptr, lib_id_len);
    let fn_name = read_string(&env, fn_name_ptr, fn_name_len);
    let args = read_string(&env, args_ptr, args_len);

    let modules_ref = env.data().modules_ref.clone();

    // Take-execute-put-back: remove library from shared modules map
    let mut library = match modules_ref.lock() {
        Ok(mut modules) => match modules.remove(&lib_id) {
            Some(m) => m,
            None => return -1, // library not found
        },
        Err(_) => return -4,
    };

    if library.kind != ModuleKind::Library {
        // Put it back — it's not a library
        if let Ok(mut modules) = modules_ref.lock() {
            modules.insert(lib_id, library);
        }
        return -1;
    }

    // Invoke the function on the library
    let result = WasmBridge::invoke_on_module(&mut library, &fn_name, &args);

    // Put library back
    if let Ok(mut modules) = modules_ref.lock() {
        modules.insert(lib_id, library);
    }

    match result {
        Ok(result_str) => {
            let result_bytes = result_str.as_bytes();
            if result_bytes.len() > result_len as usize {
                return -3; // buffer too small
            }
            write_bytes(&env, result_ptr, result_bytes, result_len) as i32
        }
        Err(code) => code,
    }
}
