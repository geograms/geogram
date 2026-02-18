/// Reusable Nostr NIP-07 login component for web pages
/// Provides header button, localStorage persistence, and event-based integration
/// No Flutter dependencies - pure Dart only
///
/// Usage:
/// - Include getNostrLoginScripts() in <script> tags
/// - Include getNostrLoginStyles() in <style> tags
/// - Include getNostrLoginHeaderHtml() inside .header__inner
/// - Listen for 'nostr-connected' CustomEvent for { pubkey, callsign }
/// - Check window.GeogramNostr.connected for current state

/// Returns HTML snippet for the header login button + callsign display
String getNostrLoginHeaderHtml() {
  return '''
<div class="nostr-header-login" id="nostr-header-login" style="display:none;">
  <button class="nostr-header-btn" id="nostr-header-connect">Connect with Nostr</button>
  <span class="nostr-header-callsign" id="nostr-header-callsign" style="display:none;"></span>
</div>
''';
}

/// Returns CSS styles for the header Nostr login component
String getNostrLoginStyles() {
  return '''
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

/// Returns JavaScript for Nostr NIP-07 login with localStorage persistence
/// Sets up window.GeogramNostr global state and dispatches 'nostr-connected' event
String getNostrLoginScripts() {
  return '''
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

  function detectNostr(attempts, callback) {
    if (window.nostr) {
      callback(true);
      return;
    }
    if (attempts > 0) {
      setTimeout(function() { detectNostr(attempts - 1, callback); }, 200);
    } else {
      callback(false);
    }
  }

  function connectNostr() {
    if (!window.nostr) return;
    window.nostr.getPublicKey().then(function(pubkey) {
      var callsign = deriveCallsign(pubkey);
      window.GeogramNostr.pubkey = pubkey;
      window.GeogramNostr.callsign = callsign;
      window.GeogramNostr.connected = true;
      try { localStorage.setItem('geogram_nostr_pubkey', pubkey); } catch(e) {}
      updateHeaderUI(callsign);
      document.dispatchEvent(new CustomEvent('nostr-connected', { detail: { pubkey: pubkey, callsign: callsign } }));
    }).catch(function(e) {
      console.error('Nostr connect error:', e);
    });
  }

  document.addEventListener('DOMContentLoaded', function() {
    var headerLogin = document.getElementById('nostr-header-login');
    var connectBtn = document.getElementById('nostr-header-connect');

    detectNostr(10, function(available) {
      if (!available) {
        // No extension - hide the login component entirely
        return;
      }

      // Extension available - show the header login area
      if (headerLogin) headerLogin.style.display = '';

      // Check localStorage for saved pubkey
      var savedPubkey = null;
      try { savedPubkey = localStorage.getItem('geogram_nostr_pubkey'); } catch(e) {}

      if (savedPubkey) {
        // Auto-connect: derive callsign and update UI immediately
        var callsign = deriveCallsign(savedPubkey);
        window.GeogramNostr.pubkey = savedPubkey;
        window.GeogramNostr.callsign = callsign;
        window.GeogramNostr.connected = true;
        updateHeaderUI(callsign);
        document.dispatchEvent(new CustomEvent('nostr-connected', { detail: { pubkey: savedPubkey, callsign: callsign } }));
      }
    });

    if (connectBtn) {
      connectBtn.addEventListener('click', connectNostr);
    }
  });
})();
''';
}
