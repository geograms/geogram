// Geogram Iwi — Web Wapp Runner
// Loads .wapp (ZIP) files, instantiates WASM with HAL imports,
// renders GeoUI screens as HTML per the renderer behaviour matrix.

const enc = new TextEncoder(), dec = new TextDecoder();
let instance = null, memory = null, startTime = performance.now();
const kvStore = {}, msgQueue = [], outbox = [], history = [];
let historyIdx = -1, manifest = null, screens = [], fieldValues = {}, tickTimer = null;

function readStr(p, l) { return dec.decode(new Uint8Array(memory.buffer, p, l)); }
function writeStr(p, m, s) { const b = enc.encode(s); const n = Math.min(b.length, m); new Uint8Array(memory.buffer, p, n).set(b.subarray(0, n)); return n; }

// ── HAL ──────────────────────────────────────────────────────────────
const hal = {
  time_ms: () => BigInt(Math.floor(performance.now() - startTime)),
  time_epoch: () => BigInt(Math.floor(Date.now() / 1000)),
  log: (lv, p, l) => { const m = readStr(p, l); lv >= 2 ? console.warn('[HAL]', m) : console.log('[HAL]', m); },
  yield: () => {},
  platform: (p, l) => writeStr(p, l, 'web'),
  heap_free: () => 1048576,
  kv_get: (kP, kL, vP, vL) => { const v = kvStore[readStr(kP, kL)]; if (!v) return 0; const n = Math.min(v.length, vL); new Uint8Array(memory.buffer, vP, n).set(v.subarray(0, n)); return n; },
  kv_set: (kP, kL, vP, vL) => { const k = readStr(kP, kL); kvStore[k] = new Uint8Array(memory.buffer.slice(vP, vP + vL)); try { localStorage.setItem('kv:' + k, btoa(String.fromCharCode(...kvStore[k]))); } catch {} return 0; },
  kv_delete: (kP, kL) => { const k = readStr(kP, kL); if (!(k in kvStore)) return -1; delete kvStore[k]; try { localStorage.removeItem('kv:' + k); } catch {} return 0; },
  kv_list: (pP, pL, bP, bL) => { const pfx = readStr(pP, pL); const keys = Object.keys(kvStore).filter(k => k.startsWith(pfx)); let off = 0, cnt = 0; const buf = new Uint8Array(memory.buffer, bP, bL); for (const k of keys) { const kb = enc.encode(k); if (off + kb.length + 1 > bL) break; buf.set(kb, off); off += kb.length; buf[off++] = 0; cnt++; } return cnt; },
  kv_exists: (kP, kL) => readStr(kP, kL) in kvStore ? 1 : 0,
  kv_size: (kP, kL) => { const v = kvStore[readStr(kP, kL)]; return v ? v.length : 0; },
  file_open: () => -1, file_read: () => -1, file_write: () => -1, file_close: () => {},
  http_request: () => -1, http_poll: () => -1, http_read_response: () => 0, http_status: () => -1, http_free: () => {},
  lora_available_hw: () => 0, lora_send: () => -1, lora_available: () => 0, lora_recv: () => 0,
  ble_scan_start: () => -1, ble_scan_stop: () => {}, ble_scan_read: () => 0, ble_advertise: () => -1, ble_advertise_stop: () => {},
  sensor_temperature: () => -2147483648, sensor_humidity: () => -2147483648, sensor_battery: () => -2147483648, sensor_gps_lat: () => -2147483648, sensor_gps_lon: () => -2147483648,
  display_width: () => 0, display_height: () => 0, display_clear: () => {}, display_text: () => {}, display_pixel: () => {}, display_rect: () => {}, display_flush: () => {},
  gpio_mode: () => {}, gpio_read: () => 0, gpio_write: () => {},
  msg_send: (p, l) => { outbox.push(readStr(p, l)); },
  msg_available: () => msgQueue.length > 0 ? msgQueue[0].length : 0,
  msg_recv: (p, l) => { if (!msgQueue.length) return 0; const m = msgQueue.shift(); const n = Math.min(m.length, l); new Uint8Array(memory.buffer, p, n).set(m.subarray(0, n)); return n; },
  lib_call: () => -1,
  event_subscribe: () => 0, event_unsubscribe: () => 0, event_publish: () => 0, event_available: () => 0, event_recv: () => 0,
};
const wasi = {
  random_get: (p, l) => { crypto.getRandomValues(new Uint8Array(memory.buffer, p, l)); return 0; },
  args_get: () => 0, args_sizes_get: () => 0, environ_get: () => 0, environ_sizes_get: () => 0,
  clock_time_get: () => 0, proc_exit: () => {}, fd_close: () => 0, fd_write: () => 0, fd_read: () => 0, fd_seek: () => 0, fd_fdstat_get: () => 0,
};

