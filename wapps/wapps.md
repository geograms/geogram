# Geogram Wapp Specification
## Package Format, HAL, and UI Language Reference
**Version 0.8**

---

## 1. Overview

A **wapp** is a self-contained application package that runs identically on ESP32 (Wasm3), Android/Desktop Flutter (Wasmer), CLI (Wasmer), and web browsers. Business logic lives in a single compiled WebAssembly binary. User interfaces are declared in `.ui` files using the GeoUI language — a renderer-agnostic description of screens, fields, actions, and reactive behaviours that each host platform translates into its own native widgets.

```
┌─────────────────────────────────────────────────────┐
│                  myapp.wapp (zip)                    │
│                                                      │
│  app.wasm          ← business logic (required)       │
│  manifest.json     ← metadata, deps, permissions     │
│  screens/          ← UI definitions (.ui files)      │
│    home.ui                                           │
│    settings.ui                                       │
│    chat.ui                                           │
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

The WASM binary is the single source of truth for logic. The `.ui` files are data — they can be updated, propagated over the mesh, and rendered by any conforming host without recompiling `app.wasm`.

---

## 2. Package Format — `.wapp`

A `.wapp` file is a standard ZIP archive with the following layout:

```
app.wasm              ← required, must be at archive root
manifest.json         ← required, must be at archive root
screens/              ← required if the app has a UI
  *.ui
media/                ← optional, all assets live here
  icons/              ← SVG preferred, PNG acceptable
  images/
  audio/
  fonts/
```

### Rules

- `app.wasm` **must** be at the archive root. No subdirectory.
- `manifest.json` **must** be at the archive root.
- `.ui` files **must** live inside `screens/`.
- Media assets **must** live inside `media/`. Subdirectory structure is free-form; the renderer searches recursively.
- Paths in `.ui` files reference assets relative to `media/` by name alone when unambiguous, or by subpath when needed: `media(send.svg)` or `media(icons/send.svg)`.
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
  "entry_ui":        "screens/home.ui",
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
| `entry_ui` | string | no | First `.ui` file to display on launch |
| `tick_interval_ms` | int\|null | no | WASM tick rate; null for libraries |
| `permissions` | string[] | no | Declared capabilities the host must grant |
| `provides` | object | no | Events, functions, variables this wapp exports |
| `requires` | object | no | HAL features, libraries, and variables needed |

---

## 3. UI Language — GeoUI (.ui files)

GeoUI is a brace-delimited declarative language for describing user interfaces. It is:

- **Not indentation-sensitive.** The parser only cares about `{` and `}`. Formatting is cosmetic.
- **Not a stylesheet.** It describes interactive menus and screens, not visual presentation.
- **Renderer-agnostic.** Each host translates GeoUI primitives into its own native widgets.
- **Trivially parseable on ESP32.** The grammar is one recursive function, ~60 lines in C.

### 3.1 Grammar

```
file     :=  block*
block    :=  keyword  name?  type?  "{"  ( declaration | block )*  "}"
decl     :=  key  ":"  value  ";"
value    :=  bare_word | quoted_string | number | bool | func_call | list
func_call:=  name "(" args ")"
```

Comments use `/* ... */`. Semicolons terminate every declaration. Maximum nesting depth is 6: `app → screen → group → field → option → icon`.

### 3.2 Structure

```
app "Label" {
  version:  0.8;
  base-url: /api;           /* prefix for all endpoint paths */
  tip:      "...";

  /* icon sets available to this app */
  icons {
    set file  { for: web, lvgl, email; }
    set emoji { for: web, cli, email, lvgl; }
    set text  { for: cli, email; }
  }

  screen "Name" { ... }
  screen "Name" { ... }
}
```

A `.ui` file may contain a single `app` block (full definition) or one or more bare `screen` blocks (screen-only file, referenced from a parent app). The `entry_ui` in `manifest.json` points to the app-level file; additional screens may be split into separate `.ui` files and included:

```
include "screens/settings.ui";
include "screens/chat.ui";
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

## 4. Complete .ui Syntax Reference

### 4.1 Screens, Groups, Fields

