# Geogram Wapp Specification
## Package Format, HAL, and UI Language Reference
**Version 0.8**

---

## 1. Overview

A **wapp** is a self-contained application package that runs identically on ESP32 (Wasm3), Android/Desktop Flutter (Wasmer), CLI (Wasmer), and web browsers. Business logic lives in a single compiled WebAssembly binary. User interfaces are declared in `.ui.json` files using the GeoUI JSON schema — a renderer-agnostic description of screens, fields, actions, and reactive behaviours that each host platform translates into its own native widgets. Because GeoUI uses plain JSON, any language's built-in JSON decoder can read the files (Dart `jsonDecode`, C `cJSON`, Python `json.load`, JS `JSON.parse`).

```
┌─────────────────────────────────────────────────────┐
│                  myapp.wapp (zip)                    │
│                                                      │
│  app.wasm          ← business logic (required)       │
│  manifest.json     ← metadata, deps, permissions     │
│  screens/          ← UI definitions (.ui.json)       │
│    home.ui.json                                      │
│    settings.ui.json                                  │
│    chat.ui.json                                      │
│  media/            ← all assets (default root)       │
│    icons/                                            │
│      send.svg                                        │
│      lock.svg                                        │
│    images/                                           │
│      banner.png                                      │
│      logo.png                                        │
│    audio/                                            │
│      notification.wav                                │
└─────────────────────────────────────────────────────┘
```

The WASM binary is the single source of truth for logic. The `.ui.json` files are data — they can be updated, propagated over the mesh, and rendered by any conforming host without recompiling `app.wasm`.

---

## 2. Package Format — `.wapp`

A `.wapp` file is a standard ZIP archive with the following layout:

```
app.wasm              ← required, must be at archive root
manifest.json         ← required, must be at archive root
screens/              ← required if the app has a UI
  *.ui.json
media/                ← optional, all assets live here
  icons/              ← SVG preferred, PNG acceptable
  images/
  audio/
  fonts/
```

### Rules

- `app.wasm` **must** be at the archive root. No subdirectory.
- `manifest.json` **must** be at the archive root.
- `.ui.json` files **must** live inside `screens/`.
- Media assets **must** live inside `media/`. Subdirectory structure is free-form; the renderer searches recursively.
- Paths in `.ui.json` files reference assets relative to `media/` using function-call syntax: `{"$fn":"media","args":["send.svg"]}` or `{"$fn":"media","args":["icons/send.svg"]}`.
- The archive **must not** contain symlinks, absolute paths, or path traversal (`..`).
- Total uncompressed size on ESP32 is constrained by available flash (~900KB after firmware + OTA + NVS). Individual `.wasm` targets 2–10KB; full packages including media should stay under 512KB for reliable mesh propagation.

### manifest.json

