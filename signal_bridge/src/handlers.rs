//! Request handlers — one function per `@type`.
//!
//! Each handler receives the shared state, the parsed JSON request, and the
//! optional `@extra` field for request/response correlation.

use crate::bridge::SharedState;
use std::sync::Arc;
use crate::types::AuthState;

use base64::Engine as _;
use futures::channel::oneshot;
use futures::StreamExt;
use presage::libsignal_service::content::ContentBody;
use presage::libsignal_service::prelude::Uuid;
use presage::libsignal_service::proto::DataMessage;
use presage::libsignal_service::protocol::{Aci, ServiceId};
use presage::libsignal_service::sender::AttachmentSpec;
use presage::manager::Registered;
use presage::model::identity::OnNewIdentity;
use presage::model::messages::Received;
use presage::store::{ContentsStore, Thread};
use presage::Manager;
use presage_store_sqlite::SqliteStore;

use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use url::Url;

/// Helper: emit a JSON response/event to the outbound channel.
fn emit(state: &SharedState, response: Value) {
    let _ = state.out_tx.send(response.to_string());
}

/// Helper: emit a response with @extra correlation.
fn emit_response(state: &SharedState, extra: Option<Value>, mut response: Value) {
    if let Some(e) = extra {
        response["@extra"] = e;
    }
    emit(state, response);
}

/// Helper: emit an error response.
fn emit_error(state: &SharedState, extra: Option<Value>, code: i32, message: &str) {
    emit_response(
        state,
        extra,
        json!({
            "@type": "error",
            "code": code,
            "message": message,
        }),
    );
}

/// Helper: emit auth state change event (flat structure for Dart).
fn emit_auth_state(state: &SharedState, auth: &AuthState) {
    let mut obj = auth.to_json();
    obj["@type"] = serde_json::Value::String("updateAuthState".to_string());
    emit(state, obj);
}

/// Helper: get current timestamp in milliseconds.
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Helper: base64 encode bytes.
fn b64_encode(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

/// Helper: base64 decode string.
fn b64_decode(s: &str) -> Result<Vec<u8>, base64::DecodeError> {
    base64::engine::general_purpose::STANDARD.decode(s)
}

/// Helper: read conversation/chat ID from request (Dart sends `conversation_id`,
/// but also accept `chat_id` for backward compat).
fn get_conversation_id<'a>(val: &'a Value) -> Option<&'a str> {
    val["conversation_id"]
        .as_str()
        .or_else(|| val["chat_id"].as_str())
}

/// Background receive loop: consumes incoming messages from Signal servers,
/// stores them in the SQLite store, and emits events to the Dart side.
async fn run_receive_loop(
    mut manager: Manager<SqliteStore, Registered>,
    out_tx: tokio::sync::mpsc::UnboundedSender<String>,
    self_uuid: Option<Uuid>,
) {
    tracing::info!("receive_loop: starting receive_messages...");

    let stream = match manager.receive_messages().await {
        Ok(s) => s,
        Err(e) => {
            tracing::error!("receive_loop: receive_messages FAILED: {}", e);
            let _ = out_tx.send(
                json!({
                    "@type": "updateSyncComplete",
                    "success": false,
                    "error": format!("{}", e),
                })
                .to_string(),
            );
            return;
        }
    };

    tracing::info!("receive_loop: stream opened, processing events...");
    futures::pin_mut!(stream);

    while let Some(received) = stream.next().await {
        match received {
            Received::Contacts => {
                tracing::info!("receive_loop: contacts synced");
                let _ = out_tx.send(
                    json!({
                        "@type": "updateContacts",
                    })
                    .to_string(),
                );
            }
            Received::Content(content) => {
                let msg_json = content_to_json(&content, self_uuid);
                let _ = out_tx.send(
                    json!({
                        "@type": "updateNewMessage",
                        "message": msg_json,
                    })
                    .to_string(),
                );
            }
            Received::QueueEmpty => {
                tracing::info!("receive_loop: queue empty (initial sync complete)");
                let _ = out_tx.send(
                    json!({
                        "@type": "updateSyncComplete",
                        "success": true,
                    })
                    .to_string(),
                );
            }
        }
    }

    tracing::info!("receive_loop: stream ended");
}

