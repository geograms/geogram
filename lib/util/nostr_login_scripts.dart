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
      <div class="nostr-profile-field">
        <label>npub</label>
        <div class="nostr-copy-row">
          <span id="nostr-profile-npub" class="nostr-key-text"></span>
          <button class="nostr-copy-btn" id="nostr-copy-npub" title="Copy npub"><svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="5.5" y="5.5" width="8" height="8" rx="1"/><path d="M4 10.5H3a1 1 0 01-1-1v-7a1 1 0 011-1h7a1 1 0 011 1V3"/></svg></button>
          <button class="nostr-qr-btn" id="nostr-qr-npub" title="Show QR code"><svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><rect x="1" y="1" width="6" height="6"/><rect x="9" y="1" width="6" height="6"/><rect x="1" y="9" width="6" height="6"/><rect x="3" y="3" width="2" height="2" fill="var(--background,#1a1a2e)"/><rect x="11" y="3" width="2" height="2" fill="var(--background,#1a1a2e)"/><rect x="3" y="11" width="2" height="2" fill="var(--background,#1a1a2e)"/><rect x="9" y="9" width="2" height="2"/><rect x="13" y="9" width="2" height="2"/><rect x="9" y="13" width="2" height="2"/><rect x="13" y="13" width="2" height="2"/><rect x="11" y="11" width="2" height="2"/></svg></button>
        </div>
      </div>
      <div class="nostr-profile-field" id="nostr-nsec-field" style="display:none;">
        <label>nsec <span class="nostr-nsec-warning">(keep secret!)</span></label>
        <div class="nostr-copy-row">
          <span id="nostr-profile-nsec" class="nostr-key-text"></span>
          <button class="nostr-copy-btn" id="nostr-copy-nsec" title="Copy nsec"><svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="5.5" y="5.5" width="8" height="8" rx="1"/><path d="M4 10.5H3a1 1 0 01-1-1v-7a1 1 0 011-1h7a1 1 0 011 1V3"/></svg></button>
          <button class="nostr-qr-btn" id="nostr-qr-nsec" title="Show QR code"><svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><rect x="1" y="1" width="6" height="6"/><rect x="9" y="1" width="6" height="6"/><rect x="1" y="9" width="6" height="6"/><rect x="3" y="3" width="2" height="2" fill="var(--background,#1a1a2e)"/><rect x="11" y="3" width="2" height="2" fill="var(--background,#1a1a2e)"/><rect x="3" y="11" width="2" height="2" fill="var(--background,#1a1a2e)"/><rect x="9" y="9" width="2" height="2"/><rect x="13" y="9" width="2" height="2"/><rect x="9" y="13" width="2" height="2"/><rect x="13" y="13" width="2" height="2"/><rect x="11" y="11" width="2" height="2"/></svg></button>
        </div>
      </div>
      <div class="nostr-profile-field" id="nostr-nsec-extension-hint" style="display:none;">
        <label>nsec</label>
        <span class="nostr-extension-hint">Managed by your browser extension</span>
      </div>
      <button id="nostr-profile-save" class="nostr-header-btn">Save</button>
    </div>
  </div>
</div>
<div class="nostr-qr-overlay" id="nostr-qr-overlay" style="display:none;" onclick="this.style.display='none'">
  <div class="nostr-qr-modal" onclick="event.stopPropagation()">
    <div id="nostr-qr-svg"></div>
    <div id="nostr-qr-label" class="nostr-qr-label"></div>
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

.nostr-copy-row {
  display: flex;
  align-items: center;
  gap: 4px;
}

