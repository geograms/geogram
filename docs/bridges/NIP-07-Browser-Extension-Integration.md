# NIP-07: Using NOSTR Browser Extensions for Authentication & Signing

## How It Works

NIP-07 defines a standardized `window.nostr` JavaScript object that browser extensions inject into every web page. This is the same pattern as MetaMask's `window.ethereum` — the extension acts as a secure key vault, and your web app never touches the private key directly. The user approves each operation (login, signing, encryption) via the extension's popup.

**Popular extensions implementing NIP-07:** nos2x (Chromium, by fiatjaf), nos2x-fox (Firefox), Alby, nostr-keyx (uses OS keychain/YubiKey), and the newer Remote NIP-07 (bridges to Amber on Android via NIP-46).

---

## The `window.nostr` API

### Required Methods (all extensions must implement)

```javascript
// 1. Get the user's public key (authentication/identity)
async window.nostr.getPublicKey(): string
// Returns: 32-byte hex-encoded public key

// 2. Sign a NOSTR event
async window.nostr.signEvent(event: {
  created_at: number,
  kind: number,
  tags: string[][],
  content: string
}): Event
// Returns: the full event with `id`, `pubkey`, and `sig` added
```

### Optional Methods

```javascript
// 3. Get user's preferred relays
async window.nostr.getRelays(): { [url: string]: { read: boolean, write: boolean } }

// 4. NIP-44 encryption (CURRENT — use this for new development)
async window.nostr.nip44.encrypt(pubkey: string, plaintext: string): string
async window.nostr.nip44.decrypt(pubkey: string, ciphertext: string): string

// 5. NIP-04 encryption (DEPRECATED — avoid for new code)
async window.nostr.nip04.encrypt(pubkey: string, plaintext: string): string
async window.nostr.nip04.decrypt(pubkey: string, ciphertext: string): string
```

---

## Step-by-Step Integration for a Chat Application

### 1. Detect Extension Availability

The extension injects `window.nostr` at page load. Chromium/Firefox extension authors should set `"run_at": "document_end"` in their manifest to ensure availability.

```javascript
function hasNostrExtension() {
  return typeof window.nostr !== 'undefined';
}

// Robust detection — some extensions inject slightly after DOMContentLoaded
async function waitForNostr(timeoutMs = 3000) {
  if (window.nostr) return window.nostr;

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('No NOSTR extension found')), timeoutMs);

    // Some extensions dispatch a custom event
    const check = setInterval(() => {
      if (window.nostr) {
        clearInterval(check);
        clearTimeout(timeout);
        resolve(window.nostr);
      }
    }, 100);
  });
}
```

### 2. Authenticate (Get Public Key)

This is the "login" — the extension prompts the user to approve sharing their public key with your site.

```javascript
async function login() {
  try {
    const nostr = await waitForNostr();
    const pubkey = await nostr.getPublicKey();

    // pubkey is a 64-char hex string (32 bytes)
    console.log('Logged in as:', pubkey);

    // Optionally fetch their relay list
    if (nostr.getRelays) {
      const relays = await nostr.getRelays();
      console.log('User relays:', relays);
    }

    return pubkey;
  } catch (err) {
    console.error('Login failed:', err);
    // Show UI: "Please install a NOSTR extension (nos2x, Alby, etc.)"
  }
}
```

### 3. Sign and Publish a Chat Message

For a chat, you'd typically use **kind 42** (NIP-28 public chat channel message) or **kind 14** (NIP-17 private direct messages). Here's a general-purpose signing flow:

```javascript
async function sendChatMessage(content, channelId) {
  const nostr = window.nostr;

  // Build the unsigned event
  const unsignedEvent = {
    created_at: Math.floor(Date.now() / 1000),
    kind: 42,  // NIP-28 channel message
    tags: [
      ['e', channelId, 'wss://relay.example.com', 'root']  // reference the channel
    ],
    content: content
  };

  // The extension adds: id, pubkey, sig
  const signedEvent = await nostr.signEvent(unsignedEvent);

  // Optionally validate before publishing
  // (using nostr-tools)
  // const valid = validateEvent(signedEvent);
  // const verified = verifySignature(signedEvent);

  // Publish to relays via WebSocket
  await publishToRelays(signedEvent);

  return signedEvent;
}
```

### 4. Encrypt/Decrypt Private Messages

For DMs and encrypted chat, use **NIP-44** (preferred) or NIP-04 (legacy):

```javascript
async function sendEncryptedDM(recipientPubkey, plaintext) {
  const nostr = window.nostr;

  // Encrypt using NIP-44 (preferred)
  let ciphertext;
  if (nostr.nip44) {
    ciphertext = await nostr.nip44.encrypt(recipientPubkey, plaintext);
  } else if (nostr.nip04) {
    // Fallback to NIP-04 (deprecated but widely supported)
    ciphertext = await nostr.nip04.encrypt(recipientPubkey, plaintext);
  }

  const event = {
    created_at: Math.floor(Date.now() / 1000),
    kind: 14,    // NIP-17 private DM (or kind 4 for legacy NIP-04 DMs)
    tags: [['p', recipientPubkey]],
    content: ciphertext
  };

  return await nostr.signEvent(event);
}

async function decryptMessage(senderPubkey, ciphertext) {
  const nostr = window.nostr;

  if (nostr.nip44) {
    return await nostr.nip44.decrypt(senderPubkey, ciphertext);
  } else if (nostr.nip04) {
    return await nostr.nip04.decrypt(senderPubkey, ciphertext);
  }
}
```

### 5. Complete Integration Example (Vanilla JS)