// ---------------------------------------------------------------------------
// setSignalParameters
// ---------------------------------------------------------------------------

/// Configure the bridge: set database path, device name, etc.
/// Must be called before `requestLinkDevice`.
pub async fn set_signal_parameters(
    state: &SharedState,
    val: &Value,
    extra: Option<Value>,
) {
    let db_path = val["database_directory"]
        .as_str()
        .unwrap_or("signal_db")
        .to_string();
    let device_name = val["device_name"]
        .as_str()
        .unwrap_or("Geogram")
        .to_string();

    *state.db_path.lock().unwrap() = Some(PathBuf::from(&db_path));
    *state.device_name.lock().unwrap() = device_name;

    // Transition to waitingLink
    let new_state = AuthState::WaitingLink;
    *state.auth_state.lock().unwrap() = new_state.clone();
    emit_auth_state(state, &new_state);

    emit_response(
        state,
        extra,
        json!({
            "@type": "ok",
        }),
    );
}

// ---------------------------------------------------------------------------
// requestLinkDevice
// ---------------------------------------------------------------------------

/// Start the secondary device linking flow, or reconnect an existing registration.
///
/// 1. Opens the SQLite store.
/// 2. Tries `Manager::load_registered()` — if device is already linked, emits
///    `ready` and starts the receive loop immediately.
/// 3. Otherwise, falls back to `link_secondary_device()` for QR-code provisioning.
pub async fn request_link_device(state: Arc<SharedState>, extra: Option<Value>) {
    let db_path = match state.db_path.lock().unwrap().clone() {
        Some(p) => p,
        None => {
            emit_error(
                &state,
                extra,
                400,
                "call setSignalParameters before requestLinkDevice",
            );
            return;
        }
    };
    let device_name = state.device_name.lock().unwrap().clone();

    // Clone out_tx for use inside the spawned task
    let out_tx = state.out_tx.clone();

    // Convert db_path to a sqlite: URL string for SqliteStore
    let db_url = format!(
        "sqlite:{}",
        db_path.join("signal.db").to_string_lossy()
    );

    tracing::info!("requestLinkDevice: db_url={}", db_url);

    // Open/create the SQLite store
    tracing::info!("requestLinkDevice: opening SQLite store...");
    let store = match SqliteStore::open_with_passphrase(&db_url, None, OnNewIdentity::Trust).await {
        Ok(s) => {
            tracing::info!("requestLinkDevice: store opened OK");
            s
        }
        Err(e) => {
            tracing::error!("requestLinkDevice: store open FAILED: {}", e);
            let mut obj = AuthState::Error {
                message: format!("failed to open store: {}", e),
            }
            .to_json();
            obj["@type"] = serde_json::Value::String("updateAuthState".to_string());
            emit(&state, obj);
            emit_response(&state, extra, json!({"@type": "error", "code": 500, "message": "store open failed"}));
            return;
        }
    };

    // --- Try loading an existing registration first ---
    tracing::info!("requestLinkDevice: trying load_registered...");
    match Manager::load_registered(store.clone()).await {
        Ok(manager) => {
            tracing::info!("requestLinkDevice: already registered, skipping QR flow");

            // Store our own UUID for is_outgoing detection
            let self_uuid_val = manager.registration_data().service_ids.aci;
            *state.self_uuid.lock().unwrap() = Some(self_uuid_val);

            // Store a clone for query/send handlers
            MANAGER_SLOT.with(|slot| {
                slot.borrow_mut().replace(manager.clone());
            });

            // Emit ready
            let ready = AuthState::Ready;
            *state.auth_state.lock().unwrap() = ready.clone();
            emit_auth_state(&state, &ready);
            emit_response(&state, extra, json!({"@type": "ok"}));

            // Start the receive loop in the background
            let recv_tx = out_tx.clone();
            tokio::task::spawn_local(async move {
                run_receive_loop(manager, recv_tx, Some(self_uuid_val)).await;
            });
            return;
        }
        Err(e) => {
            tracing::info!("requestLinkDevice: not registered ({}), proceeding with QR linking", e);
        }
    }

    // --- Fresh linking via QR code ---
    let (tx, rx) = oneshot::channel::<Url>();

    let state_for_spawn = Arc::clone(&state);
    tokio::task::spawn_local(async move {
        tracing::info!("requestLinkDevice: calling link_secondary_device...");
        let manager = match Manager::link_secondary_device(
            store,
            presage::libsignal_service::configuration::SignalServers::Production,
            device_name,
            tx,
        )
        .await
        {
            Ok(m) => {
                tracing::info!("requestLinkDevice: link_secondary_device OK");
                m
            }
            Err(e) => {
                tracing::error!("requestLinkDevice: link_secondary_device FAILED: {}", e);
                let mut obj = AuthState::Error {
                    message: format!("linking failed: {}", e),
                }
                .to_json();
                obj["@type"] = serde_json::Value::String("updateAuthState".to_string());
                let _ = out_tx.send(obj.to_string());
                return;
            }
        };

        // Store our own UUID for is_outgoing detection
        let self_uuid_val = manager.registration_data().service_ids.aci;
        *state_for_spawn.self_uuid.lock().unwrap() = Some(self_uuid_val);

        // Store a clone for query/send handlers
        MANAGER_SLOT.with(|slot| {
            slot.borrow_mut().replace(manager.clone());
        });

        // Emit ready state
        let mut obj = AuthState::Ready.to_json();
        obj["@type"] = serde_json::Value::String("updateAuthState".to_string());
        let _ = out_tx.send(obj.to_string());

        // Start the receive loop with the original manager
        run_receive_loop(manager, out_tx, Some(self_uuid_val)).await;
    });

    // Wait for the provisioning URL on this task
    match rx.await {
        Ok(url) => {
            let qr_state = AuthState::WaitingQrScan {
                provisioning_url: url.to_string(),
            };

            // Update shared auth state
            *state.auth_state.lock().unwrap() = qr_state.clone();
            emit_auth_state(&state, &qr_state);

            emit_response(
                &state,
                extra,
                json!({
                    "@type": "linkDeviceQrCode",
                    "provisioning_url": url.to_string(),
                }),
            );
        }
        Err(_) => {
            emit_error(
                &state,
                extra,
                500,
                "provisioning channel closed unexpectedly",
            );
        }
    }
}