// ── Minimal ZIP parser ───────────────────────────────────────────────
async function unzip(buffer) {
  const files = {};
  const view = new DataView(buffer);
  let offset = 0;
  while (offset + 30 <= buffer.byteLength) {
    if (view.getUint32(offset, true) !== 0x04034b50) break;
    const method = view.getUint16(offset + 8, true);
    const compSize = view.getUint32(offset + 18, true);
    const nameLen = view.getUint16(offset + 26, true);
    const extraLen = view.getUint16(offset + 28, true);
    const name = dec.decode(new Uint8Array(buffer, offset + 30, nameLen));
    const dataStart = offset + 30 + nameLen + extraLen;
    const raw = new Uint8Array(buffer, dataStart, compSize);
    if (compSize > 0 && !name.endsWith('/')) {
      if (method === 0) {
        files[name] = raw.slice();
      } else if (method === 8) {
        const ds = new DecompressionStream('deflate-raw');
        const w = ds.writable.getWriter(); w.write(raw); w.close();
        const chunks = []; const r = ds.readable.getReader();
        while (true) { const { done, value } = await r.read(); if (done) break; chunks.push(value); }
        const total = chunks.reduce((s, c) => s + c.length, 0);
        const result = new Uint8Array(total);
        let pos = 0; for (const c of chunks) { result.set(c, pos); pos += c.length; }
        files[name] = result;
      }
    }
    offset = dataStart + compSize;
  }
  return files;
}

// ── Load wapp ────────────────────────────────────────────────────────
async function loadWapp(basePath, wappFiles) {
  showLoading(true);
  try {
    // Manifest
    if (wappFiles && wappFiles['manifest.json']) manifest = JSON.parse(dec.decode(wappFiles['manifest.json']));
    else manifest = await (await fetch(basePath + '/manifest.json')).json();

    // Screens
    screens = [];
    const screenPaths = wappFiles
      ? Object.keys(wappFiles).filter(k => k.startsWith('screens/') && k.endsWith('.ui.json'))
      : ['screens/home.ui.json', 'screens/settings.ui.json'];
    for (const name of screenPaths) {
      try {
        let json;
        if (wappFiles && wappFiles[name]) json = JSON.parse(dec.decode(wappFiles[name]));
        else { const r = await fetch(basePath + '/' + name); if (!r.ok) continue; json = await r.json(); }
        for (const b of json) {
          if (b.$ === 'screen') screens.push(b);
          else if (b.$ === 'app') for (const c of (b.children || [])) if (c.$ === 'screen') screens.push(c);
        }
      } catch {}
    }
    const seen = new Set();
    screens = screens.filter(s => { const k = (s.name || '').toLowerCase(); if (seen.has(k)) return false; seen.add(k); return true; });

    // Field defaults
    fieldValues = {};
    for (const sc of screens)
      for (const g of (sc.children || []).filter(c => c.$ === 'group'))
        for (const f of (g.children || []).filter(c => c.$ === 'field'))
          if (f.default !== undefined) fieldValues[f.name] = f.default;

    // Restore KV
    for (let i = 0; i < localStorage.length; i++) {
      const lk = localStorage.key(i);
      if (lk && lk.startsWith('kv:')) try { kvStore[lk.slice(3)] = Uint8Array.from(atob(localStorage.getItem(lk)), c => c.charCodeAt(0)); } catch {}
    }

    // WASM
    let wasmBytes;
    if (wappFiles && wappFiles['app.wasm']) wasmBytes = wappFiles['app.wasm'].buffer;
    else wasmBytes = await (await fetch(basePath + '/app.wasm')).arrayBuffer();
    startTime = performance.now();
    const result = await WebAssembly.instantiate(wasmBytes, { hal, wasi_snapshot_preview1: wasi });
    instance = result.instance;
    memory = instance.exports.memory;
    instance.exports.module_init();
    drainOutbox();

    // UI
    document.getElementById('app-title').textContent = manifest.description || manifest.id || 'Wapp';
    document.getElementById('back-btn').style.display = '';
    buildTabs(); switchTab('terminal');
    const interval = instance.exports.module_tick_interval_ms ? instance.exports.module_tick_interval_ms() : 500;
    tickTimer = setInterval(() => { instance.exports.module_tick(); drainOutbox(); }, interval);
    setStatus('Running', true);
    renderSettings();
    document.getElementById('cmd-input').focus();
  } catch (e) {
    console.error('Load failed:', e);
    setStatus('Error: ' + e.message, false);
  }
  showLoading(false);
}

