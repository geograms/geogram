//! KV storage backends for WASM modules.
//!
//! Pluggable backends replacing the in-memory HashMap from Phase 1.
//! Each module's keys are scoped by module_id.

use std::collections::HashMap;
use std::sync::Mutex;

/// Trait for KV storage backends. Implementations must be thread-safe.
pub trait KvBackend: Send + Sync {
    fn get(&self, module_id: &str, key: &str) -> Option<Vec<u8>>;
    fn set(&self, module_id: &str, key: &str, value: &[u8]);
    fn delete(&self, module_id: &str, key: &str) -> bool;
    fn list_keys(&self, module_id: &str, prefix: &str) -> Vec<String>;
    fn exists(&self, module_id: &str, key: &str) -> bool;
    fn size(&self, module_id: &str, key: &str) -> Option<usize>;
}

/// In-memory KV backend (current behavior, good for testing).
pub struct InMemoryKvBackend {
    data: Mutex<HashMap<String, HashMap<String, Vec<u8>>>>,
}

impl InMemoryKvBackend {
    pub fn new() -> Self {
        Self {
            data: Mutex::new(HashMap::new()),
        }
    }
}

impl KvBackend for InMemoryKvBackend {
    fn get(&self, module_id: &str, key: &str) -> Option<Vec<u8>> {
        let data = self.data.lock().ok()?;
        data.get(module_id)?.get(key).cloned()
    }

    fn set(&self, module_id: &str, key: &str, value: &[u8]) {
        if let Ok(mut data) = self.data.lock() {
            data.entry(module_id.to_string())
                .or_default()
                .insert(key.to_string(), value.to_vec());
        }
    }

    fn delete(&self, module_id: &str, key: &str) -> bool {
        if let Ok(mut data) = self.data.lock() {
            data.get_mut(module_id)
                .map(|m| m.remove(key).is_some())
                .unwrap_or(false)
        } else {
            false
        }
    }

    fn list_keys(&self, module_id: &str, prefix: &str) -> Vec<String> {
        if let Ok(data) = self.data.lock() {
            data.get(module_id)
                .map(|m| {
                    m.keys()
                        .filter(|k| k.starts_with(prefix))
                        .cloned()
                        .collect()
                })
                .unwrap_or_default()
        } else {
            vec![]
        }
    }

    fn exists(&self, module_id: &str, key: &str) -> bool {
        if let Ok(data) = self.data.lock() {
            data.get(module_id)
                .map(|m| m.contains_key(key))
                .unwrap_or(false)
        } else {
            false
        }
    }

    fn size(&self, module_id: &str, key: &str) -> Option<usize> {
        let data = self.data.lock().ok()?;
        data.get(module_id)?.get(key).map(|v| v.len())
    }
}

/// File-based KV backend — persists to {base_dir}/{module_id}/kv/{key} files.
pub struct FileKvBackend {
    base_dir: String,
}

impl FileKvBackend {
    pub fn new(base_dir: String) -> Self {
        Self { base_dir }
    }

    fn key_path(&self, module_id: &str, key: &str) -> std::path::PathBuf {
        let sanitized_key = key
            .replace('/', "_")
            .replace('\\', "_")
            .replace('\0', "_");
        std::path::Path::new(&self.base_dir)
            .join(module_id)
            .join("kv")
            .join(sanitized_key)
    }

    fn kv_dir(&self, module_id: &str) -> std::path::PathBuf {
        std::path::Path::new(&self.base_dir)
            .join(module_id)
            .join("kv")
    }
}

impl KvBackend for FileKvBackend {
    fn get(&self, module_id: &str, key: &str) -> Option<Vec<u8>> {
        std::fs::read(self.key_path(module_id, key)).ok()
    }

    fn set(&self, module_id: &str, key: &str, value: &[u8]) {
        let path = self.key_path(module_id, key);
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(path, value);
    }

    fn delete(&self, module_id: &str, key: &str) -> bool {
        std::fs::remove_file(self.key_path(module_id, key)).is_ok()
    }

    fn list_keys(&self, module_id: &str, prefix: &str) -> Vec<String> {
        let dir = self.kv_dir(module_id);
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => return vec![],
        };
        entries
            .filter_map(|entry| {
                let entry = entry.ok()?;
                let name = entry.file_name().into_string().ok()?;
                if name.starts_with(prefix) {
                    Some(name)
                } else {
                    None
                }
            })
            .collect()
    }

    fn exists(&self, module_id: &str, key: &str) -> bool {
        self.key_path(module_id, key).exists()
    }

    fn size(&self, module_id: &str, key: &str) -> Option<usize> {
        std::fs::metadata(self.key_path(module_id, key))
            .ok()
            .map(|m| m.len() as usize)
    }
}