// Thread-local slot for the registered manager.
// Used because the linking task (spawn_local) needs to store the manager
// after successful linking. All dispatch happens on a single LocalSet thread.
thread_local! {
    static MANAGER_SLOT: std::cell::RefCell<Option<Manager<SqliteStore, Registered>>> =
        std::cell::RefCell::new(None);
}

/// Helper: get the manager, first checking the shared state, then the thread-local slot.
fn get_manager(state: &SharedState) -> Option<Manager<SqliteStore, Registered>> {
    // Check if manager is in the shared state
    {
        let guard = state.manager.lock().unwrap();
        if guard.is_some() {
            return guard.clone();
        }
    }

    // Check the thread-local slot and move it to shared state
    MANAGER_SLOT.with(|slot| {
        if let Some(mgr) = slot.borrow_mut().take() {
            let cloned = mgr.clone();
            *state.manager.lock().unwrap() = Some(mgr);
            return Some(cloned);
        }
        None
    })
}

// ---------------------------------------------------------------------------
// getConversations
// ---------------------------------------------------------------------------

/// Retrieve the list of conversations (contacts + groups).
pub async fn get_conversations(state: &SharedState, extra: Option<Value>) {
    let manager = match get_manager(state) {
        Some(m) => m,
        None => {
            emit_error(state, extra, 401, "not linked");
            return;
        }
    };

    let store = manager.store();
    let mut conversations = Vec::new();

    // Get contacts
    match store.contacts().await {
        Ok(contacts) => {
            for result in contacts {
                if let Ok(contact) = result {
                    let uuid_str = contact.uuid.to_string();
                    conversations.push(json!({
                        "id": uuid_str,
                        "type": "direct",
                        "title": contact.name,
                        "phone_number": contact.phone_number.as_ref().map(|p| p.to_string()),
                    }));
                }
            }
        }
        Err(e) => {
            tracing::warn!("failed to list contacts: {}", e);
        }
    }

    // Get groups
    match store.groups().await {
        Ok(groups) => {
            for result in groups {
                if let Ok((key, group)) = result {
                    let key_b64 = b64_encode(&key);
                    conversations.push(json!({
                        "id": key_b64,
                        "type": "group",
                        "title": group.title,
                        "member_count": group.members.len(),
                    }));
                }
            }
        }
        Err(e) => {
            tracing::warn!("failed to list groups: {}", e);
        }
    }

    emit_response(
        state,
        extra,
        json!({
            "@type": "conversations",
            "conversations": conversations,
            "total_count": conversations.len(),
        }),
    );
}