function unloadWapp() {
  if (tickTimer) { clearInterval(tickTimer); tickTimer = null; }
  if (instance) { try { instance.exports.module_destroy(); } catch {} instance = null; memory = null; }
  document.getElementById('output').innerHTML = '';
  document.getElementById('settings').innerHTML = '';
  document.getElementById('tabs').innerHTML = '';
  document.getElementById('terminal').style.display = 'none';
  document.getElementById('settings').style.display = 'none';
  document.getElementById('launcher').style.display = '';
  document.getElementById('back-btn').style.display = 'none';
  document.getElementById('app-title').textContent = 'Iwi';
  setStatus('Select a wapp', false);
}
document.getElementById('back-btn').onclick = unloadWapp;

function showLoading(show) {
  let el = document.querySelector('.loading');
  if (show && !el) { el = document.createElement('div'); el.className = 'loading'; el.innerHTML = '<span>Loading wapp...</span>'; document.body.appendChild(el); }
  else if (!show && el) el.remove();
}

// ── Output ───────────────────────────────────────────────────────────
function drainOutbox() { while (outbox.length) { try { handleMessage(JSON.parse(outbox.shift())); } catch (e) { appendOutput(String(e), 'err'); } } }
function handleMessage(d) {
  if (d.type === 'ui.append') appendOutput((d.item || {}).text || '', (d.item || {}).level || 'out');
  else if (d.type === 'ui.toast') showToast(d.message || '', d.level || 'info');
  else if (d.type === 'ui.field') fieldValues[d.target] = d.value;
}
function appendOutput(text, level) {
  const el = document.getElementById('output');
  const d = document.createElement('div'); d.className = 'line ' + (level || ''); d.textContent = text;
  el.appendChild(d); el.scrollTop = el.scrollHeight;
}
function showToast(msg, level) {
  const t = document.createElement('div'); t.className = 'toast ' + (level || 'info'); t.textContent = msg;
  document.body.appendChild(t); setTimeout(() => t.remove(), 3000);
}
function setStatus(t, ok) { const el = document.getElementById('status'); el.textContent = t; el.className = 'status' + (ok ? ' ok' : ''); }

// ── Commands ─────────────────────────────────────────────────────────
function sendCommand(cmd) {
  if (!instance) return;
  msgQueue.push(enc.encode(JSON.stringify({ command: cmd })));
  instance.exports.module_handle_event();
  drainOutbox();
}

// ── Tabs ─────────────────────────────────────────────────────────────
function buildTabs() {
  const c = document.getElementById('tabs'); c.innerHTML = '';
  const t = document.createElement('button'); t.className = 'tab active'; t.textContent = 'Terminal';
  t.onclick = () => switchTab('terminal'); c.appendChild(t);
  for (const s of screens) {
    const n = s.name || ''; if (n.toLowerCase() === 'terminal') continue;
    const b = document.createElement('button'); b.className = 'tab'; b.textContent = n;
    b.onclick = () => switchTab(n.toLowerCase()); c.appendChild(b);
  }
}
function switchTab(name) {
  document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.textContent.toLowerCase() === name));
  document.getElementById('terminal').style.display = name === 'terminal' ? 'flex' : 'none';
  document.getElementById('settings').style.display = name === 'settings' ? 'block' : 'none';
  document.getElementById('launcher').style.display = 'none';
  if (name === 'terminal') document.getElementById('cmd-input').focus();
}