```
screen "Home" {
  tip: "Compose and send a message over the available transport.";

  /* Optional screen-level banner image */
  image {
    source: media(home-banner.png);
    alt:    "Mesh network";
    size:   medium;
    role:   banner;
  }

  group "Identity" {
    tip: "Who you are on the mesh. Shared with peers on transmit.";

    field nickname : string {
      label:   "Nickname";
      default: "";
      tip:     "Your human-readable name. Does not need to be unique.";
      hint:    "e.g. Ritu";
      icon {
        file:  media(person.svg);
        emoji: 👤;
        text:  [user];
      }
    }

    field callsign : string {
      label:    "Callsign";
      default:  "";
      tip:      "Amateur radio callsign. Used in APRS frames.";
      hint:     "e.g. CT1ABC";
      validate: regex("[A-Z0-9]{3,8}");
    }

    field private : bool {
      label:   "Private mode";
      default: false;
      tip:     "Omits your identity from unencrypted broadcast frames.";
      icon {
        file:  media(lock.svg);
        emoji: 🔒;
        text:  [lock];
      }
    }

    /* Image field — user-uploadable avatar */
    field avatar : image {
      label:    "Avatar";
      tip:      "Profile image shared with peers over NOSTR.";
      accept:   jpg, png, webp;
      max-size: 64kb;
      role:     avatar;
      fallback: initials(field(nickname));
    }
  }

  group "Compose" {

    field body : text {
      label:    "Message";
      required: true;
      tip:      "Free-form message. Signed with your NOSTR key before sending.";
      hint:     "Keep under 256 chars for reliable radio transport.";

      /* Live character counter — purely local, no network call */
      bind char-counter {
        source:  local(length(field(body)));
        target:  label(char-counter);
        format:  "{value}/256";
        level:   if(value > 240, warning, normal);
      }
    }

    label char-counter {
      text:  "0/256";
      style: meta;
    }

    field channel : enum {
      label:   "Transport";
      default: mesh;
      tip:     "Which physical layer carries your message.";
      hint:    "Mesh=local,  Radio=100km,  NOSTR=store-and-forward.";

      option mesh {
        label: "Mesh (BLE / WiFi)";
        tip:   "Short-range. BLE beacons and WiFi Direct. No license needed.";
        icon { file: media(mesh.svg);  emoji: 📡; text: [mesh];  }
      }
      option radio {
        label: "Radio (APRS)";
        tip:   "Medium-range ~100km. Requires amateur radio license.";
        icon { file: media(radio.svg); emoji: 📻; text: [radio]; }
      }
      option nostr {
        label: "NOSTR Relay";
        tip:   "Store-and-forward. Syncs when a relay is reachable.";
        icon { file: media(nostr.svg); emoji: ⚡; text: [nostr]; }
      }
    }

    /* Binary file attachment */
    field attachment : file {
      label:    "Attachment";
      tip:      "Optional file sent alongside the message.";
      accept:   jpg, png, pdf;
      max-size: 512kb;
      required: false;
      icon { file: media(attach.svg); emoji: 📎; text: [attach]; }
    }
  }
}
```

### 4.2 Actions with API Binding

Actions connect directly to `app.wasm` via the module's internal HTTP API. The `endpoint` path is relative to `base-url`.

```
action send {
  label:   "Send";
  style:   primary;          /* primary | secondary | danger | ghost */
  confirm: false;
  tip:     "Sign and transmit on the selected transport.";

  icon {
    file:  media(send.svg);
    emoji: 📤;
    text:  [send];
  }

  request {
    method:   POST;
    endpoint: /send;

    body {
      /* field(id)   — reads a field value from the current screen      */
      /* state(key)  — reads a runtime variable maintained by renderer  */
      /* literal     — a constant value                                  */
      nickname:   field(nickname);
      private:    field(private);
      message:    field(body);
      channel:    field(channel);
      attachment: field(attachment);
    }
  }

  result {
    200 {
      type:    toast;
      message: response(status_message);
      level:   success;
      then:    clear-form;
    }
    4xx {
      type:    toast;
      message: response(error);
      level:   warning;
    }
    5xx {
      type:    toast;
      message: "Server error. Try again.";
      level:   error;
    }
  }
}

action clear {
  label:         "Clear";
  style:         danger;
  tip:           "Discard all fields and reset to defaults.";
  confirm:       true;
  confirm-label: "Clear everything?";
  icon { file: media(trash.svg); emoji: 🗑️; text: [del]; }
  /* No request block — purely local action handled by renderer */
}
```

### 4.3 Result Status Codes

Every `result` block contains one or more **status matchers**. Matchers are tested top to bottom; the first match wins.