.nostr-key-text {
  flex: 1;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 0.78rem;
  font-family: monospace;
  color: var(--foreground, #ccc);
  min-width: 0;
}

.nostr-copy-btn, .nostr-qr-btn {
  background: transparent;
  border: 1px solid var(--accent);
  color: var(--accent);
  cursor: pointer;
  padding: 3px 4px;
  line-height: 0;
  flex-shrink: 0;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}

.nostr-copy-btn:hover, .nostr-qr-btn:hover {
  background: var(--accent);
  color: var(--background, #1a1a2e);
}

.nostr-copied-toast {
  position: fixed;
  top: 10px;
  left: 50%;
  transform: translateX(-50%);
  background: var(--accent, #00ff41);
  color: var(--background, #1a1a2e);
  padding: 4px 16px;
  font-size: 0.8rem;
  font-weight: bold;
  z-index: 2000;
  pointer-events: none;
  animation: nostr-toast-fade 1.2s forwards;
}

@keyframes nostr-toast-fade {
  0% { opacity: 1; }
  70% { opacity: 1; }
  100% { opacity: 0; }
}

.nostr-nsec-warning {
  color: #ff6b6b;
  font-size: 0.65rem;
  text-transform: none;
  letter-spacing: normal;
}

.nostr-extension-hint {
  color: var(--foreground, #ccc);
  font-size: 0.75rem;
  opacity: 0.6;
  font-style: italic;
}

.nostr-qr-overlay {
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  background: rgba(0,0,0,0.85);
  z-index: 3000;
  display: flex;
  align-items: center;
  justify-content: center;
}

.nostr-qr-modal {
  background: #fff;
  padding: 24px;
  border-radius: 8px;
  text-align: center;
  max-width: 340px;
}

.nostr-qr-modal svg {
  width: 256px;
  height: 256px;
}

.nostr-qr-label {
  margin-top: 12px;
  font-size: 0.7rem;
  font-family: monospace;
  color: #333;
  word-break: break-all;
  max-width: 280px;
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

  window.GeogramNostr = {
    pubkey: null, callsign: null, nickname: null, connected: false, relayWs: null,
    disconnect: function() {
      try { localStorage.removeItem('geogram_nostr_pubkey'); } catch(e) {}
      try { localStorage.removeItem('geogram_nostr_privkey'); } catch(e) {}
      try { localStorage.removeItem('geogram_nostr_nickname'); } catch(e) {}
      try { document.cookie = 'geogram_nostr_pubkey=;path=/;expires=Thu, 01 Jan 1970 00:00:00 GMT'; } catch(e) {}
      window.GeogramNostr.pubkey = null;
      window.GeogramNostr.callsign = null;
      window.GeogramNostr.nickname = null;
      window.GeogramNostr.connected = false;
      var btn = document.getElementById('nostr-header-connect');
      var wrapper = document.getElementById('nostr-profile-wrapper');
      if (btn) btn.style.display = '';
      if (wrapper) wrapper.style.display = 'none';
    }
  };

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

  // --- npub/nsec helpers ---

  function hexToNpub(hex) {
    var NT = window.NostrTools;
    if (NT && NT.nip19 && NT.nip19.npubEncode) return NT.nip19.npubEncode(hex);
    return null;
  }

  function hexToNsec(hex) {
    var NT = window.NostrTools;
    if (NT && NT.nip19 && NT.nip19.nsecEncode) {
      try {
        return NT.nip19.nsecEncode(hexToBytes(hex));
      } catch(e) {
        console.error('nsecEncode failed:', e);
        return null;
      }
    }
    return null;
  }

  function truncateKey(str) {
    if (!str || str.length < 20) return str || '';
    return str.substring(0, 12) + '...' + str.substring(str.length - 6);
  }

  function copyToClipboard(text) {
    navigator.clipboard.writeText(text).then(function() {
      var toast = document.createElement('div');
      toast.className = 'nostr-copied-toast';
      toast.textContent = 'Copied!';
      document.body.appendChild(toast);
      setTimeout(function() { toast.remove(); }, 1300);
    }).catch(function(e) {
      console.error('Copy failed:', e);
    });
  }

  function showQrModal(value, label) {
    var overlay = document.getElementById('nostr-qr-overlay');
    var svgContainer = document.getElementById('nostr-qr-svg');
    var labelEl = document.getElementById('nostr-qr-label');
    if (!overlay || !svgContainer) return;
    svgContainer.innerHTML = generateQrSvg(value);
    if (labelEl) labelEl.textContent = value;
    overlay.style.display = '';
  }

  // --- Minimal QR Code generator (SVG output) ---
  // Supports alphanumeric/byte mode, error correction level L
  function generateQrSvg(data) {
    // Use a canvas-based approach with the qrcodegen algorithm
    var modules = generateQrModules(data);
    var size = modules.length;
    var scale = 4;
    var border = 2;
    var total = (size + border * 2) * scale;
    var rects = '';
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (modules[y][x]) {
          rects += '<rect x="' + ((x + border) * scale) + '" y="' + ((y + border) * scale) + '" width="' + scale + '" height="' + scale + '"/>';
        }
      }
    }
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + total + ' ' + total + '"><rect width="' + total + '" height="' + total + '" fill="#fff"/>' + rects + '</svg>';
  }

  // Minimal QR code matrix generator (byte mode, ECC level L)
  function generateQrModules(data) {
    var dataBytes = [];
    for (var i = 0; i < data.length; i++) {
      var c = data.charCodeAt(i);
      if (c < 128) dataBytes.push(c);
      else if (c < 2048) { dataBytes.push(192 | (c >> 6)); dataBytes.push(128 | (c & 63)); }
      else { dataBytes.push(224 | (c >> 12)); dataBytes.push(128 | ((c >> 6) & 63)); dataBytes.push(128 | (c & 63)); }
    }

    // Determine version (1-40) for byte mode, ECC L
    var capacities = [0,17,32,53,78,106,134,154,192,230,271,321,367,425,458,520,586,644,718,792,858,929,1003,1091,1171,1273,1367,1465,1528,1628,1732,1840,1952,2068,2188,2303,2431,2563,2699,2809,2953];
    var version = 1;
    for (var v = 1; v <= 40; v++) {
      if (capacities[v] >= dataBytes.length) { version = v; break; }
    }
    var size = version * 4 + 17;

    // Total data codewords for version at ECC L
    var totalCodewords = [0,19,34,55,80,108,136,156,194,232,274,324,370,428,461,523,589,647,721,795,861,932,1006,1094,1174,1276,1370,1468,1531,1631,1735,1843,1955,2071,2191,2306,2434,2566,2702,2812,2956];
    var ecCodewords  = [0,7,10,15,20,26,18,20,24,30,18,20,24,26,30,22,24,28,30,28,28,28,28,30,30,26,28,30,30,30,30,30,30,30,30,30,30,30,30,30,30];
    var numBlocks    = [0,1,1,1,1,1,2,2,2,2,2,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4];

    var totalDC = totalCodewords[version];
    var ecPerBlock = ecCodewords[version];
    var blocks = numBlocks[version];
    var dataCW = totalDC - ecPerBlock * blocks;

    // Build data bitstream
    var bits = [];
    function pushBits(val, len) { for (var b = len - 1; b >= 0; b--) bits.push((val >> b) & 1); }

    pushBits(4, 4); // byte mode indicator
    var ccBits = version <= 9 ? 8 : 16;
    pushBits(dataBytes.length, ccBits);
    for (var d = 0; d < dataBytes.length; d++) pushBits(dataBytes[d], 8);

    // Terminator + padding
    var maxBits = dataCW * 8;
    var termLen = Math.min(4, maxBits - bits.length);
    pushBits(0, termLen);
    while (bits.length % 8 !== 0) bits.push(0);
    var padBytes = [236, 17];
    var pi = 0;
    while (bits.length < maxBits) { pushBits(padBytes[pi % 2], 8); pi++; }

    // Convert to codeword array
    var codewords = [];
    for (var bi = 0; bi < bits.length; bi += 8) {
      var cw = 0;
      for (var bb = 0; bb < 8; bb++) cw = (cw << 1) | (bits[bi + bb] || 0);
      codewords.push(cw);
    }

    // Reed-Solomon error correction (GF(2^8) with 0x11d)
    var gfExp = new Array(512), gfLog = new Array(256);
    var val = 1;
    for (var gi = 0; gi < 255; gi++) { gfExp[gi] = val; gfLog[val] = gi; val = (val << 1) ^ (val >= 128 ? 0x11d : 0); }
    for (var gi2 = 255; gi2 < 512; gi2++) gfExp[gi2] = gfExp[gi2 - 255];

    function gfMul(a, b) { return (a === 0 || b === 0) ? 0 : gfExp[gfLog[a] + gfLog[b]]; }

    function rsEncode(data, nsym) {
      var gen = [1];
      for (var gi = 0; gi < nsym; gi++) {
        var ng = new Array(gen.length + 1).fill(0);
        for (var gj = 0; gj < gen.length; gj++) {
          ng[gj] ^= gen[gj];
          ng[gj + 1] ^= gfMul(gen[gj], gfExp[gi]);
        }
        gen = ng;
      }
      var rem = new Array(nsym).fill(0);
      for (var ri = 0; ri < data.length; ri++) {
        var coef = rem.shift() ^ data[ri];
        rem.push(0);
        for (var rj = 0; rj < gen.length - 1; rj++) rem[rj] ^= gfMul(coef, gen[rj + 1]);
      }
      return rem;
    }

    // Split into blocks and compute EC
    var cwPerBlock = Math.floor(dataCW / blocks);
    var extraBlocks = dataCW - cwPerBlock * blocks;
    var dataBlocks = [], ecBlocks = [];
    var offset = 0;
    for (var bl = 0; bl < blocks; bl++) {
      var blen = cwPerBlock + (bl >= blocks - extraBlocks ? 1 : 0);
      dataBlocks.push(codewords.slice(offset, offset + blen));
      offset += blen;
      ecBlocks.push(rsEncode(dataBlocks[bl], ecPerBlock));
    }

    // Interleave
    var interleaved = [];
    var maxDataLen = cwPerBlock + (extraBlocks > 0 ? 1 : 0);
    for (var il = 0; il < maxDataLen; il++)
      for (var ib = 0; ib < blocks; ib++)
        if (il < dataBlocks[ib].length) interleaved.push(dataBlocks[ib][il]);
    for (var el = 0; el < ecPerBlock; el++)
      for (var eb = 0; eb < blocks; eb++)
        interleaved.push(ecBlocks[eb][el]);

    // Create module matrix
    var matrix = [];
    for (var my = 0; my < size; my++) { matrix[my] = []; for (var mx = 0; mx < size; mx++) matrix[my][mx] = false; }
    var reserved = [];
    for (var ry = 0; ry < size; ry++) { reserved[ry] = []; for (var rx = 0; rx < size; rx++) reserved[ry][rx] = false; }

    function setModule(y, x, val) { if (y >= 0 && y < size && x >= 0 && x < size) { matrix[y][x] = val; reserved[y][x] = true; } }

    // Finder patterns
    function drawFinder(cy, cx) {
      for (var dy = -4; dy <= 4; dy++) for (var dx = -4; dx <= 4; dx++) {
        var ay = cy + dy, ax = cx + dx;
        if (ay < 0 || ay >= size || ax < 0 || ax >= size) continue;
        var ady = Math.abs(dy), adx = Math.abs(dx);
        var on = ady <= 3 && adx <= 3 && (Math.max(ady, adx) <= 1 || Math.max(ady, adx) === 3);
        setModule(ay, ax, on);
      }
    }
    drawFinder(3, 3); drawFinder(3, size - 4); drawFinder(size - 4, 3);

    // Timing patterns
    for (var t = 8; t < size - 8; t++) {
      setModule(6, t, t % 2 === 0);
      setModule(t, 6, t % 2 === 0);
    }

    // Alignment patterns (version >= 2)
    if (version >= 2) {
      var aligns = [6];
      var last = size - 7;
      var count = Math.floor(version / 7) + 2;
      var step = count === 2 ? last - 6 : Math.ceil((last - 6) / (count - 1));
      if (step % 2 !== 0) step++;
      for (var ap = last; aligns.length < count; ap -= step) aligns.splice(1, 0, ap);
      for (var ai = 0; ai < aligns.length; ai++) for (var aj = 0; aj < aligns.length; aj++) {
        var ay2 = aligns[ai], ax2 = aligns[aj];
        if (reserved[ay2][ax2]) continue;
        for (var ady2 = -2; ady2 <= 2; ady2++) for (var adx2 = -2; adx2 <= 2; adx2++) {
          setModule(ay2 + ady2, ax2 + adx2, Math.max(Math.abs(ady2), Math.abs(adx2)) !== 1);
        }
      }
    }

    // Reserve format info areas
    for (var fi = 0; fi < 8; fi++) {
      reserved[8][fi] = true; reserved[8][size - 1 - fi] = true;
      reserved[fi][8] = true; reserved[size - 1 - fi][8] = true;
    }
    reserved[8][8] = true;
    setModule(size - 8, 8, true); // dark module

    // Version info (version >= 7)
    if (version >= 7) {
      var versionBits = version;
      for (var vb = 0; vb < 12; vb++) versionBits = (versionBits << 1) ^ ((versionBits >> 11) * 0x1F25);
      versionBits = (version << 12) | (versionBits & 0xFFF);
      // BCH: not needed for our typical npub/nsec sizes (version < 7)
    }

    // Place data bits
    var bitIdx = 0;
    var dataBits = [];
    for (var ib2 = 0; ib2 < interleaved.length; ib2++)
      for (var ibb = 7; ibb >= 0; ibb--) dataBits.push((interleaved[ib2] >> ibb) & 1);

    var right = size - 1;
    var upward = true;
    while (right >= 0) {
      if (right === 6) right--;
      for (var row = 0; row < size; row++) {
        var y3 = upward ? (size - 1 - row) : row;
        for (var col = 0; col < 2; col++) {
          var x3 = right - col;
          if (x3 < 0 || reserved[y3][x3]) continue;
          matrix[y3][x3] = bitIdx < dataBits.length ? dataBits[bitIdx] === 1 : false;
          reserved[y3][x3] = true;
          bitIdx++;
        }
      }
      right -= 2;
      upward = !upward;
    }

    // Apply mask (pattern 0: (y+x)%2==0) and format info
    for (var my2 = 0; my2 < size; my2++)
      for (var mx2 = 0; mx2 < size; mx2++)
        if (!isReservedForFormat(my2, mx2, size)) {
          if ((my2 + mx2) % 2 === 0) matrix[my2][mx2] = !matrix[my2][mx2];
        }

    // Write format info (mask 0, ECC L = 01)
    var formatInfo = 0; // ECC L=01, mask 0=000 -> 01000
    var fData = 0x08; // 01 000
    var fBits = fData;
    for (var fb = 0; fb < 10; fb++) fBits = (fBits << 1) ^ ((fBits >> 9) * 0x537);
    fBits = ((fData << 10) | (fBits & 0x3FF)) ^ 0x5412;

    var formatPositions1 = [[8,0],[8,1],[8,2],[8,3],[8,4],[8,5],[8,7],[8,8],[7,8],[5,8],[4,8],[3,8],[2,8],[1,8],[0,8]];
    var formatPositions2 = [[size-1,8],[size-2,8],[size-3,8],[size-4,8],[size-5,8],[size-6,8],[size-7,8],[8,size-8],[8,size-7],[8,size-6],[8,size-5],[8,size-4],[8,size-3],[8,size-2],[8,size-1]];

    for (var fp = 0; fp < 15; fp++) {
      var fbit = (fBits >> (14 - fp)) & 1;
      matrix[formatPositions1[fp][0]][formatPositions1[fp][1]] = fbit === 1;
      matrix[formatPositions2[fp][0]][formatPositions2[fp][1]] = fbit === 1;
    }

    return matrix;
  }

  function isReservedForFormat(y, x, size) {
    // Format info areas: row 8 cols 0-8, col 8 rows 0-8, plus mirror areas
    if (y === 8 && (x <= 8 || x >= size - 8)) return true;
    if (x === 8 && (y <= 8 || y >= size - 7)) return true;
    return false;
  }

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
    try { document.cookie = 'geogram_nostr_pubkey=' + pubkey + ';path=/;SameSite=Lax'; } catch(e) {}
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
    // Clear stale cookie if no localStorage pubkey
    try {
      var savedPk = localStorage.getItem('geogram_nostr_pubkey');
      if (!savedPk) {
        document.cookie = 'geogram_nostr_pubkey=;path=/;expires=Thu, 01 Jan 1970 00:00:00 GMT';
      }
    } catch(e) {}

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

          // Populate npub
          var npubEl = document.getElementById('nostr-profile-npub');
          if (npubEl && window.GeogramNostr.pubkey) {
            var npub = hexToNpub(window.GeogramNostr.pubkey);
            if (npub) {
              npubEl.textContent = truncateKey(npub);
              npubEl.setAttribute('data-full', npub);
            }
          }

          // Populate nsec (only for locally generated keys)
          var nsecField = document.getElementById('nostr-nsec-field');
          var nsecEl = document.getElementById('nostr-profile-nsec');
          var nsecExtHint = document.getElementById('nostr-nsec-extension-hint');
          var privkey = null;
          try { privkey = localStorage.getItem('geogram_nostr_privkey'); } catch(ex) {}
          if (privkey && nsecField && nsecEl) {
            var nsec = hexToNsec(privkey);
            if (nsec) {
              nsecEl.textContent = truncateKey(nsec);
              nsecEl.setAttribute('data-full', nsec);
              nsecField.style.display = '';
              if (nsecExtHint) nsecExtHint.style.display = 'none';
            }
          } else {
            if (nsecField) nsecField.style.display = 'none';
            // Show extension hint if using NIP-07 extension
            if (nsecExtHint) {
              var hasExtension = window.nostr && !window.nostr._geogramPolyfill;
              nsecExtHint.style.display = hasExtension ? '' : 'none';
            }
          }
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

    // Copy npub
    var copyNpubBtn = document.getElementById('nostr-copy-npub');
    if (copyNpubBtn) {
      copyNpubBtn.addEventListener('click', function(e) {
        e.stopPropagation();
        var el = document.getElementById('nostr-profile-npub');
        if (el) copyToClipboard(el.getAttribute('data-full') || el.textContent);
      });
    }

    // Copy nsec
    var copyNsecBtn = document.getElementById('nostr-copy-nsec');
    if (copyNsecBtn) {
      copyNsecBtn.addEventListener('click', function(e) {
        e.stopPropagation();
        var el = document.getElementById('nostr-profile-nsec');
        if (el) copyToClipboard(el.getAttribute('data-full') || el.textContent);
      });
    }

    // QR npub
    var qrNpubBtn = document.getElementById('nostr-qr-npub');
    if (qrNpubBtn) {
      qrNpubBtn.addEventListener('click', function(e) {
        e.stopPropagation();
        var el = document.getElementById('nostr-profile-npub');
        if (el) showQrModal(el.getAttribute('data-full') || el.textContent, 'npub');
      });
    }

    // QR nsec
    var qrNsecBtn = document.getElementById('nostr-qr-nsec');
    if (qrNsecBtn) {
      qrNsecBtn.addEventListener('click', function(e) {
        e.stopPropagation();
        var el = document.getElementById('nostr-profile-nsec');
        if (el) showQrModal(el.getAttribute('data-full') || el.textContent, 'nsec');
      });
    }

    // Poll for NIP-07 extension
    detectNostr(10, function(extensionAvailable) {
      if (extensionAvailable) {
        // Extension found — always auto-connect (prompts authorization if needed)
        connectViaExtension();
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