// ---------------------------------------------------------------------------
// getMessages
// ---------------------------------------------------------------------------

/// Retrieve messages for a conversation.
pub async fn get_messages(state: &SharedState, val: &Value, extra: Option<Value>) {
    let manager = match get_manager(state) {
        Some(m) => m,
        None => {
            emit_error(state, extra, 401, "not linked");
            return;
        }
    };

    let chat_id = match get_conversation_id(val) {
        Some(id) => id,
        None => {
            emit_error(state, extra, 400, "conversation_id is required");
            return;
        }
    };
    let chat_type = val["chat_type"].as_str().unwrap_or("auto");

    let thread = match parse_thread(chat_id, chat_type) {
        Ok(t) => t,
        Err(msg) => {
            emit_error(state, extra, 400, &msg);
            return;
        }
    };

    let self_uuid = *state.self_uuid.lock().unwrap();
    let limit = val["limit"].as_u64().unwrap_or(50) as usize;
    let before_timestamp = val["before_timestamp"].as_u64();

    let store = manager.store();
    match store.messages(&thread, ..).await {
        Ok(messages) => {
            let mut msg_list = Vec::new();
            for result in messages {
                if let Ok(msg) = result {
                    let ts = msg.metadata.timestamp;
                    // Filter by before_timestamp if specified
                    if let Some(before_ts) = before_timestamp {
                        if ts >= before_ts {
                            continue;
                        }
                    }
                    msg_list.push(content_to_json(&msg, self_uuid));
                    if msg_list.len() >= limit {
                        break;
                    }
                }
            }

            emit_response(
                state,
                extra,
                json!({
                    "@type": "messages",
                    "conversation_id": chat_id,
                    "messages": msg_list,
                }),
            );
        }
        Err(e) => {
            emit_error(
                state,
                extra,
                500,
                &format!("failed to get messages: {}", e),
            );
        }
    }
}

/// Parse a chat_id + chat_type into a Thread.
/// When chat_type is "auto" or empty, auto-detect: try UUID first, then base64 group key.
fn parse_thread(chat_id: &str, chat_type: &str) -> Result<Thread, String> {
    match chat_type {
        "group" => {
            let bytes = b64_decode(chat_id).map_err(|_| "invalid base64 group key".to_string())?;
            if bytes.len() < 32 {
                return Err("group key too short".to_string());
            }
            let mut key = [0u8; 32];
            key.copy_from_slice(&bytes[..32]);
            Ok(Thread::Group(key))
        }
        "direct" => {
            let uuid =
                Uuid::parse_str(chat_id).map_err(|_| "invalid UUID".to_string())?;
            Ok(Thread::Contact(uuid))
        }
        _ => {
            // Auto-detect: try UUID first, then base64 group key
            if let Ok(uuid) = Uuid::parse_str(chat_id) {
                return Ok(Thread::Contact(uuid));
            }
            if let Ok(bytes) = b64_decode(chat_id) {
                if bytes.len() >= 32 {
                    let mut key = [0u8; 32];
                    key.copy_from_slice(&bytes[..32]);
                    return Ok(Thread::Group(key));
                }
            }
            Err(format!("cannot parse '{}' as UUID or group key", chat_id))
        }
    }
}