```
result {
  optimistic { ... }   /* fires immediately, before the request is sent  */
  200        { ... }   /* exact match                                     */
  201        { ... }   /* exact match                                     */
  404        { ... }   /* exact match                                     */
  4xx        { ... }   /* range: any 400–499                             */
  5xx        { ... }   /* range: any 500–599                             */
  *          { ... }   /* catch-all — matches anything not already caught */
}
```

**Supported matcher forms:**

| Matcher | Matches |
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

```
200 {
  type:    toast;
  message: response(status_message);  /* or a literal string */
  level:   success | warning | error | info;
  then:    clear-form | reload | redirect(screen-id) | nothing;
}
```

**`inline`** — rendered beneath the button

```
200 {
  type:    inline;
  title:   "Your export key";
  display: qr(response(bunker_uri)) {
    size:     large;
    alt:      "NOSTR bunker URI QR code";
    fallback: text(response(bunker_uri));
  }
}
```

**`field`** — write a response value back into a named field

```
200 {
  type:  field;
  write: pubkey <- response(npub);
  then:  toast("New keypair generated.");
}
```

**`mutation`** — modify a live list without full re-render

```
200 {
  type:   mutation;
  target: messages-list;     /* id of the list to modify */
  op:     append | prepend | remove | update | clear;
  where:  id == response(id);
  set {
    pending: false;
    id:      response(id);
  }
}
```

**`redirect`** — navigate to another screen

```
200 {
  type:   redirect;
  screen: inbox;
}
```

---

### 4.5 Reactive Data — `watch`, `bind`, `stream`

#### `watch` — polling (Tier 1, works on all renderers)

```
group "Messages" {

  watch {
    endpoint: /messages;
    interval: 5s;
    params {
      limit: 20;
      after: state(last_message_id);
    }

    result {
      type:  list;
      id:    messages-list;
      empty: "No messages yet.";

      200 {
        strategy: append-new;       /* append | prepend | replace | diff */
        track-by: response(id);     /* stable ID for deduplication */
        scroll:   bottom;
        update:   state(last_message_id) <- response(last_id);
      }
      4xx { type: toast; message: response(error); level: warning; }
      5xx { type: toast; message: "Could not fetch messages."; level: error; }

      item {
        image {
          source:   response(avatar_url);
          alt:      response(nickname);
          size:     small;
          role:     avatar;
          fallback: initials(response(nickname));
        }

        title:     response(nickname);
        subtitle:  response(message);
        timestamp: response(sent_at);

        icon {
          from:  response(channel);
          file:  media(mesh.svg), media(radio.svg), media(nostr.svg);
          emoji: 📡, 📻, ⚡;
          text:  [mesh], [radio], [nostr];
        }

        /* Per-item action */
        action delete-message {
          label:   "Delete";
          style:   danger;
          visible: if(response(own) == true);
          icon { file: media(trash.svg); emoji: 🗑️; text: [del]; }

          request {
            method:   DELETE;
            endpoint: /messages/{response(id)};
          }

          result {
            200 {
              type:   mutation;
              target: messages-list;
              op:     remove;
              where:  id == response(id);
            }
            404 {
              /* Message already gone — silently remove from local list too */
              type:   mutation;
              target: messages-list;
              op:     remove;
              where:  id == response(id);
            }
            4xx { type: toast; message: response(error); level: warning; }
            5xx { type: toast; message: "Could not delete message."; level: error; }
          }
        }
      }
    }
  }
}
```

#### `bind` — live local or endpoint binding (Tier 2)

`bind` uses named change events rather than status codes, because local binds have no HTTP round-trip. Only endpoint-backed binds use status matchers for their outgoing PATCH/POST:

```
/* Local bind: no network, purely reactive to field state */
bind char-counter {
  source:    local(length(field(body)));
  target:    label(char-counter);
  format:    "{value}/256";
  level:     if(value > 240, warning, normal);
}

/* Two-way endpoint bind: collaborative shared text field */
field notes : text {
  label: "Shared Notes";

  bind live-notes {
    source:    endpoint(/notes/live);
    direction: both;                   /* in | out | both */
    transport: sse;                    /* poll | sse | websocket */
    debounce:  500ms;

    on-local-change {
      method:   PATCH;
      endpoint: /notes;
      body { delta: diff(field(notes)); }

      result {
        2xx { /* silent — no UI feedback on successful sync */ }
        4xx { type: toast; message: response(error); level: warning; }
        5xx { type: toast; message: "Sync failed."; level: error; }
      }
    }

    on-remote-change {
      op:   merge-diff;
      then: update(field(notes));
    }
  }
}
```

#### `stream` — persistent connection for continuous data (Tier 3)

