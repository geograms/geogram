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
  <span class="nostr-header-callsign" id="nostr-header-callsign" style="display:none;"></span>
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

  window.GeogramNostr = { pubkey: null, callsign: null, connected: false };

  function updateHeaderUI(callsign) {
    var btn = document.getElementById('nostr-header-connect');
    var csEl = document.getElementById('nostr-header-callsign');
    if (btn) btn.style.display = 'none';
    if (csEl) {
      csEl.textContent = callsign;
      csEl.style.display = '';
    }
  }

  function finishConnect(pubkey) {
    var callsign = deriveCallsign(pubkey);
    window.GeogramNostr.pubkey = pubkey;
    window.GeogramNostr.callsign = callsign;
    window.GeogramNostr.connected = true;
    try { localStorage.setItem('geogram_nostr_pubkey', pubkey); } catch(e) {}
    updateHeaderUI(callsign);
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