// ── Settings renderer ────────────────────────────────────────────────
function renderSettings() {
  const screen = screens.find(s => (s.name || '').toLowerCase() === 'settings');
  if (!screen) return;
  const c = document.getElementById('settings'); c.innerHTML = '';
  if (screen.tip) { const d = document.createElement('div'); d.className = 'screen-tip'; d.textContent = screen.tip; c.appendChild(d); }
  for (const ch of (screen.children || [])) if (ch.$ === 'group') renderGroup(c, ch);
  const actions = (screen.children || []).filter(x => x.$ === 'action');
  if (actions.length) {
    const row = document.createElement('div'); row.className = 'actions';
    for (const a of actions) {
      const b = document.createElement('button'); b.className = a.style === 'primary' ? 'primary' : 'secondary';
      b.textContent = a.label || a.name; if (a.tip) b.title = a.tip;
      b.onclick = () => handleAction(a); row.appendChild(b);
    }
    c.appendChild(row);
  }
}
function renderGroup(c, g) {
  const d = document.createElement('div'); d.className = 'group';
  const h = document.createElement('div'); h.className = 'group-header'; h.textContent = g.name || ''; d.appendChild(h);
  if (g.tip) { const t = document.createElement('div'); t.className = 'group-tip'; t.textContent = g.tip; d.appendChild(t); }
  for (const ch of (g.children || [])) if (ch.$ === 'field') renderField(d, ch);
  c.appendChild(d);
}
function renderField(c, f) {
  const name = f.name || '', type = f.$type || 'string', label = f.label || name;
  const value = fieldValues[name] !== undefined ? fieldValues[name] : (f.default ?? '');
  const row = document.createElement('div'); row.className = 'field'; row.id = 'field-' + name;
  const lbl = document.createElement('label'); lbl.textContent = label; row.appendChild(lbl);
  if (type === 'bool') {
    const cb = document.createElement('input'); cb.type = 'checkbox'; cb.checked = !!value;
    cb.onchange = () => { fieldValues[name] = cb.checked; }; row.appendChild(cb);
  } else if (type === 'enum') {
    const sel = document.createElement('select');
    for (const o of (f.children || []).filter(x => x.$ === 'option')) {
      const opt = document.createElement('option'); opt.value = o.name || ''; opt.textContent = o.label || o.name || '';
      if (opt.value === String(value)) opt.selected = true; sel.appendChild(opt);
    }
    sel.onchange = () => { fieldValues[name] = sel.value; }; row.appendChild(sel);
  } else if ((type === 'float' || type === 'int') && f.min != null && f.max != null) {
    const r = document.createElement('input'); r.type = 'range'; r.min = f.min; r.max = f.max;
    r.step = f.step || (type === 'int' ? 1 : 0.1); r.value = value;
    const v = document.createElement('span'); v.className = 'value';
    v.textContent = type === 'int' ? Math.round(value) : Number(value).toFixed(1);
    r.oninput = () => { const n = type === 'int' ? Math.round(Number(r.value)) : Number(r.value); fieldValues[name] = n; v.textContent = type === 'int' ? n : n.toFixed(1); };
    row.appendChild(r); row.appendChild(v);
  } else {
    const inp = document.createElement('input'); inp.type = 'text'; inp.value = value;
    inp.style.cssText = 'flex:1;background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:6px;padding:4px 8px;font-size:13px;font-family:var(--font)';
    inp.oninput = () => { fieldValues[name] = inp.value; }; row.appendChild(inp);
  }
  if (f.tip) { const t = document.createElement('span'); t.className = 'tip'; t.textContent = f.tip; row.appendChild(t); }
  c.appendChild(row);
}
function handleAction(a) {
  if (a.name === 'save') {
    msgQueue.push(enc.encode(JSON.stringify({ type: 'action', action: 'save', fields: fieldValues })));
    if (instance) { instance.exports.module_handle_event(); drainOutbox(); }
    showToast('Settings saved.', 'success');
  } else if (a.name === 'cancel') switchTab('terminal');
}

// ── Input ────────────────────────────────────────────────────────────
document.getElementById('cmd-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { const v = e.target.value.trim(); if (v) { history.push(v); historyIdx = -1; sendCommand(v); } e.target.value = ''; }
  else if (e.key === 'ArrowUp') { e.preventDefault(); if (!history.length) return; if (historyIdx < 0) historyIdx = history.length; if (historyIdx > 0) e.target.value = history[--historyIdx]; }
  else if (e.key === 'ArrowDown') { e.preventDefault(); if (historyIdx < 0) return; if (historyIdx < history.length - 1) e.target.value = history[++historyIdx]; else { historyIdx = -1; e.target.value = ''; } }
});

// ── Launcher ─────────────────────────────────────────────────────────
async function init() {
  let wapps;
  try { const r = await fetch('/wapps.json'); if (r.ok) wapps = await r.json(); } catch {}
  if (!wapps) wapps = [{ name: 'Terminal', path: '/wapps/terminal' }];

  const list = document.getElementById('app-list');
  const colors = ['#0F3460', '#533483', '#1A5276', '#1E8449', '#B9770E', '#943126'];
  for (let i = 0; i < wapps.length; i++) {
    const w = wapps[i];
    const card = document.createElement('div'); card.className = 'app-card';
    card.onclick = async () => {
      if (w.wapp) { const buf = await (await fetch(w.wapp)).arrayBuffer(); await loadWapp(null, await unzip(buf)); }
      else await loadWapp(w.path, null);
    };
    const icon = document.createElement('div'); icon.className = 'icon';
    icon.style.background = colors[i % colors.length];
    icon.textContent = w.icon || (w.name || '?')[0].toUpperCase();
    card.appendChild(icon);
    const name = document.createElement('div'); name.className = 'name'; name.textContent = w.name || 'Wapp'; card.appendChild(name);
    if (w.description) { const d = document.createElement('div'); d.className = 'desc'; d.textContent = w.description; card.appendChild(d); }
    list.appendChild(card);
  }
  if (wapps.length === 1) { document.getElementById('launcher').style.display = 'none'; if (wapps[0].wapp) { const buf = await (await fetch(wapps[0].wapp)).arrayBuffer(); await loadWapp(null, await unzip(buf)); } else await loadWapp(wapps[0].path, null); }
}
init();