/// Convert a presage Content to our JSON message format.
fn content_to_json(content: &presage::libsignal_service::content::Content, self_uuid: Option<Uuid>) -> Value {
    let sender_uuid = content.metadata.sender.raw_uuid().to_string();
    let timestamp = content.metadata.timestamp;

    let is_outgoing = self_uuid
        .map(|su| content.metadata.sender.raw_uuid() == su)
        .unwrap_or(false);

    let mut msg = json!({
        "sender_uuid": sender_uuid,
        "timestamp": timestamp,
        "is_outgoing": is_outgoing,
    });

    // Extract text from the body if it's a DataMessage
    if let ContentBody::DataMessage(dm) = &content.body {
        if let Some(text) = &dm.body {
            msg["text"] = Value::String(text.clone());
        }
        msg["content_type"] = Value::String("text".to_string());

        // Attachments
        if !dm.attachments.is_empty() {
            msg["content_type"] = Value::String("attachment".to_string());
            msg["attachment_count"] = json!(dm.attachments.len());
        }

        // Quote (reply)
        if let Some(quote) = &dm.quote {
            msg["quote_timestamp"] = json!(quote.id);
            if let Some(text) = &quote.text {
                msg["quote_text"] = Value::String(text.clone());
            }
        }

        // Reactions
        if let Some(reaction) = &dm.reaction {
            msg["content_type"] = Value::String("reaction".to_string());
            msg["reaction_emoji"] =
                Value::String(reaction.emoji.clone().unwrap_or_default());
            msg["reaction_target_timestamp"] = json!(reaction.target_sent_timestamp);
        }

        // Group context
        if let Some(gv2) = &dm.group_v2 {
            if let Some(key) = &gv2.master_key {
                msg["group_key"] = Value::String(b64_encode(key));
            }
        }
    }

    msg
}

// ---------------------------------------------------------------------------
// sendMessage
// ---------------------------------------------------------------------------

/// Send a text message to a contact or group.
pub async fn send_message(state: &SharedState, val: &Value, extra: Option<Value>) {
    let mut manager = match get_manager(state) {
        Some(m) => m,
        None => {
            emit_error(state, extra, 401, "not linked");
            return;
        }
    };

    let chat_id = match get_conversation_id(val) {
        Some(id) => id,
        None => {
            emit_error(state, extra, 400, "conversation_id is required");
            return;
        }
    };
    let text = match val["text"].as_str() {
        Some(t) => t,
        None => {
            emit_error(state, extra, 400, "text is required");
            return;
        }
    };
    let chat_type = val["chat_type"].as_str().unwrap_or("auto");
    let timestamp = now_ms();

    let mut dm = DataMessage::default();
    dm.body = Some(text.to_string());
    dm.timestamp = Some(timestamp);

    // Handle quote/reply
    if let Some(quote_ts) = val["quote_timestamp"].as_u64() {
        let mut quote =
            presage::libsignal_service::proto::data_message::Quote::default();
        quote.id = Some(quote_ts);
        if let Some(qt) = val["quote_text"].as_str() {
            quote.text = Some(qt.to_string());
        }
        dm.quote = Some(quote);
    }

    // Capture quote fields before sending
    let quote_ts = val["quote_timestamp"].as_u64();
    let quote_text_str = val["quote_text"].as_str().map(|s| s.to_string());

    let result = send_dm_to(&mut manager, chat_id, chat_type, dm, timestamp).await;

    match result {
        Ok(()) => {
            let self_uuid_str = state
                .self_uuid
                .lock()
                .unwrap()
                .map(|u| u.to_string())
                .unwrap_or_default();

            let mut resp = json!({
                "@type": "message",
                "conversation_id": chat_id,
                "timestamp": timestamp,
                "text": text,
                "sender_uuid": self_uuid_str,
                "is_outgoing": true,
                "content_type": "text",
            });
            if let Some(qt) = quote_ts {
                resp["quote_timestamp"] = json!(qt);
            }
            if let Some(ref qt) = quote_text_str {
                resp["quote_text"] = json!(qt);
            }

            emit_response(state, extra, resp);
        }
        Err(msg) => {
            emit_error(state, extra, 500, &msg);
        }
    }

    // Store the manager back
    *state.manager.lock().unwrap() = Some(manager);
}

/// Helper: send a DataMessage to a contact or group.
async fn send_dm_to(
    manager: &mut Manager<SqliteStore, Registered>,
    chat_id: &str,
    chat_type: &str,
    dm: DataMessage,
    timestamp: u64,
) -> Result<(), String> {
    match chat_type {
        "group" => {
            let key_bytes =
                b64_decode(chat_id).map_err(|_| "invalid base64 group key".to_string())?;
            manager
                .send_message_to_group(&key_bytes, dm, timestamp)
                .await
                .map_err(|e| format!("failed to send to group: {}", e))
        }
        _ => {
            let uuid =
                Uuid::parse_str(chat_id).map_err(|_| "invalid UUID".to_string())?;
            let service_id = ServiceId::from(Aci::from(uuid));
            manager
                .send_message(service_id, dm, timestamp)
                .await
                .map_err(|e| format!("failed to send message: {}", e))
        }
    }
}