```
group "Audio" {
  tip: "Send and receive audio over the mesh.";

  /* Receive stream */
  stream audio-out {
    type:      audio;
    direction: receive;
    transport: mesh-socket;
    endpoint:  /stream/audio;
    codec:     opus;
    fallback:  wav;
    requires:  speaker;

    indicator {
      type:  waveform;
      label: "Receiving audio";
    }

    controls {
      action play-audio {
        label: "Play";
        style: primary;
        icon { file: media(play.svg); emoji: ▶️; text: [play]; }
      }
      action stop-audio {
        label: "Stop";
        style: secondary;
        icon { file: media(stop.svg); emoji: ⏹️; text: [stop]; }
      }
    }
  }

  /* Send stream — PTT (press-and-hold) */
  stream audio-in {
    type:      audio;
    direction: send;
    transport: mesh-socket;
    endpoint:  /stream/audio/publish;
    codec:     opus;
    requires:  microphone;

    indicator {
      type:  level;
      label: "Microphone level";
    }

    controls {
      action transmit {
        label: "Transmit";
        style: primary;
        hold:  true;            /* press-and-hold, not toggle */
        icon { file: media(mic.svg); emoji: 🎙️; text: [tx]; }
      }
    }
  }
}

group "Screen Share" {
  tip: "Share your screen over the mesh at low framerate.";

  stream screen-share {
    type:      screen;
    direction: send;
    transport: websocket;
    endpoint:  /stream/screen;
    codec:     mjpeg;
    quality:   low;
    fps:       2;
    requires:  screen-capture;    /* renderer skips this group if absent */

    controls {
      action share-screen {
        label: "Share Screen";
        style: primary;
        icon { file: media(screen.svg); emoji: 🖥️; text: [share]; }
      }
      action stop-share {
        label:   "Stop";
        style:   danger;
        visible: if(state(screen-share.active) == true);
        icon { file: media(stop.svg); emoji: ⏹️; text: [stop]; }
      }
    }
  }

  stream screen-view {
    type:      screen;
    direction: receive;
    transport: websocket;
    endpoint:  /stream/screen/watch;
    codec:     mjpeg;
    requires:  screen-capture;

    display {
      role:  screen-view;
      size:  full;
      label: "Remote screen";
    }

    controls {
      action watch-screen {
        label: "Watch";
        style: primary;
        icon { file: media(eye.svg); emoji: 👁️; text: [watch]; }
      }
    }
  }
}
```

### 4.6 Optimistic Updates

`optimistic` is a special matcher that fires **before** the request is sent. If the request fails, the renderer automatically rolls back any mutations made in the `optimistic` block — unless an explicit rollback handler is defined.

```
action send {
  ...
  result {

    /* Fires immediately — item appears in list before server confirms */
    optimistic {
      type:   mutation;
      target: messages-list;
      op:     append;
      item {
        nickname: state(my_nickname);
        message:  field(body);
        sent_at:  now();
        own:      true;
        pending:  true;         /* renderer marks item as pending */
      }
    }

    /* Server confirmed — replace pending item with real one */
    200 {
      type:   mutation;
      target: messages-list;
      op:     update;
      where:  pending == true;
      set {
        pending: false;
        id:      response(id);
      }
      then: clear(field(body));
    }

    /* Server rejected — roll back pending item and show reason */
    4xx {
      type:   mutation;
      target: messages-list;
      op:     remove;
      where:  pending == true;
      then {
        type:    toast;
        message: response(error);
        level:   warning;
      }
    }

    /* Server error — roll back and suggest retry */
    5xx {
      type:   mutation;
      target: messages-list;
      op:     remove;
      where:  pending == true;
      then {
        type:    toast;
        message: "Failed to send. Message discarded.";
        level:   error;
      }
    }
  }
}
```

---

## 5. WASM ↔ UI Communication

The `.ui` actions call the module's internal HTTP API, which the wapp runtime exposes on localhost. This is the same HTTP API used by `wasm_library_server.dart` — the UI renderer is just another HTTP client.

