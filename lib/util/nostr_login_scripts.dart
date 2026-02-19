/// Reusable Nostr login component for web pages
/// Supports NIP-07 browser extensions AND client-side key generation via nostr-tools
/// No Flutter dependencies - pure Dart only
///
/// Usage:
/// - Include getNostrLoginScripts() in <script> tags
/// - Include getNostrLoginStyles() in <head> (includes styles + nostr.bundle.js script tag)
/// - Include getNostrLoginHeaderHtml() inside .header__inner
/// - Listen for 'nostr-connected' CustomEvent for { pubkey, callsign }
/// - Check window.GeogramNostr.connected for current state

/// Returns HTML snippet for the header login button + callsign display
/// Button is always visible (no display:none) — works with or without extension
String getNostrLoginHeaderHtml() {
  return '''
<div class="nostr-header-login" id="nostr-header-login">
  <button class="nostr-header-btn" id="nostr-header-connect">Connect with Nostr</button>
  <div class="nostr-profile-wrapper" id="nostr-profile-wrapper" style="display:none;">
    <span class="nostr-header-callsign" id="nostr-header-callsign"></span>
    <div class="nostr-profile-menu" id="nostr-profile-menu" style="display:none;">
      <div class="nostr-profile-field">
        <label>Callsign</label>
        <span id="nostr-profile-callsign"></span>
      </div>
      <div class="nostr-profile-field">
        <label>Nickname</label>
        <input type="text" id="nostr-profile-nickname" placeholder="Enter nickname..." maxlength="20">
      </div>
      <button id="nostr-profile-save" class="nostr-header-btn">Save</button>
    </div>
  </div>
</div>
''';
}

/// Returns CSS styles + nostr.bundle.js script tag for the header Nostr login component
/// The bundle script goes in <head> so window.NostrTools is available before login scripts run
String getNostrLoginStyles() {
  return '''
<script src="/lib/nostr.bundle.js"></script>
<style>
/* Nostr header login component */
.header__inner {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.nostr-header-login {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-left: 20px;
}

.nostr-header-btn {
  background: transparent;
  color: var(--accent);
  border: 1px solid var(--accent);
  padding: 4px 12px;
  font-family: inherit;
  font-size: 0.8rem;
  cursor: pointer;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  white-space: nowrap;
}

.nostr-header-btn:hover {
  background: var(--accent);
  color: var(--background);
}

.nostr-header-callsign {
  color: var(--accent);
  font-size: 0.85rem;
  font-weight: bold;
  letter-spacing: 0.05em;
  white-space: nowrap;
  cursor: pointer;
}

.nostr-header-callsign:hover {
  text-decoration: underline;
}

.nostr-header-callsign::after {
  content: ' \\25BE';
  font-size: 1em;
  opacity: 0.8;
}

.nostr-profile-wrapper {
  position: relative;
}

.nostr-profile-menu {
  position: absolute;
  top: 100%;
  right: 0;
  margin-top: 6px;
  background: var(--background, #1a1a2e);
  border: 1px solid var(--accent);
  padding: 12px;
  min-width: 220px;
  z-index: 1000;
}

.nostr-profile-field {
  margin-bottom: 10px;
}

.nostr-profile-field label {
  display: block;
  color: var(--accent);
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  margin-bottom: 3px;
  opacity: 0.7;
}

.nostr-profile-field span {
  color: var(--foreground, #ccc);
  font-size: 0.85rem;
  font-weight: bold;
}

.nostr-profile-field input {
  width: 100%;
  box-sizing: border-box;
  background: transparent;
  border: 1px solid var(--accent);
  color: var(--foreground, #ccc);
  padding: 4px 8px;
  font-family: inherit;
  font-size: 0.85rem;
}

.nostr-profile-menu .nostr-header-btn {
  width: 100%;
  margin-top: 4px;
}
</style>
''';
}