// ---------------------------------------------------------------------------
// sendAttachment
// ---------------------------------------------------------------------------

/// Send a file attachment.
pub async fn send_attachment(state: &SharedState, val: &Value, extra: Option<Value>) {
    let mut manager = match get_manager(state) {
        Some(m) => m,
        None => {
            emit_error(state, extra, 401, "not linked");
            return;
        }
    };

    let chat_id = match get_conversation_id(val) {
        Some(id) => id,
        None => {
            emit_error(state, extra, 400, "conversation_id is required");
            return;
        }
    };
    let file_path = match val["file_path"].as_str() {
        Some(p) => p,
        None => {
            emit_error(state, extra, 400, "file_path is required");
            return;
        }
    };
    let chat_type = val["chat_type"].as_str().unwrap_or("auto");
    let caption = val["caption"].as_str().map(|s| s.to_string());
    let content_type = val["content_type"]
        .as_str()
        .unwrap_or("application/octet-stream");
    let timestamp = now_ms();

    // Read the file
    let file_data = match tokio::fs::read(file_path).await {
        Ok(data) => data,
        Err(e) => {
            emit_error(
                state,
                extra,
                500,
                &format!("failed to read file: {}", e),
            );
            return;
        }
    };

    let file_name = std::path::Path::new(file_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("attachment")
        .to_string();

    // Create attachment spec
    let spec = AttachmentSpec {
        content_type: content_type.to_string(),
        length: file_data.len(),
        file_name: Some(file_name.clone()),
        preview: None,
        voice_note: Some(false),
        borderless: Some(false),
        width: val["width"].as_u64().map(|w| w as u32),
        height: val["height"].as_u64().map(|h| h as u32),
        caption: caption.clone(),
        blur_hash: None,
    };

    // Upload the attachment
    let pointer = match manager.upload_attachment(spec, file_data).await {
        Ok(Ok(p)) => p,
        Ok(Err(e)) => {
            emit_error(
                state,
                extra,
                500,
                &format!("attachment upload failed: {:?}", e),
            );
            return;
        }
        Err(e) => {
            emit_error(
                state,
                extra,
                500,
                &format!("attachment upload error: {}", e),
            );
            return;
        }
    };

    // Build data message with attachment
    let mut dm = DataMessage::default();
    dm.attachments = vec![pointer];
    dm.timestamp = Some(timestamp);
    if let Some(cap) = caption {
        dm.body = Some(cap);
    }

    let result = send_dm_to(&mut manager, chat_id, chat_type, dm, timestamp).await;

    match result {
        Ok(()) => {
            emit_response(
                state,
                extra,
                json!({
                    "@type": "attachmentSent",
                    "chat_id": chat_id,
                    "timestamp": timestamp,
                    "file_name": file_name,
                }),
            );
        }
        Err(msg) => {
            emit_error(state, extra, 500, &msg);
        }
    }

    *state.manager.lock().unwrap() = Some(manager);
}

// ---------------------------------------------------------------------------
// sendReaction
// ---------------------------------------------------------------------------

/// Send a reaction emoji to a message.
pub async fn send_reaction(state: &SharedState, val: &Value, extra: Option<Value>) {
    let mut manager = match get_manager(state) {
        Some(m) => m,
        None => {
            emit_error(state, extra, 401, "not linked");
            return;
        }
    };

    let chat_id = match get_conversation_id(val) {
        Some(id) => id,
        None => {
            emit_error(state, extra, 400, "conversation_id is required");
            return;
        }
    };
    let emoji = match val["emoji"].as_str() {
        Some(e) => e,
        None => {
            emit_error(state, extra, 400, "emoji is required");
            return;
        }
    };
    let target_timestamp = match val["target_timestamp"].as_u64() {
        Some(t) => t,
        None => {
            emit_error(state, extra, 400, "target_timestamp is required");
            return;
        }
    };
    let target_uuid = val["target_sender_uuid"].as_str().unwrap_or("");
    let chat_type = val["chat_type"].as_str().unwrap_or("auto");
    let remove = val["remove"].as_bool().unwrap_or(false);
    let timestamp = now_ms();

    // Build reaction data message
    let mut reaction =
        presage::libsignal_service::proto::data_message::Reaction::default();
    reaction.emoji = Some(emoji.to_string());
    reaction.remove = Some(remove);
    reaction.target_sent_timestamp = Some(target_timestamp);
    if !target_uuid.is_empty() {
        reaction.target_author_aci = Some(target_uuid.to_string());
    }

    let mut dm = DataMessage::default();
    dm.reaction = Some(reaction);
    dm.timestamp = Some(timestamp);

    let result = send_dm_to(&mut manager, chat_id, chat_type, dm, timestamp).await;

    match result {
        Ok(()) => {
            emit_response(
                state,
                extra,
                json!({
                    "@type": "reactionSent",
                    "chat_id": chat_id,
                    "emoji": emoji,
                    "target_timestamp": target_timestamp,
                }),
            );
        }
        Err(msg) => {
            emit_error(state, extra, 500, &msg);
        }
    }

    *state.manager.lock().unwrap() = Some(manager);
}

// ---------------------------------------------------------------------------
// getContact
// ---------------------------------------------------------------------------

/// Retrieve contact info by UUID.
pub async fn get_contact(state: &SharedState, val: &Value, extra: Option<Value>) {
    let manager = match get_manager(state) {
        Some(m) => m,
        None => {
            emit_error(state, extra, 401, "not linked");
            return;
        }
    };

    let uuid_str = match val["uuid"].as_str() {
        Some(id) => id,
        None => {
            emit_error(state, extra, 400, "uuid is required");
            return;
        }
    };

    let uuid = match Uuid::parse_str(uuid_str) {
        Ok(u) => u,
        Err(_) => {
            emit_error(state, extra, 400, "invalid UUID");
            return;
        }
    };

    let store = manager.store();
    match store.contact_by_id(&uuid).await {
        Ok(Some(contact)) => {
            // Try to save avatar to disk if available
            let mut avatar_path_str: Option<String> = None;
            if let Some(ref avatar) = contact.avatar {
                if let Some(ref db_path) = *state.db_path.lock().unwrap() {
                    let avatars_dir = db_path.join("avatars");
                    let _ = std::fs::create_dir_all(&avatars_dir);
                    let dest = avatars_dir.join(format!("{}.jpg", uuid_str));
                    if let Ok(()) = std::fs::write(&dest, &avatar.reader) {
                        avatar_path_str = Some(dest.to_string_lossy().to_string());
                    }
                }
            } else {
                // Check if a previously saved avatar exists on disk
                if let Some(ref db_path) = *state.db_path.lock().unwrap() {
                    let dest = db_path.join("avatars").join(format!("{}.jpg", uuid_str));
                    if dest.exists() {
                        avatar_path_str = Some(dest.to_string_lossy().to_string());
                    }
                }
            }

            emit_response(
                state,
                extra,
                json!({
                    "@type": "contact",
                    "uuid": uuid_str,
                    "name": contact.name,
                    "phone_number": contact.phone_number.as_ref().map(|p| p.to_string()),
                    "avatar_path": avatar_path_str,
                }),
            );
        }
        Ok(None) => {
            emit_response(
                state,
                extra,
                json!({
                    "@type": "contact",
                    "uuid": uuid_str,
                    "name": null,
                    "phone_number": null,
                }),
            );
        }
        Err(e) => {
            emit_error(
                state,
                extra,
                500,
                &format!("failed to get contact: {}", e),
            );
        }
    }
}

// ---------------------------------------------------------------------------
// unlinkDevice
// ---------------------------------------------------------------------------

/// Unlink this device (destroy the Signal session).
pub async fn unlink_device(state: &SharedState, extra: Option<Value>) {
    // Clear the manager
    {
        let mut guard = state.manager.lock().unwrap();
        *guard = None;
    }
    MANAGER_SLOT.with(|slot| {
        *slot.borrow_mut() = None;
    });

    // Update auth state
    let new_state = AuthState::Closed;
    *state.auth_state.lock().unwrap() = new_state.clone();
    emit_auth_state(state, &new_state);

    emit_response(
        state,
        extra,
        json!({
            "@type": "ok",
        }),
    );
}