```
┌─────────────────────────────────────────────────────────┐
│  Renderer (web / Flutter / CLI / LVGL)                  │
│                                                         │
│   .ui file parsed → screen rendered                     │
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
│   ├── home.ui
│   ├── chat.ui
│   ├── live.ui
│   └── settings.ui
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

### screens/home.ui

```
app "Geogram Chat" {
  version:  0.8;
  base-url: /api;
  tip:      "Offline-first mesh communication. Works without internet.";

  icons {
    set file  { for: web, lvgl, email; }
    set emoji { for: web, cli, email, lvgl; }
    set text  { for: cli, email; }
  }

  include "screens/chat.ui";
  include "screens/live.ui";
  include "screens/settings.ui";

  screen "Home" {
    tip: "Compose and send a message over the available transport.";

    image {
      source: media(home-banner.png);
      alt:    "Mesh network visualisation";
      size:   medium;
      role:   banner;
    }

    group "Identity" {
      tip: "Who you are on the mesh. Shared with peers on transmit.";

      field nickname : string {
        label:   "Nickname";
        default: "";
        tip:     "Your human-readable name. Does not need to be unique.";
        hint:    "e.g. Ritu";
        icon { file: media(person.svg); emoji: 👤; text: [user]; }
      }

      field callsign : string {
        label:    "Callsign";
        default:  "";
        tip:      "Your amateur radio callsign. Used in APRS frames.";
        hint:     "e.g. CT1ABC";
        validate: regex("[A-Z0-9]{3,8}");
      }

      field private : bool {
        label:   "Private mode";
        default: false;
        tip:     "Omits your identity from unencrypted broadcast frames.";
        icon { file: media(lock.svg); emoji: 🔒; text: [lock]; }
      }

      field avatar : image {
        label:    "Avatar";
        tip:      "Profile image shared with peers over NOSTR.";
        accept:   jpg, png, webp;
        max-size: 64kb;
        role:     avatar;
        fallback: initials(field(nickname));
      }
    }

    group "Compose" {
      tip: "Your message. Signed and encrypted before sending.";

      field body : text {
        label:    "Message";
        required: true;
        tip:      "Free-form message body. Signed with your NOSTR key.";
        hint:     "Keep under 256 chars for reliable radio transport.";
        bind char-counter {
          source: local(length(field(body)));
          target: label(char-counter);
          format: "{value}/256";
          level:  if(value > 240, warning, normal);
        }
      }

      label char-counter { text: "0/256"; style: meta; }

      field channel : enum {
        label:   "Transport";
        default: mesh;
        tip:     "Which physical layer carries your message.";

        option mesh  { label: "Mesh (BLE / WiFi)"; icon { file: media(mesh.svg);  emoji: 📡; text: [mesh];  } }
        option radio { label: "Radio (APRS)";       icon { file: media(radio.svg); emoji: 📻; text: [radio]; } }
        option nostr { label: "NOSTR Relay";        icon { file: media(nostr.svg); emoji: ⚡; text: [nostr]; } }
      }

      field attachment : file {
        label:    "Attachment";
        tip:      "Optional file sent alongside the message.";
        accept:   jpg, png, pdf;
        max-size: 512kb;
        required: false;
        icon { file: media(attach.svg); emoji: 📎; text: [attach]; }
      }
    }

    action send {
      label:   "Send";
      style:   primary;
      confirm: false;
      tip:     "Sign and transmit on the selected transport.";
      icon { file: media(send.svg); emoji: 📤; text: [send]; }

      request {
        method:   POST;
        endpoint: /send;
        body {
          nickname:   field(nickname);
          private:    field(private);
          message:    field(body);
          channel:    field(channel);
          attachment: field(attachment);
        }
      }

      result {
        optimistic {
          type:   mutation;
          target: messages-list;
          op:     append;
          item {
            nickname: state(my_nickname);
            message:  field(body);
            sent_at:  now();
            own:      true;
            pending:  true;
          }
        }
        200 {
          type:   mutation;
          target: messages-list;
          op:     update;
          where:  pending == true;
          set { pending: false; id: response(id); }
          then: clear(field(body));
        }
        4xx {
          type:   mutation;
          target: messages-list;
          op:     remove;
          where:  pending == true;
          then { type: toast; message: response(error); level: warning; }
        }
        5xx {
          type:   mutation;
          target: messages-list;
          op:     remove;
          where:  pending == true;
          then { type: toast; message: "Send failed. Try again."; level: error; }
        }
      }
    }

    action draft {
      label: "Save Draft";
      style: secondary;
      tip:   "Save locally without transmitting.";
      icon { file: media(save.svg); emoji: 💾; text: [save]; }

      request {
        method:   POST;
        endpoint: /drafts;
        body {
          message: field(body);
          channel: field(channel);
        }
      }

      result {
        200 { type: toast; message: "Draft saved.";        level: success; }
        4xx { type: toast; message: response(error);       level: warning; }
        5xx { type: toast; message: "Could not save draft."; level: error; }
      }
    }

    action clear {
      label:         "Clear";
      style:         danger;
      confirm:       true;
      confirm-label: "Clear everything?";
      tip:           "Discard all fields and reset to defaults.";
      icon { file: media(trash.svg); emoji: 🗑️; text: [del]; }
    }
  }
}
```

### screens/settings.ui (excerpt — key regeneration)

```
screen "Settings" {
  tip: "Configure radio, network, and identity keys.";

  group "Identity Keys" {
    tip: "Your NOSTR keypair. The private key never leaves this device.";

    field pubkey : string {
      label:    "Public Key (npub)";
      readonly: true;
      tip:      "Your NOSTR public key. Safe to share.";
      hint:     "Starts with npub1...";
    }

    action regen {
      label:         "Regenerate Keys";
      style:         danger;
      icon           { file: media(key.svg); emoji: 🔑; text: [key]; }
      tip:           "Creates a new keypair. Old messages become unreadable.";
      confirm:       true;
      confirm-label: "Regenerate? This cannot be undone.";

      request {
        method:   POST;
        endpoint: /keys/regenerate;
      }

      result {
        200 {
          type:  field;
          write: pubkey <- response(npub);
          then:  toast("New keypair generated.");
        }
        409 {
          /* Conflict — key operation already in progress */
          type:    toast;
          message: "Key operation already in progress. Please wait.";
          level:   warning;
        }
        4xx {
          type:    toast;
          message: response(error);
          level:   warning;
        }
        5xx {
          type:    toast;
          message: "Key generation failed. Hardware RNG may be unavailable.";
          level:   error;
        }
      }
    }

    action export {
      label: "Export Keys";
      style: secondary;
      tip:   "Export keypair as QR code or NOSTR bunker URI.";
      icon   { file: media(export.svg); emoji: 📷; text: [qr]; }

      request {
        method:   GET;
        endpoint: /keys/export;
      }

      result {
        200 {
          type:    inline;
          title:   "Scan to import on another device";
          display: qr(response(bunker_uri)) {
            size:     large;
            alt:      "NOSTR bunker URI QR code";
            fallback: text(response(bunker_uri));
          }
        }
        4xx { type: toast; message: response(error);           level: warning; }
        5xx { type: toast; message: "Export failed.";          level: error;   }
      }
    }
  }

  action save {
    label: "Save Settings";
    style: primary;
    tip:   "Write all settings to persistent storage.";
    icon   { file: media(check.svg); emoji: ✅; text: [save]; }

    request {
      method:   POST;
      endpoint: /settings;
      body {
        frequency: field(frequency);
        power:     field(power);
        relay:     field(relay);
        beacon:    field(beacon);
      }
    }

    result {
      200 { type: toast; message: "Settings saved.";         level: success; }
      4xx { type: toast; message: response(error);           level: warning; }
      5xx { type: toast; message: "Could not save settings."; level: error;  }
    }
  }

  action reset {
    label:         "Reset Defaults";
    style:         danger;
    tip:           "Restore all settings to factory defaults.";
    confirm:       true;
    confirm-label: "Reset all settings to defaults?";
    icon { file: media(reset.svg); emoji: 🔄; text: [reset]; }

    request {
      method:   POST;
      endpoint: /settings/reset;
    }

    result {
      200 { type: redirect; screen: settings; }
      4xx { type: toast; message: response(error);    level: warning; }
      5xx { type: toast; message: "Reset failed.";    level: error;   }
    }
  }
}
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

A node receiving kind `32200` can verify the BIP-340 signature, unpack the archive, validate `app.wasm` against the declared hash, and offer to install it — all without any prior knowledge of the app. The `.ui` files inside are rendered immediately; `app.wasm` is loaded into the Wasm3/Wasmer runtime on first launch.

For large packages that exceed NOSTR event size limits, the `content` field carries a magnet-style content-addressed URI and the binary is fetched separately over mesh file transfer.

---

## 10. Implementation Status

| Component | Status | Notes |
|---|---|---|
| WASM HAL + bridge | Done | Wasm3 ESP32, Wasmer desktop/CLI |
| Manifests + events + KV | Done | JSON manifests, event bus, KV backends |
| Library modules | Done | `hal_lib_call`, HTTP API server |
| `.wapp` zip format | Specified | Loader implementation pending |
| GeoUI parser (Dart) | Planned | Recursive descent, ~300 lines |
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