/// Returns JavaScript for Nostr login with NIP-07 extension support AND
/// client-side key generation fallback via nostr-tools bundle.
///
/// Flow:
/// 1. Always show login button
/// 2. Poll for NIP-07 extension (10 attempts @ 200ms)
/// 3. If extension found: use it (extension always takes priority)
/// 4. If no extension: use nostr-tools for client-side key generation
/// 5. Install window.nostr polyfill so chat_scripts and blog likes work unchanged
///
/// localStorage keys:
/// - geogram_nostr_pubkey: hex pubkey (used by both extension and generated)
/// - geogram_nostr_privkey: hex private key (only for generated identities)
String getNostrLoginScripts() {
  return r'''
(function() {
  var BECH32_CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

  function deriveCallsign(hexPubkey) {
    var bytes = [];
    for (var i = 0; i < 6 && i < hexPubkey.length; i += 2) {
      bytes.push(parseInt(hexPubkey.substr(i, 2), 16));
    }
    var acc = 0, bits = 0;
    var groups = [];
    for (var j = 0; j < bytes.length; j++) {
      acc = (acc << 8) | bytes[j];
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        groups.push((acc >> bits) & 31);
      }
    }
    var suffix = groups.slice(0, 4).map(function(v) { return BECH32_CHARSET[v]; }).join('').toUpperCase();
    return 'X1' + suffix;
  }

  // Convert Uint8Array to hex string
  function bytesToHex(bytes) {
    return Array.from(bytes).map(function(b) { return b.toString(16).padStart(2, '0'); }).join('');
  }

  // Convert hex string to Uint8Array
  function hexToBytes(hex) {
    var bytes = new Uint8Array(hex.length / 2);
    for (var i = 0; i < hex.length; i += 2) {
      bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
    }
    return bytes;
  }

  // SHA-256 hash of UTF-8 string, returns hex
  async function sha256Hex(str) {
    var encoder = new TextEncoder();
    var data = encoder.encode(str);
    var hash = await crypto.subtle.digest('SHA-256', data);
    return bytesToHex(new Uint8Array(hash));
  }

  window.GeogramNostr = { pubkey: null, callsign: null, nickname: null, connected: false, relayWs: null };

  // --- Relay WebSocket for kind 0 metadata events ---

  function connectRelay() {
    if (window.GeogramNostr.relayWs) return;
    try {
      var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      var ws = new WebSocket(proto + '//' + location.host);
      ws.onopen = function() {
        console.log('Relay WebSocket connected');
        window.GeogramNostr.relayWs = ws;
      };
      ws.onclose = function() {
        window.GeogramNostr.relayWs = null;
        // Reconnect after 5s
        setTimeout(connectRelay, 5000);
      };
      ws.onerror = function() {
        window.GeogramNostr.relayWs = null;
      };
      ws.onmessage = function(evt) {
        try {
          var msg = JSON.parse(evt.data);
          // Handle EVENT responses for kind 0 queries
          if (Array.isArray(msg) && msg[0] === 'EVENT' && msg[2]) {
            var ev = msg[2];
            if (ev.kind === 0) {
              try {
                var meta = JSON.parse(ev.content);
                var displayName = meta.display_name || meta.name || null;
                if (displayName && window.GeogramNostr._onKind0) {
                  window.GeogramNostr._onKind0(ev.pubkey, displayName);
                }
              } catch(e) {}
            }
          }
        } catch(e) {}
      };
    } catch(e) {
      console.error('Relay WebSocket error:', e);
    }
  }

  // Publish a kind 0 metadata event to the relay
  async function publishKind0(nickname) {
    var ws = window.GeogramNostr.relayWs;
    var pubkey = window.GeogramNostr.pubkey;
    var callsign = window.GeogramNostr.callsign;
    if (!ws || ws.readyState !== 1 || !pubkey || !window.nostr) return;

    try {
      var content = JSON.stringify({
        name: callsign,
        display_name: nickname || callsign
      });
      var unsignedEvent = {
        kind: 0,
        created_at: Math.floor(Date.now() / 1000),
        tags: [],
        content: content
      };
      var signedEvent = await window.nostr.signEvent(unsignedEvent);
      ws.send(JSON.stringify(['EVENT', signedEvent]));
    } catch(e) {
      console.error('Failed to publish kind 0:', e);
    }
  }

  // Query kind 0 metadata for a pubkey
  function queryKind0(pubkeyHex) {
    var ws = window.GeogramNostr.relayWs;
    if (!ws || ws.readyState !== 1) return;
    var subId = 'k0_' + pubkeyHex.substring(0, 8);
    ws.send(JSON.stringify(['REQ', subId, { kinds: [0], authors: [pubkeyHex] }]));
  }

  // Expose for chat_scripts to use
  window.GeogramNostr.publishKind0 = publishKind0;
  window.GeogramNostr.queryKind0 = queryKind0;

  function updateHeaderUI() {
    var btn = document.getElementById('nostr-header-connect');
    var wrapper = document.getElementById('nostr-profile-wrapper');
    var csEl = document.getElementById('nostr-header-callsign');
    var callsign = window.GeogramNostr.callsign;
    var nickname = window.GeogramNostr.nickname;
    if (btn) btn.style.display = 'none';
    if (wrapper) wrapper.style.display = '';
    if (csEl) {
      csEl.textContent = nickname ? nickname + ' (' + callsign + ')' : callsign;
    }
  }

  function finishConnect(pubkey) {
    var callsign = deriveCallsign(pubkey);
    window.GeogramNostr.pubkey = pubkey;
    window.GeogramNostr.callsign = callsign;
    window.GeogramNostr.connected = true;
    try { localStorage.setItem('geogram_nostr_pubkey', pubkey); } catch(e) {}
    try {
      var saved = localStorage.getItem('geogram_nostr_nickname');
      if (saved) window.GeogramNostr.nickname = saved;
    } catch(e) {}
    updateHeaderUI();
    // Connect relay WebSocket for kind 0 metadata
    connectRelay();
    document.dispatchEvent(new CustomEvent('nostr-connected', { detail: { pubkey: pubkey, callsign: callsign } }));
  }

  function detectNostr(attempts, callback) {
    if (window.nostr && !window.nostr._geogramPolyfill) {
      callback(true);
      return;
    }
    if (attempts > 0) {
      setTimeout(function() { detectNostr(attempts - 1, callback); }, 200);
    } else {
      callback(false);
    }
  }

  // Install a NIP-07 polyfill using nostr-tools so existing code (chat, blog likes) works unchanged
  function installPolyfill(pubkeyHex, privkeyHex) {
    window.nostr = {
      _geogramPolyfill: true,
      getPublicKey: function() {
        return Promise.resolve(pubkeyHex);
      },
      signEvent: async function(event) {
        var ev = Object.assign({}, event);
        ev.pubkey = pubkeyHex;
        if (!ev.created_at) ev.created_at = Math.floor(Date.now() / 1000);

        // Compute event ID (NIP-01 serialization)
        var serialized = JSON.stringify([
          0,
          ev.pubkey,
          ev.created_at,
          ev.kind || 0,
          Array.isArray(ev.tags) ? ev.tags : [],
          ev.content || ''
        ]);
        ev.id = await sha256Hex(serialized);

        // Sign with nostr-tools
        var NT = window.NostrTools;
        if (NT && NT.finalizeEvent) {
          // finalizeEvent expects a secret key as Uint8Array
          var skBytes = hexToBytes(privkeyHex);
          var finalized = NT.finalizeEvent(ev, skBytes);
          return finalized;
        }

        // Fallback: manual schnorr signing
        if (NT && NT.schnorr && NT.schnorr.sign) {
          var sigResult = await NT.schnorr.sign(hexToBytes(ev.id), hexToBytes(privkeyHex));
          ev.sig = typeof sigResult === 'string' ? sigResult : bytesToHex(sigResult);
          return ev;
        }

        throw new Error('NostrTools not available for signing');
      }
    };
  }

  // Generate a new keypair using nostr-tools
  function generateKeypair() {
    var NT = window.NostrTools;
    if (!NT || !NT.generateSecretKey || !NT.getPublicKey) {
      console.error('NostrTools not loaded — cannot generate keypair');
      return null;
    }
    var skBytes = NT.generateSecretKey();
    var skHex = bytesToHex(skBytes);
    var pkHex = NT.getPublicKey(skBytes);
    return { privkey: skHex, pubkey: pkHex };
  }

  // Connect using extension (NIP-07)
  function connectViaExtension() {
    if (!window.nostr || window.nostr._geogramPolyfill) return;
    window.nostr.getPublicKey().then(function(pubkey) {
      finishConnect(pubkey);
    }).catch(function(e) {
      console.error('Nostr extension connect error:', e);
    });
  }

  // Connect using generated/stored local keys
  function connectViaLocalKeys(privkeyHex) {
    var NT = window.NostrTools;
    if (!NT) {
      console.error('NostrTools not loaded');
      return;
    }
    var pkHex = NT.getPublicKey(hexToBytes(privkeyHex));
    installPolyfill(pkHex, privkeyHex);
    finishConnect(pkHex);
  }

  // Click handler: generate new keypair or use extension
  function handleConnectClick() {
    // If a real extension is available, use it
    if (window.nostr && !window.nostr._geogramPolyfill) {
      connectViaExtension();
      return;
    }

    // Generate new keypair with nostr-tools
    var keys = generateKeypair();
    if (!keys) return;

    // Store private key for session persistence
    try { localStorage.setItem('geogram_nostr_privkey', keys.privkey); } catch(e) {}
    installPolyfill(keys.pubkey, keys.privkey);
    finishConnect(keys.pubkey);
  }

  document.addEventListener('DOMContentLoaded', function() {
    var connectBtn = document.getElementById('nostr-header-connect');

    if (connectBtn) {
      connectBtn.addEventListener('click', handleConnectClick);
    }

    // Profile menu toggle
    var csEl = document.getElementById('nostr-header-callsign');
    var profileMenu = document.getElementById('nostr-profile-menu');
    if (csEl && profileMenu) {
      csEl.addEventListener('click', function(e) {
        e.stopPropagation();
        var isOpen = profileMenu.style.display !== 'none';
        profileMenu.style.display = isOpen ? 'none' : '';
        if (!isOpen) {
          var pcs = document.getElementById('nostr-profile-callsign');
          var pnick = document.getElementById('nostr-profile-nickname');
          if (pcs) pcs.textContent = window.GeogramNostr.callsign || '';
          if (pnick) pnick.value = window.GeogramNostr.nickname || '';
        }
      });
      profileMenu.addEventListener('click', function(e) { e.stopPropagation(); });
      document.addEventListener('click', function() { profileMenu.style.display = 'none'; });
    }

    // Profile save
    var saveBtn = document.getElementById('nostr-profile-save');
    if (saveBtn) {
      saveBtn.addEventListener('click', function() {
        var input = document.getElementById('nostr-profile-nickname');
        var val = input ? input.value.trim() : '';
        window.GeogramNostr.nickname = val || null;
        try {
          if (val) localStorage.setItem('geogram_nostr_nickname', val);
          else localStorage.removeItem('geogram_nostr_nickname');
        } catch(e) {}
        updateHeaderUI();
        profileMenu.style.display = 'none';
        // Publish kind 0 metadata event to relay
        publishKind0(val || null);
      });
    }

    // Poll for NIP-07 extension
    detectNostr(10, function(extensionAvailable) {
      if (extensionAvailable) {
        // Extension found — it takes priority
        var savedPubkey = null;
        try { savedPubkey = localStorage.getItem('geogram_nostr_pubkey'); } catch(e) {}
        if (savedPubkey) {
          // Auto-connect via extension
          connectViaExtension();
        }
        // Otherwise button is visible, click will use extension
      } else {
        // No extension — check for saved local private key
        var savedPrivkey = null;
        try { savedPrivkey = localStorage.getItem('geogram_nostr_privkey'); } catch(e) {}
        if (savedPrivkey) {
          // Auto-connect with stored local keys
          connectViaLocalKeys(savedPrivkey);
        }
        // Otherwise button is visible, click will generate new keypair
      }
    });
  });
})();
''';
}