```javascript
// Full chat flow using only window.nostr + WebSocket
class NostrChat {
  constructor(relayUrl) {
    this.relayUrl = relayUrl;
    this.ws = null;
    this.pubkey = null;
  }

  async connect() {
    // 1. Authenticate via extension
    if (!window.nostr) {
      throw new Error('Install a NIP-07 extension (nos2x, Alby, etc.)');
    }
    this.pubkey = await window.nostr.getPublicKey();

    // 2. Connect to relay
    this.ws = new WebSocket(this.relayUrl);
    this.ws.onopen = () => this.subscribe();
    this.ws.onmessage = (msg) => this.handleMessage(JSON.parse(msg.data));
  }

  subscribe() {
    // Subscribe to kind 42 messages in a channel
    const sub = JSON.stringify([
      'REQ', 'chat-sub',
      { kinds: [42], limit: 50 }
    ]);
    this.ws.send(sub);
  }

  handleMessage(data) {
    if (data[0] === 'EVENT') {
      const event = data[2];
      // Display in UI: event.pubkey, event.content, event.created_at
      this.onMessage?.(event);
    }
  }

  async send(content, channelEventId) {
    const unsigned = {
      created_at: Math.floor(Date.now() / 1000),
      kind: 42,
      tags: [['e', channelEventId, this.relayUrl, 'root']],
      content
    };

    const signed = await window.nostr.signEvent(unsigned);

    // Publish: ["EVENT", signedEvent]
    this.ws.send(JSON.stringify(['EVENT', signed]));
    return signed;
  }
}

// Usage
const chat = new NostrChat('wss://relay.damus.io');
chat.onMessage = (event) => console.log(`${event.pubkey}: ${event.content}`);
await chat.connect();
await chat.send('Hello world!', '<channel-creation-event-id>');
```

---

## TypeScript Support with nostr-tools

The `@nostr/tools` package (formerly `nostr-tools`) provides type definitions for `window.nostr`:

```typescript
import type { WindowNostr } from '@nostr/tools/nip07'

declare global {
  interface Window {
    nostr?: WindowNostr;
  }
}
```

And higher-level utilities for validation, relay pooling, and encoding:

```typescript
import { SimplePool, validateEvent, verifySignature } from '@nostr/tools';

async function createAndPublish(kind: number, tags: string[][], content: string) {
  const pubkey = await window.nostr!.getPublicKey();

  const event = {
    pubkey,
    created_at: Math.floor(Date.now() / 1000),
    kind,
    tags,
    content
  };

  const signedEvent = await window.nostr!.signEvent(event);

  if (!validateEvent(signedEvent) || !verifySignature(signedEvent)) {
    throw new Error('Invalid event after signing');
  }

  // Get relays from extension or use defaults
  const relayObj = await window.nostr!.getRelays?.() ?? {};
  const relays = Object.keys(relayObj).length > 0
    ? Object.keys(relayObj)
    : ['wss://relay.damus.io', 'wss://nos.lol'];

  const pool = new SimplePool();
  await pool.publish(relays, signedEvent);

  return signedEvent;
}
```

---

## NOSTR Event Structure Reference

Every signed event has this shape (per NIP-01):

```json
{
  "id": "<32-byte hex SHA-256 of the serialized event>",
  "pubkey": "<32-byte hex public key of the creator>",
  "created_at": 1234567890,
  "kind": 1,
  "tags": [["p", "<hex-pubkey>"], ["e", "<event-id>"]],
  "content": "Hello!",
  "sig": "<64-byte hex Schnorr signature>"
}
```

When calling `signEvent()`, you provide `created_at`, `kind`, `tags`, and `content`. The extension computes and adds `id`, `pubkey`, and `sig`.

---

## Relevant Event Kinds for Chat

| Kind | NIP | Purpose |
|------|-----|---------|
| 1 | NIP-01 | Short text note (public post) |
| 4 | NIP-04 | Encrypted DM (deprecated, use kind 14) |
| 14 | NIP-17 | Private direct message (sealed) |
| 40 | NIP-28 | Channel creation |
| 41 | NIP-28 | Channel metadata |
| 42 | NIP-28 | Channel message |
| 9 | NIP-29 | Group chat message (relay-based groups) |

---

## Security Considerations

**The private key never leaves the extension.** This is the core security model — your web page only receives the public key and signed events. The extension handles all cryptographic operations internally (or delegates to OS keychain / YubiKey in the case of nostr-keyx).

**Permission prompts:** Most extensions will popup a confirmation dialog each time `signEvent()`, `encrypt()`, or `decrypt()` is called (at least the first time per domain). Some extensions allow users to whitelist specific sites.

**Limitation — no generic signing:** NIP-07 currently only supports signing NOSTR events, not arbitrary messages. There's an open discussion (issue #373 on the NIPs repo) about adding a generic `window.nostr.sign(message)` method, but it hasn't been adopted. If you need to prove identity for a non-NOSTR backend, the workaround is to create a kind-22242 auth event (NIP-42 style) that your server can verify.

**NIP-44 vs NIP-04:** NIP-04 encryption is deprecated because it leaks metadata and uses weaker cryptography. Always prefer `nip44.encrypt/decrypt` for new implementations, falling back to NIP-04 only for backwards compatibility.

---

## Summary: What Your Web Page Needs

1. **No library required** — `window.nostr` is a pure JS API injected by the extension
2. **Check** `window.nostr` exists at runtime
3. **Call** `getPublicKey()` for authentication
4. **Call** `signEvent()` to sign any NOSTR event (posts, DMs, reactions, etc.)
5. **Call** `nip44.encrypt()/decrypt()` for end-to-end encrypted messaging
6. **Optionally call** `getRelays()` to discover the user's preferred relay infrastructure
7. **Publish** signed events to relays via standard WebSocket (`["EVENT", signedEvent]`)

The extension handles all cryptography. Your web app handles the UI, relay connections, and event construction.