```json
{
  "id":              "chat.geogram.messenger",
  "version":         "1.0.0",
  "kind":            "app",
  "description":     "Offline mesh chat with NOSTR signing",
  "summary":         "End-to-end encrypted messaging over BLE, WiFi Direct, and APRS.\nWorks without any internet connection.",
  "icon":            "media/icons/app-icon.svg",
  "screenshots":     ["media/images/screen-home.png", "media/images/screen-settings.png"],
  "tags":            ["messaging", "radio", "mesh"],
  "entry_ui":        "screens/home.ui.json",
  "tick_interval_ms": 2000,
  "permissions":     ["microphone", "network", "storage", "ble", "radio"],
  "provides": {
    "functions": [],
    "events":    ["message.received", "node.seen"],
    "variables": ["my.nickname", "my.callsign"]
  },
  "requires": {
    "hal":       ["kv", "log", "http", "ble"],
    "events":    [],
    "libraries": [],
    "variables": []
  }
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | Reverse-domain identifier |
| `version` | string | yes | Semantic version |
| `kind` | string | yes | `"app"` or `"library"` |
| `description` | string | yes | One-line summary |
| `summary` | string | no | Longer description, markdown ok |
| `icon` | string | no | Path within archive to icon (SVG preferred) |
| `screenshots` | string[] | no | Paths within archive to screenshots |
| `tags` | string[] | no | Category tags for discovery |
| `entry_ui` | string | no | First `.ui.json` file to display on launch |
| `tick_interval_ms` | int\|null | no | WASM tick rate; null for libraries |
| `permissions` | string[] | no | Declared capabilities the host must grant |
| `provides` | object | no | Events, functions, variables this wapp exports |
| `requires` | object | no | HAL features, libraries, and variables needed |

---

## 3. UI Language — GeoUI (.ui.json files)

GeoUI uses plain JSON to describe user interfaces. It is:

- **Standard JSON.** Any language's built-in JSON decoder can read the files — no custom parser needed.
- **Not a stylesheet.** It describes interactive menus and screens, not visual presentation.
- **Renderer-agnostic.** Each host translates GeoUI primitives into its own native widgets.
- **Trivially parseable on ESP32.** `cJSON` handles it; ~30 lines of C to walk blocks.

### 3.1 JSON Schema

Every `.ui.json` file is a **JSON array** of block objects at the root.

**Block structure:**

```json
{
  "$": "keyword",
  "name": "optional name",
  "$type": "optional block type",
  "children": [ ... ],
  "anyDecl": "value"
}
```

| Key | Type | Description |
|---|---|---|
| `$` | string | Block keyword (`screen`, `group`, `field`, `action`, etc.) |
| `name` | string | Optional block name |
| `$type` | string | Optional block type (e.g. `"float"` on a field). Uses `$` prefix to avoid collision with `type` declarations in result blocks. |
| `children` | array | Nested blocks (omit when empty) |
| *(other keys)* | any | Declarations — values are strings, numbers, booleans, arrays, or function calls |

**Function calls** use `{"$fn": "name", "args": [...]}`:

```json
{ "$fn": "field", "args": ["command"] }
{ "$fn": "response", "args": ["error"] }
{ "$fn": "media", "args": ["send.svg"] }
```

### 3.2 Structure

```json
[{
  "$": "app",
  "name": "Label",
  "version": 0.8,
  "base-url": "/api",
  "tip": "...",
  "children": [
    {
      "$": "icons",
      "children": [
        { "$": "set", "name": "file", "for": ["web", "lvgl", "email"] },
        { "$": "set", "name": "emoji", "for": ["web", "cli", "email", "lvgl"] },
        { "$": "set", "name": "text", "for": ["cli", "email"] }
      ]
    },
    { "$": "screen", "name": "Name", "children": [ ] },
    { "$": "screen", "name": "Name", "children": [ ] }
  ]
}]
```

A `.ui.json` file may contain a single `app` block (full definition) or one or more bare `screen` blocks (screen-only file, referenced from a parent app). The `entry_ui` in `manifest.json` points to the app-level file; additional screens may be split into separate `.ui.json` files and included:

```json
{ "$": "include", "name": "screens/settings.ui.json" }
{ "$": "include", "name": "screens/chat.ui.json" }
```

### 3.3 Field Types

| Type | CLI form | Web widget | LVGL widget | Description |
|---|---|---|---|---|
| `string` | `--name value` | `<input type=text>` | `lv_textarea` | Single-line text |
| `text` | `--body "..."` | `<textarea>` | `lv_textarea` multiline | Multi-line text |
| `bool` | `--private` (flag) | `<input type=checkbox>` | `lv_switch` | True/false toggle |
| `int` | `--count 5` | `<input type=number>` | `lv_spinbox` | Integer |
| `float` | `--freq 144.800` | `<input type=number step=any>` | `lv_spinbox` | Decimal |
| `enum` | `--mode [a\|b\|c]` | `<select>` | `lv_roller` | Predefined options |
| `image` | `--avatar path` | file picker | `lv_img` upload | Image file |
| `file` | `--attach path` | file picker | file icon | Binary attachment |

### 3.4 Icon Resolution

Every icon block lists renderers from most specific to most generic. The renderer picks the first entry it supports:

```
icon {
  file:  media(send.svg);    /* web, LVGL, email — from media/ folder */
  emoji: 📤;                 /* universal fallback */
  text:  [send];             /* CLI, plain email — last resort */
}
```

### 3.5 Image Sources

| Source | Syntax | Use |
|---|---|---|
| Bundled asset | `media(filename)` | Logo, banner, static art |
| API response | `response(field)` | Dynamic avatars in lists |
| Generated — QR | `qr(value)` | Key export, identity share |
| Generated — initials | `initials(expr)` | Avatar fallback |
| Generated — map | `map(lat, lon)` | GPS position display |

Generated images fall back to text on renderers that cannot produce them: `qr()` prints the URI, `initials()` prints the name, `map()` prints coordinates.

### 3.6 Image Roles

| Role | Web | LVGL | CLI | Email |
|---|---|---|---|---|
| `banner` | full-width header | top strip | skipped | header image |
| `avatar` | circle crop | circle mask | initials | inline attachment |
| `logo` | `<img>` in nav | `lv_img` top-left | skipped | email header |
| `inline` | flows with content | `lv_img` in card | skipped | inline CID |
| `attachment` | download link | file icon | path printed | attached file |

---

## 4. Complete .ui.json Syntax Reference

### 4.1 Screens, Groups, Fields

```json
[{
  "$": "screen",
  "name": "Home",
  "tip": "Compose and send a message over the available transport.",
  "children": [
    {
      "$": "image",
      "source": { "$fn": "media", "args": ["home-banner.png"] },
      "alt": "Mesh network",
      "size": "medium",
      "role": "banner"
    },
    {
      "$": "group",
      "name": "Identity",
      "tip": "Who you are on the mesh. Shared with peers on transmit.",
      "children": [
        {
          "$": "field", "name": "nickname", "$type": "string",
          "label": "Nickname", "default": "",
          "tip": "Your human-readable name. Does not need to be unique.",
          "hint": "e.g. Ritu",
          "children": [{
            "$": "icon",
            "file": { "$fn": "media", "args": ["person.svg"] },
            "emoji": "\ud83d\udc64", "text": "[user]"
          }]
        },
        {
          "$": "field", "name": "callsign", "$type": "string",
          "label": "Callsign", "default": "",
          "tip": "Amateur radio callsign. Used in APRS frames.",
          "hint": "e.g. CT1ABC",
          "validate": { "$fn": "regex", "args": ["[A-Z0-9]{3,8}"] }
        },
        {
          "$": "field", "name": "private", "$type": "bool",
          "label": "Private mode", "default": false,
          "tip": "Omits your identity from unencrypted broadcast frames.",
          "children": [{
            "$": "icon",
            "file": { "$fn": "media", "args": ["lock.svg"] },
            "emoji": "\ud83d\udd12", "text": "[lock]"
          }]
        },
        {
          "$": "field", "name": "avatar", "$type": "image",
          "label": "Avatar",
          "tip": "Profile image shared with peers over NOSTR.",
          "accept": ["jpg", "png", "webp"],
          "max-size": "64kb", "role": "avatar",
          "fallback": { "$fn": "initials", "args": [{ "$fn": "field", "args": ["nickname"] }] }
        }
      ]
    },
    {
      "$": "group",
      "name": "Compose",
      "children": [
        {
          "$": "field", "name": "body", "$type": "text",
          "label": "Message", "required": true,
          "tip": "Free-form message. Signed with your NOSTR key before sending.",
          "hint": "Keep under 256 chars for reliable radio transport.",
          "children": [{
            "$": "bind", "name": "char-counter",
            "source": { "$fn": "local", "args": [{ "$fn": "length", "args": [{ "$fn": "field", "args": ["body"] }] }] },
            "target": { "$fn": "label", "args": ["char-counter"] },
            "format": "{value}/256",
            "level": { "$fn": "if", "args": ["value > 240", "warning", "normal"] }
          }]
        },
        { "$": "label", "name": "char-counter", "text": "0/256", "style": "meta" },
        {
          "$": "field", "name": "channel", "$type": "enum",
          "label": "Transport", "default": "mesh",
          "tip": "Which physical layer carries your message.",
          "hint": "Mesh=local,  Radio=100km,  NOSTR=store-and-forward.",
          "children": [
            {
              "$": "option", "name": "mesh",
              "label": "Mesh (BLE / WiFi)",
              "tip": "Short-range. BLE beacons and WiFi Direct. No license needed.",
              "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["mesh.svg"] }, "emoji": "\ud83d\udce1", "text": "[mesh]" }]
            },
            {
              "$": "option", "name": "radio",
              "label": "Radio (APRS)",
              "tip": "Medium-range ~100km. Requires amateur radio license.",
              "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["radio.svg"] }, "emoji": "\ud83d\udcfb", "text": "[radio]" }]
            },
            {
              "$": "option", "name": "nostr",
              "label": "NOSTR Relay",
              "tip": "Store-and-forward. Syncs when a relay is reachable.",
              "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["nostr.svg"] }, "emoji": "\u26a1", "text": "[nostr]" }]
            }
          ]
        },
        {
          "$": "field", "name": "attachment", "$type": "file",
          "label": "Attachment",
          "tip": "Optional file sent alongside the message.",
          "accept": ["jpg", "png", "pdf"],
          "max-size": "512kb", "required": false,
          "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["attach.svg"] }, "emoji": "\ud83d\udcce", "text": "[attach]" }]
        }
      ]
    }
  ]
}]
```

### 4.2 Actions with API Binding

Actions connect directly to `app.wasm` via the module's internal HTTP API. The `endpoint` path is relative to `base-url`.

```json
{
  "$": "action", "name": "send",
  "label": "Send",
  "style": "primary",
  "confirm": false,
  "tip": "Sign and transmit on the selected transport.",
  "children": [
    {
      "$": "icon",
      "file": { "$fn": "media", "args": ["send.svg"] },
      "emoji": "\ud83d\udce4", "text": "[send]"
    },
    {
      "$": "request",
      "method": "POST",
      "endpoint": "/send",
      "children": [{
        "$": "body",
        "nickname": { "$fn": "field", "args": ["nickname"] },
        "private": { "$fn": "field", "args": ["private"] },
        "message": { "$fn": "field", "args": ["body"] },
        "channel": { "$fn": "field", "args": ["channel"] },
        "attachment": { "$fn": "field", "args": ["attachment"] }
      }]
    },
    {
      "$": "result",
      "children": [
        { "$": "200", "type": "toast", "message": { "$fn": "response", "args": ["status_message"] }, "level": "success", "then": "clear-form" },
        { "$": "4xx", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" },
        { "$": "5xx", "type": "toast", "message": "Server error. Try again.", "level": "error" }
      ]
    }
  ]
}
```

A purely local action (no request block):

```json
{
  "$": "action", "name": "clear",
  "label": "Clear",
  "style": "danger",
  "tip": "Discard all fields and reset to defaults.",
  "confirm": true,
  "confirm-label": "Clear everything?",
  "children": [{
    "$": "icon",
    "file": { "$fn": "media", "args": ["trash.svg"] },
    "emoji": "\ud83d\uddd1\ufe0f", "text": "[del]"
  }]
}
```

### 4.3 Result Status Codes

Every `result` block contains one or more **status matchers** as child blocks. Matchers are tested top to bottom; the first match wins.

```json
{
  "$": "result",
  "children": [
    { "$": "optimistic" },
    { "$": "200" },
    { "$": "201" },
    { "$": "404" },
    { "$": "4xx" },
    { "$": "5xx" },
    { "$": "*" }
  ]
}
```

**Supported matcher forms:**

| Matcher (`$`) | Matches |
|---|---|
| `200` | Exactly HTTP 200 |
| `201` | Exactly HTTP 201 |
| `404` | Exactly HTTP 404 |
| `2xx` | Any 200–299 |
| `4xx` | Any 400–499 |
| `5xx` | Any 500–599 |
| `*` | Any code not matched above |

On renderers with no HTTP (pure local actions), the wapp runtime returns `200` on success and `500` on failure, so matchers still work.

---

### 4.4 Result Handler Types

**`toast`** — ephemeral notification

```json
{
  "$": "200",
  "type": "toast",
  "message": { "$fn": "response", "args": ["status_message"] },
  "level": "success",
  "then": "clear-form"
}
```

**`inline`** — rendered beneath the button

```json
{
  "$": "200",
  "type": "inline",
  "title": "Your export key",
  "display": { "$fn": "qr", "args": [{ "$fn": "response", "args": ["bunker_uri"] }] },
  "children": [{
    "$": "display",
    "size": "large",
    "alt": "NOSTR bunker URI QR code",
    "fallback": { "$fn": "text", "args": [{ "$fn": "response", "args": ["bunker_uri"] }] }
  }]
}
```

**`field`** — write a response value back into a named field

```json
{
  "$": "200",
  "type": "field",
  "write": "pubkey <- response(npub)",
  "then": "toast(\"New keypair generated.\")"
}
```

**`mutation`** — modify a live list without full re-render

```json
{
  "$": "200",
  "type": "mutation",
  "target": "messages-list",
  "op": "update",
  "where": "id == response(id)",
  "children": [{
    "$": "set",
    "pending": false,
    "id": { "$fn": "response", "args": ["id"] }
  }]
}
```

**`redirect`** — navigate to another screen

```json
{ "$": "200", "type": "redirect", "screen": "inbox" }
```

---

### 4.5 Reactive Data — `watch`, `bind`, `stream`

#### `watch` — polling (Tier 1, works on all renderers)

```json
{
  "$": "group", "name": "Messages",
  "children": [{
    "$": "watch",
    "endpoint": "/messages",
    "interval": "5s",
    "children": [
      {
        "$": "params",
        "limit": 20,
        "after": { "$fn": "state", "args": ["last_message_id"] }
      },
      {
        "$": "result",
        "type": "list", "id": "messages-list", "empty": "No messages yet.",
        "children": [
          {
            "$": "200",
            "strategy": "append-new",
            "track-by": { "$fn": "response", "args": ["id"] },
            "scroll": "bottom",
            "update": "state(last_message_id) <- response(last_id)"
          },
          { "$": "4xx", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" },
          { "$": "5xx", "type": "toast", "message": "Could not fetch messages.", "level": "error" },
          {
            "$": "item",
            "title": { "$fn": "response", "args": ["nickname"] },
            "subtitle": { "$fn": "response", "args": ["message"] },
            "timestamp": { "$fn": "response", "args": ["sent_at"] },
            "children": [
              {
                "$": "image",
                "source": { "$fn": "response", "args": ["avatar_url"] },
                "alt": { "$fn": "response", "args": ["nickname"] },
                "size": "small", "role": "avatar",
                "fallback": { "$fn": "initials", "args": [{ "$fn": "response", "args": ["nickname"] }] }
              },
              {
                "$": "icon",
                "from": { "$fn": "response", "args": ["channel"] },
                "file": [{ "$fn": "media", "args": ["mesh.svg"] }, { "$fn": "media", "args": ["radio.svg"] }, { "$fn": "media", "args": ["nostr.svg"] }],
                "emoji": ["\ud83d\udce1", "\ud83d\udcfb", "\u26a1"],
                "text": ["[mesh]", "[radio]", "[nostr]"]
              },
              {
                "$": "action", "name": "delete-message",
                "label": "Delete", "style": "danger",
                "visible": "if(response(own) == true)",
                "children": [
                  { "$": "icon", "file": { "$fn": "media", "args": ["trash.svg"] }, "emoji": "\ud83d\uddd1\ufe0f", "text": "[del]" },
                  { "$": "request", "method": "DELETE", "endpoint": "/messages/{response(id)}" },
                  {
                    "$": "result", "children": [
                      { "$": "200", "type": "mutation", "target": "messages-list", "op": "remove", "where": "id == response(id)" },
                      { "$": "404", "type": "mutation", "target": "messages-list", "op": "remove", "where": "id == response(id)" },
                      { "$": "4xx", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" },
                      { "$": "5xx", "type": "toast", "message": "Could not delete message.", "level": "error" }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }
    ]
  }]
}
```

#### `bind` — live local or endpoint binding (Tier 2)

`bind` uses named change events rather than status codes, because local binds have no HTTP round-trip. Only endpoint-backed binds use status matchers for their outgoing PATCH/POST:

```json
{
  "$": "bind", "name": "char-counter",
  "source": { "$fn": "local", "args": [{ "$fn": "length", "args": [{ "$fn": "field", "args": ["body"] }] }] },
  "target": { "$fn": "label", "args": ["char-counter"] },
  "format": "{value}/256",
  "level": { "$fn": "if", "args": ["value > 240", "warning", "normal"] }
}
```

Two-way endpoint bind (collaborative shared text field):

```json
{
  "$": "field", "name": "notes", "$type": "text",
  "label": "Shared Notes",
  "children": [{
    "$": "bind", "name": "live-notes",
    "source": "endpoint(/notes/live)",
    "direction": "both",
    "transport": "sse",
    "debounce": "500ms",
    "children": [
      {
        "$": "on-local-change",
        "method": "PATCH", "endpoint": "/notes",
        "children": [
          { "$": "body", "delta": { "$fn": "diff", "args": [{ "$fn": "field", "args": ["notes"] }] } },
          {
            "$": "result", "children": [
              { "$": "2xx" },
              { "$": "4xx", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" },
              { "$": "5xx", "type": "toast", "message": "Sync failed.", "level": "error" }
            ]
          }
        ]
      },
      {
        "$": "on-remote-change",
        "op": "merge-diff",
        "then": "update(field(notes))"
      }
    ]
  }]
}
```

#### `stream` — persistent connection for continuous data (Tier 3)

```json
{
  "$": "group", "name": "Audio",
  "tip": "Send and receive audio over the mesh.",
  "children": [
    {
      "$": "stream", "name": "audio-out",
      "type": "audio", "direction": "receive", "transport": "mesh-socket",
      "endpoint": "/stream/audio", "codec": "opus", "fallback": "wav", "requires": "speaker",
      "children": [
        { "$": "indicator", "type": "waveform", "label": "Receiving audio" },
        {
          "$": "controls", "children": [
            { "$": "action", "name": "play-audio", "label": "Play", "style": "primary",
              "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["play.svg"] }, "emoji": "\u25b6\ufe0f", "text": "[play]" }] },
            { "$": "action", "name": "stop-audio", "label": "Stop", "style": "secondary",
              "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["stop.svg"] }, "emoji": "\u23f9\ufe0f", "text": "[stop]" }] }
          ]
        }
      ]
    },
    {
      "$": "stream", "name": "audio-in",
      "type": "audio", "direction": "send", "transport": "mesh-socket",
      "endpoint": "/stream/audio/publish", "codec": "opus", "requires": "microphone",
      "children": [
        { "$": "indicator", "type": "level", "label": "Microphone level" },
        {
          "$": "controls", "children": [
            { "$": "action", "name": "transmit", "label": "Transmit", "style": "primary", "hold": true,
              "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["mic.svg"] }, "emoji": "\ud83c\udf99\ufe0f", "text": "[tx]" }] }
          ]
        }
      ]
    }
  ]
}
```

### 4.6 Optimistic Updates

`optimistic` is a special matcher that fires **before** the request is sent. If the request fails, the renderer automatically rolls back any mutations made in the `optimistic` block — unless an explicit rollback handler is defined.

```json
{
  "$": "result",
  "children": [
    {
      "$": "optimistic",
      "type": "mutation", "target": "messages-list", "op": "append",
      "children": [{
        "$": "item",
        "nickname": { "$fn": "state", "args": ["my_nickname"] },
        "message": { "$fn": "field", "args": ["body"] },
        "sent_at": { "$fn": "now", "args": [] },
        "own": true, "pending": true
      }]
    },
    {
      "$": "200",
      "type": "mutation", "target": "messages-list", "op": "update",
      "where": "pending == true",
      "then": "clear(field(body))",
      "children": [{ "$": "set", "pending": false, "id": { "$fn": "response", "args": ["id"] } }]
    },
    {
      "$": "4xx",
      "type": "mutation", "target": "messages-list", "op": "remove",
      "where": "pending == true",
      "children": [{ "$": "then", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" }]
    },
    {
      "$": "5xx",
      "type": "mutation", "target": "messages-list", "op": "remove",
      "where": "pending == true",
      "children": [{ "$": "then", "type": "toast", "message": "Failed to send. Message discarded.", "level": "error" }]
    }
  ]
}
```

---

## 5. WASM ↔ UI Communication

The `.ui.json` actions call the module's internal HTTP API, which the wapp runtime exposes on localhost. This is the same HTTP API used by `wasm_library_server.dart` — the UI renderer is just another HTTP client.

```
┌─────────────────────────────────────────────────────────┐
│  Renderer (web / Flutter / CLI / LVGL)                  │
│                                                         │
│   .ui.json parsed → screen rendered                     │
│   action fired   → HTTP POST /api/send                  │
│                         ↓                               │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Wapp Runtime (localhost HTTP on each platform)  │   │
│  │                                                  │   │
│  │   /api/<endpoint>  →  hal_msg_send(json)         │   │
│  │   module_tick()    →  watch/bind poll cycles     │   │
│  │   hal_msg_send()   →  push updates to UI         │   │
│  └──────────────────────────────────────────────────┘   │
│                         ↓                               │
│               app.wasm (business logic)                 │
└─────────────────────────────────────────────────────────┘
```

### Push updates from WASM to UI

When `app.wasm` calls `hal_msg_send()` with a JSON payload, the runtime forwards it to any listening UI renderer. The renderer matches the message type to a live list or field binding:

```json
{ "type": "ui.append",   "target": "messages-list", "item": { ... } }
{ "type": "ui.remove",   "target": "messages-list", "where": { "id": "abc" } }
{ "type": "ui.update",   "target": "messages-list", "where": { "id": "abc" }, "set": { ... } }
{ "type": "ui.field",    "target": "pubkey",         "value": "npub1..." }
{ "type": "ui.toast",    "message": "Relay connected.", "level": "info" }
{ "type": "ui.redirect", "screen": "inbox" }
```

This means `watch` polling is the renderer-initiated path (renderer asks the module), while `hal_msg_send` is the module-initiated path (module pushes to renderer). Both are needed: polling covers ESP32 where persistent connections are expensive; push covers desktop/web where events arrive from the mesh asynchronously.

---

## 6. Renderer Behaviour Matrix

| Feature | Web | Flutter/Android | LVGL/ESP32 | CLI |
|---|---|---|---|---|
| `screen` | page / tab | `Navigator` route | `lv_tabview` | subcommand |
| `group` | `<fieldset>` | `Card` widget | `lv_cont` | `--help` section |
| `field : string` | `<input>` | `TextField` | `lv_textarea` | `--name value` |
| `field : bool` | `<checkbox>` | `Switch` | `lv_switch` | `--flag` |
| `field : enum` | `<select>` | `DropdownButton` | `lv_roller` | `--mode [a\|b\|c]` |
| `action primary` | `<button>` submit | `ElevatedButton` | accent `lv_btn` | positional verb |
| `action danger` | red button | destructive style | red `lv_btn` | prompts confirm |
| `tip` | tooltip on hover | long-press sheet | long-press `lv_msgbox` | `--help` body |
| `hint` | `placeholder=` | `hintText=` | `lv_textarea` placeholder | prompt brackets |
| `result 200` | handle response | handle response | handle response | handle response |
| `result 4xx` | show warning toast | show warning toast | `lv_msgbox` warning | print to stderr |
| `result 5xx` | show error toast | show error toast | `lv_msgbox` error | print to stderr |
| `result *` | catch-all handler | catch-all handler | catch-all handler | catch-all handler |
| `optimistic` | immediate + rollback | immediate + rollback | immediate + rollback | immediate + rollback |
| `watch` | `setInterval` + fetch | `Timer.periodic` | FreeRTOS timer | keypress refresh |
| `bind local` | DOM event | `ValueNotifier` | LVGL event cb | stdin listener |
| `bind sse` | `EventSource` | HTTP poll fallback | HTTP poll fallback | poll + print |
| `stream audio` | `MediaStream` API | platform channel | I2S hardware | pipe to `aplay` |
| `stream screen` | `getDisplayMedia` | platform channel | skipped (no cap) | frames to `/tmp` |
| `mutation append` | `appendChild` | `setState` list add | `lv_list_add` | print new line |
| `mutation remove` | `removeChild` | `setState` list remove | `lv_obj_del` | strikethrough |
| `confirm` | browser `confirm()` | `AlertDialog` | `lv_msgbox` | `[y/N]` prompt |
| `hold` action | `pointerdown/up` | `GestureDetector` | `LV_EVENT_PRESSING` | hold Enter |
| `qr()` | canvas render | `qr_flutter` | skipped, URI logged | print URI |
| `initials()` | canvas circle | custom painter | `lv_label` | print name |
| Email renderer | `200 toast` → subject; `inline` → body paragraph; `stream` ignored | | | |

---

## 7. Full Example — geogram-chat.wapp

### Archive layout

```
geogram-chat.wapp
├── app.wasm
├── manifest.json
├── screens/
│   ├── home.ui.json
│   ├── chat.ui.json
│   ├── live.ui.json
│   └── settings.ui.json
└── media/
    ├── icons/
    │   ├── app-icon.svg
    │   ├── send.svg
    │   ├── save.svg
    │   ├── trash.svg
    │   ├── lock.svg
    │   ├── mesh.svg
    │   ├── radio.svg
    │   ├── nostr.svg
    │   ├── mic.svg
    │   ├── play.svg
    │   ├── stop.svg
    │   └── key.svg
    └── images/
        ├── home-banner.png
        └── logo.png
```

### screens/home.ui.json

```json
[{
  "$": "app", "name": "Geogram Chat",
  "version": 0.8, "base-url": "/api",
  "tip": "Offline-first mesh communication. Works without internet.",
  "children": [
    {
      "$": "icons", "children": [
        { "$": "set", "name": "file", "for": ["web", "lvgl", "email"] },
        { "$": "set", "name": "emoji", "for": ["web", "cli", "email", "lvgl"] },
        { "$": "set", "name": "text", "for": ["cli", "email"] }
      ]
    },
    { "$": "include", "name": "screens/chat.ui.json" },
    { "$": "include", "name": "screens/live.ui.json" },
    { "$": "include", "name": "screens/settings.ui.json" },
    {
      "$": "screen", "name": "Home",
      "tip": "Compose and send a message over the available transport.",
      "children": [
        {
          "$": "image",
          "source": { "$fn": "media", "args": ["home-banner.png"] },
          "alt": "Mesh network visualisation", "size": "medium", "role": "banner"
        },
        {
          "$": "group", "name": "Identity",
          "tip": "Who you are on the mesh. Shared with peers on transmit.",
          "children": [
            {
              "$": "field", "name": "nickname", "$type": "string",
              "label": "Nickname", "default": "",
              "tip": "Your human-readable name. Does not need to be unique.",
              "hint": "e.g. Ritu",
              "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["person.svg"] }, "emoji": "\ud83d\udc64", "text": "[user]" }]
            },
            {
              "$": "field", "name": "callsign", "$type": "string",
              "label": "Callsign", "default": "",
              "tip": "Your amateur radio callsign. Used in APRS frames.",
              "hint": "e.g. CT1ABC",
              "validate": { "$fn": "regex", "args": ["[A-Z0-9]{3,8}"] }
            },
            {
              "$": "field", "name": "private", "$type": "bool",
              "label": "Private mode", "default": false,
              "tip": "Omits your identity from unencrypted broadcast frames.",
              "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["lock.svg"] }, "emoji": "\ud83d\udd12", "text": "[lock]" }]
            },
            {
              "$": "field", "name": "avatar", "$type": "image",
              "label": "Avatar", "tip": "Profile image shared with peers over NOSTR.",
              "accept": ["jpg", "png", "webp"], "max-size": "64kb", "role": "avatar",
              "fallback": { "$fn": "initials", "args": [{ "$fn": "field", "args": ["nickname"] }] }
            }
          ]
        },
        {
          "$": "group", "name": "Compose",
          "tip": "Your message. Signed and encrypted before sending.",
          "children": [
            {
              "$": "field", "name": "body", "$type": "text",
              "label": "Message", "required": true,
              "tip": "Free-form message body. Signed with your NOSTR key.",
              "hint": "Keep under 256 chars for reliable radio transport.",
              "children": [{
                "$": "bind", "name": "char-counter",
                "source": { "$fn": "local", "args": [{ "$fn": "length", "args": [{ "$fn": "field", "args": ["body"] }] }] },
                "target": { "$fn": "label", "args": ["char-counter"] },
                "format": "{value}/256",
                "level": { "$fn": "if", "args": ["value > 240", "warning", "normal"] }
              }]
            },
            { "$": "label", "name": "char-counter", "text": "0/256", "style": "meta" },
            {
              "$": "field", "name": "channel", "$type": "enum",
              "label": "Transport", "default": "mesh",
              "tip": "Which physical layer carries your message.",
              "children": [
                { "$": "option", "name": "mesh", "label": "Mesh (BLE / WiFi)",
                  "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["mesh.svg"] }, "emoji": "\ud83d\udce1", "text": "[mesh]" }] },
                { "$": "option", "name": "radio", "label": "Radio (APRS)",
                  "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["radio.svg"] }, "emoji": "\ud83d\udcfb", "text": "[radio]" }] },
                { "$": "option", "name": "nostr", "label": "NOSTR Relay",
                  "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["nostr.svg"] }, "emoji": "\u26a1", "text": "[nostr]" }] }
              ]
            },
            {
              "$": "field", "name": "attachment", "$type": "file",
              "label": "Attachment", "tip": "Optional file sent alongside the message.",
              "accept": ["jpg", "png", "pdf"], "max-size": "512kb", "required": false,
              "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["attach.svg"] }, "emoji": "\ud83d\udcce", "text": "[attach]" }]
            }
          ]
        },
        {
          "$": "action", "name": "send",
          "label": "Send", "style": "primary", "confirm": false,
          "tip": "Sign and transmit on the selected transport.",
          "children": [
            { "$": "icon", "file": { "$fn": "media", "args": ["send.svg"] }, "emoji": "\ud83d\udce4", "text": "[send]" },
            { "$": "request", "method": "POST", "endpoint": "/send",
              "children": [{ "$": "body",
                "nickname": { "$fn": "field", "args": ["nickname"] },
                "private": { "$fn": "field", "args": ["private"] },
                "message": { "$fn": "field", "args": ["body"] },
                "channel": { "$fn": "field", "args": ["channel"] },
                "attachment": { "$fn": "field", "args": ["attachment"] }
              }]
            },
            { "$": "result", "children": [
              { "$": "optimistic", "type": "mutation", "target": "messages-list", "op": "append",
                "children": [{ "$": "item",
                  "nickname": { "$fn": "state", "args": ["my_nickname"] },
                  "message": { "$fn": "field", "args": ["body"] },
                  "sent_at": { "$fn": "now", "args": [] }, "own": true, "pending": true
                }]
              },
              { "$": "200", "type": "mutation", "target": "messages-list", "op": "update",
                "where": "pending == true", "then": "clear(field(body))",
                "children": [{ "$": "set", "pending": false, "id": { "$fn": "response", "args": ["id"] } }]
              },
              { "$": "4xx", "type": "mutation", "target": "messages-list", "op": "remove",
                "where": "pending == true",
                "children": [{ "$": "then", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" }]
              },
              { "$": "5xx", "type": "mutation", "target": "messages-list", "op": "remove",
                "where": "pending == true",
                "children": [{ "$": "then", "type": "toast", "message": "Send failed. Try again.", "level": "error" }]
              }
            ]}
          ]
        },
        {
          "$": "action", "name": "draft",
          "label": "Save Draft", "style": "secondary",
          "tip": "Save locally without transmitting.",
          "children": [
            { "$": "icon", "file": { "$fn": "media", "args": ["save.svg"] }, "emoji": "\ud83d\udcbe", "text": "[save]" },
            { "$": "request", "method": "POST", "endpoint": "/drafts",
              "children": [{ "$": "body",
                "message": { "$fn": "field", "args": ["body"] },
                "channel": { "$fn": "field", "args": ["channel"] }
              }]
            },
            { "$": "result", "children": [
              { "$": "200", "type": "toast", "message": "Draft saved.", "level": "success" },
              { "$": "4xx", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" },
              { "$": "5xx", "type": "toast", "message": "Could not save draft.", "level": "error" }
            ]}
          ]
        },
        {
          "$": "action", "name": "clear",
          "label": "Clear", "style": "danger", "confirm": true,
          "confirm-label": "Clear everything?",
          "tip": "Discard all fields and reset to defaults.",
          "children": [{ "$": "icon", "file": { "$fn": "media", "args": ["trash.svg"] }, "emoji": "\ud83d\uddd1\ufe0f", "text": "[del]" }]
        }
      ]
    }
  ]
}]
```

### screens/settings.ui.json (excerpt — key regeneration)

```json
[{
  "$": "screen", "name": "Settings",
  "tip": "Configure radio, network, and identity keys.",
  "children": [
    {
      "$": "group", "name": "Identity Keys",
      "tip": "Your NOSTR keypair. The private key never leaves this device.",
      "children": [
        {
          "$": "field", "name": "pubkey", "$type": "string",
          "label": "Public Key (npub)", "readonly": true,
          "tip": "Your NOSTR public key. Safe to share.",
          "hint": "Starts with npub1..."
        },
        {
          "$": "action", "name": "regen",
          "label": "Regenerate Keys", "style": "danger",
          "tip": "Creates a new keypair. Old messages become unreadable.",
          "confirm": true, "confirm-label": "Regenerate? This cannot be undone.",
          "children": [
            { "$": "icon", "file": { "$fn": "media", "args": ["key.svg"] }, "emoji": "\ud83d\udd11", "text": "[key]" },
            { "$": "request", "method": "POST", "endpoint": "/keys/regenerate" },
            { "$": "result", "children": [
              { "$": "200", "type": "field", "write": "pubkey <- response(npub)", "then": "toast(\"New keypair generated.\")" },
              { "$": "409", "type": "toast", "message": "Key operation already in progress. Please wait.", "level": "warning" },
              { "$": "4xx", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" },
              { "$": "5xx", "type": "toast", "message": "Key generation failed. Hardware RNG may be unavailable.", "level": "error" }
            ]}
          ]
        },
        {
          "$": "action", "name": "export",
          "label": "Export Keys", "style": "secondary",
          "tip": "Export keypair as QR code or NOSTR bunker URI.",
          "children": [
            { "$": "icon", "file": { "$fn": "media", "args": ["export.svg"] }, "emoji": "\ud83d\udcf7", "text": "[qr]" },
            { "$": "request", "method": "GET", "endpoint": "/keys/export" },
            { "$": "result", "children": [
              { "$": "200", "type": "inline", "title": "Scan to import on another device",
                "display": { "$fn": "qr", "args": [{ "$fn": "response", "args": ["bunker_uri"] }] },
                "children": [{ "$": "display", "size": "large", "alt": "NOSTR bunker URI QR code",
                  "fallback": { "$fn": "text", "args": [{ "$fn": "response", "args": ["bunker_uri"] }] }
                }]
              },
              { "$": "4xx", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" },
              { "$": "5xx", "type": "toast", "message": "Export failed.", "level": "error" }
            ]}
          ]
        }
      ]
    },
    {
      "$": "action", "name": "save",
      "label": "Save Settings", "style": "primary",
      "tip": "Write all settings to persistent storage.",
      "children": [
        { "$": "icon", "file": { "$fn": "media", "args": ["check.svg"] }, "emoji": "\u2705", "text": "[save]" },
        { "$": "request", "method": "POST", "endpoint": "/settings",
          "children": [{ "$": "body",
            "frequency": { "$fn": "field", "args": ["frequency"] },
            "power": { "$fn": "field", "args": ["power"] },
            "relay": { "$fn": "field", "args": ["relay"] },
            "beacon": { "$fn": "field", "args": ["beacon"] }
          }]
        },
        { "$": "result", "children": [
          { "$": "200", "type": "toast", "message": "Settings saved.", "level": "success" },
          { "$": "4xx", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" },
          { "$": "5xx", "type": "toast", "message": "Could not save settings.", "level": "error" }
        ]}
      ]
    },
    {
      "$": "action", "name": "reset",
      "label": "Reset Defaults", "style": "danger",
      "tip": "Restore all settings to factory defaults.",
      "confirm": true, "confirm-label": "Reset all settings to defaults?",
      "children": [
        { "$": "icon", "file": { "$fn": "media", "args": ["reset.svg"] }, "emoji": "\ud83d\udd04", "text": "[reset]" },
        { "$": "request", "method": "POST", "endpoint": "/settings/reset" },
        { "$": "result", "children": [
          { "$": "200", "type": "redirect", "screen": "settings" },
          { "$": "4xx", "type": "toast", "message": { "$fn": "response", "args": ["error"] }, "level": "warning" },
          { "$": "5xx", "type": "toast", "message": "Reset failed.", "level": "error" }
        ]}
      ]
    }
  ]
}]
```

---

## 8. HAL Integration Points

The UI runtime interacts with `app.wasm` through the standard HAL. No new HAL functions are needed — the UI layer is a consumer of the existing API surface.

| UI behaviour | HAL mechanism |
|---|---|
| Action fires → HTTP status returned | renderer → `hal_http_request` → module processes → HTTP status code → result matcher |
| `watch` poll | renderer timer → `hal_http_request` GET → module reads from KV/mesh → JSON response |
| `bind sse` | renderer → SSE connection → module publishes via `hal_event_publish` → host bridges to SSE |
| `stream audio` | renderer → `hal_msg_send({"type":"stream.start"})` → module opens I2S / audio socket |
| `hal_msg_send` push | module sends `{"type":"ui.append",...}` → host forwards to renderer |
| State persistence | module uses `hal_kv_set` / `hal_kv_get`; renderer reads via GET /state/{key} |

### Status code conventions for `app.wasm` authors

The WASM module is responsible for returning appropriate HTTP status codes from its API endpoints. Recommended conventions:

| Code | Meaning | When to use |
|---|---|---|
| `200` | OK | Request succeeded, response body contains data |
| `201` | Created | Resource created (new message, new draft) |
| `204` | No Content | Succeeded but no response body (clear, reset) |
| `400` | Bad Request | Validation failed, malformed input |
| `401` | Unauthorised | Missing or invalid NOSTR signature |
| `404` | Not Found | Resource does not exist (deleted message, unknown key) |
| `409` | Conflict | Operation already in progress or state conflict |
| `413` | Payload Too Large | Attachment exceeds `max-size` |
| `429` | Too Many Requests | Rate limit on radio transmit |
| `500` | Internal Error | WASM logic failure |
| `503` | Service Unavailable | Hardware not ready (radio module offline, no GPS fix) |

---

## 9. Mesh Distribution

`.wapp` files propagate over the Geogram mesh as NOSTR events:

```json
{
  "kind": 32200,
  "tags": [
    ["d",       "chat.geogram.messenger"],
    ["version", "1.0.0"],
    ["size",    "48320"],
    ["hash",    "sha256:abcdef..."],
    ["sig",     "bip340:..."]
  ],
  "content": "<base64-encoded .wapp archive>"
}
```

A node receiving kind `32200` can verify the BIP-340 signature, unpack the archive, validate `app.wasm` against the declared hash, and offer to install it — all without any prior knowledge of the app. The `.ui.json` files inside are rendered immediately; `app.wasm` is loaded into the Wasm3/Wasmer runtime on first launch.

For large packages that exceed NOSTR event size limits, the `content` field carries a magnet-style content-addressed URI and the binary is fetched separately over mesh file transfer.

---

## 10. Implementation Status

| Component | Status | Notes |
|---|---|---|
| WASM HAL + bridge | Done | Wasm3 ESP32, Wasmer desktop/CLI |
| Manifests + events + KV | Done | JSON manifests, event bus, KV backends |
| Library modules | Done | `hal_lib_call`, HTTP API server |
| `.wapp` zip format | Specified | Loader implementation pending |
| GeoUI parser (Dart) | Done | JSON-based, ~80 lines |
| CLI renderer | Planned | Interactive + flag mode |
| Web renderer | Planned | WASM → HTML form via GeoUI |
| Flutter renderer | Planned | GeoUI → Widget tree |
| LVGL renderer | Planned | GeoUI → lv_obj tree (C, build-time) |
| `watch` / polling | Planned | Timer + HTTP GET in each renderer |
| `bind` SSE | Planned | Desktop/web only; poll fallback on ESP32 |
| `stream` audio | Planned | MediaStream web; I2S ESP32; aplay CLI |
| `stream` screen | Planned | getDisplayMedia web; skipped on ESP32 |
| Mesh distribution | Planned | NOSTR kind 32200, BIP-340 verification |
| BIP-340 signing | Planned | `tool/wasm_sign.dart` |
