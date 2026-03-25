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
  else if (d.type === 'ui.map.viewport') mapSetViewport(d.lat, d.lon, d.zoom);
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
let hasMapScreen = false;
function buildTabs() {
  const c = document.getElementById('tabs'); c.innerHTML = '';
  // Detect if there's a map screen (group with $type=map)
  hasMapScreen = screens.some(s => (s.children || []).some(ch => ch.$ === 'group' && ch.$type === 'map'));
  // First tab: Map if it's a map wapp, otherwise Terminal
  const firstName = hasMapScreen ? 'Map' : 'Terminal';
  const firstId = hasMapScreen ? 'map' : 'terminal';
  const t = document.createElement('button'); t.className = 'tab active'; t.textContent = firstName;
  t.onclick = () => switchTab(firstId); c.appendChild(t);
  // If map wapp, also add terminal tab
  if (hasMapScreen) {
    const tb = document.createElement('button'); tb.className = 'tab'; tb.textContent = 'Terminal';
    tb.onclick = () => switchTab('terminal'); c.appendChild(tb);
  }
  for (const s of screens) {
    const n = s.name || '';
    if (n.toLowerCase() === 'terminal' || n.toLowerCase() === 'map') continue;
    const b = document.createElement('button'); b.className = 'tab'; b.textContent = n;
    b.onclick = () => switchTab(n.toLowerCase()); c.appendChild(b);
  }
}
function switchTab(name) {
  document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.textContent.toLowerCase() === name));
  document.getElementById('terminal').style.display = name === 'terminal' ? 'flex' : 'none';
  document.getElementById('map-container').style.display = name === 'map' ? 'block' : 'none';
  document.getElementById('settings').style.display = name === 'settings' ? 'block' : 'none';
  document.getElementById('launcher').style.display = 'none';
  if (name === 'terminal') document.getElementById('cmd-input').focus();
  if (name === 'map') mapResize();
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

// ── Slippy map renderer ──────────────────────────────────────────────

const TILE_SIZE = 256;
const tileServers = {
  satellite: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
  osm: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  topo: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}',
};
let mapLat = 0, mapLon = 0, mapZoom = 2;
let mapPixelX = 0, mapPixelY = 0; // top-left corner in world pixel coords
let mapDragging = false, mapDragStartX = 0, mapDragStartY = 0, mapDragPxX = 0, mapDragPxY = 0;
const tileCache = new Map(); // "z/x/y" → img element
let mapTileUrl = tileServers.satellite;

function lon2px(lon, z) { return ((lon + 180) / 360) * TILE_SIZE * Math.pow(2, z); }
function lat2px(lat, z) { const r = Math.PI / 180 * lat; return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * TILE_SIZE * Math.pow(2, z); }
function px2lon(px, z) { return px / (TILE_SIZE * Math.pow(2, z)) * 360 - 180; }
function px2lat(py, z) { const n = Math.PI - 2 * Math.PI * py / (TILE_SIZE * Math.pow(2, z)); return 180 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n))); }

function mapSetViewport(lat, lon, zoom) {
  mapLat = lat; mapLon = lon; mapZoom = Math.round(zoom);
  // Find tile URL from screen definition
  const mapGroup = screens.flatMap(s => s.children || []).find(c => c.$ === 'group' && c.$type === 'map');
  if (mapGroup) {
    const url = mapGroup['tile-url'];
    if (url) mapTileUrl = url;
  }
  // Also check fieldValues for tileServer setting
  if (fieldValues.tileServer && tileServers[fieldValues.tileServer]) {
    mapTileUrl = tileServers[fieldValues.tileServer];
  }
  mapCenterOn(lat, lon);
  mapRender();
}

function mapCenterOn(lat, lon) {
  const container = document.getElementById('map-container');
  const w = container.clientWidth || 800, h = container.clientHeight || 600;
  mapPixelX = lon2px(lon, mapZoom) - w / 2;
  mapPixelY = lat2px(lat, mapZoom) - h / 2;
}

function mapRender() {
  const container = document.getElementById('map-container');
  const tilesEl = document.getElementById('map-tiles');
  const w = container.clientWidth || 800, h = container.clientHeight || 600;

  // Calculate visible tile range
  const tileXMin = Math.floor(mapPixelX / TILE_SIZE);
  const tileYMin = Math.floor(mapPixelY / TILE_SIZE);
  const tileXMax = Math.floor((mapPixelX + w) / TILE_SIZE);
  const tileYMax = Math.floor((mapPixelY + h) / TILE_SIZE);
  const maxTile = Math.pow(2, mapZoom) - 1;

  // Track which tiles should be visible
  const visible = new Set();

  for (let ty = tileYMin; ty <= tileYMax; ty++) {
    for (let tx = tileXMin; tx <= tileXMax; tx++) {
      const wrappedX = ((tx % (maxTile + 1)) + (maxTile + 1)) % (maxTile + 1);
      if (ty < 0 || ty > maxTile) continue;
      const key = `${mapZoom}/${wrappedX}/${ty}`;
      visible.add(key);

      let img = tileCache.get(key);
      if (!img) {
        img = document.createElement('img');
        img.src = mapTileUrl.replace('{z}', mapZoom).replace('{x}', wrappedX).replace('{y}', ty);
        img.draggable = false;
        img.onerror = () => { img.style.opacity = '0'; };
        img.onload = () => { img.style.opacity = '1'; };
        img.style.opacity = '0';
        img.style.transition = 'opacity 0.2s';
        tileCache.set(key, img);
        tilesEl.appendChild(img);
      }

      // Position
      img.style.left = (tx * TILE_SIZE - mapPixelX) + 'px';
      img.style.top = (ty * TILE_SIZE - mapPixelY) + 'px';
      img.style.display = '';
    }
  }

  // Hide tiles not in view
  for (const [key, img] of tileCache) {
    if (!visible.has(key)) img.style.display = 'none';
  }

  // Prune cache (keep max 200 tiles)
  if (tileCache.size > 200) {
    const keys = [...tileCache.keys()];
    for (let i = 0; i < keys.length - 150; i++) {
      const img = tileCache.get(keys[i]);
      if (img && img.parentNode) img.parentNode.removeChild(img);
      tileCache.delete(keys[i]);
    }
  }

  // Update coords display
  const cLat = px2lat(mapPixelY + h / 2, mapZoom);
  const cLon = px2lon(mapPixelX + w / 2, mapZoom);
  document.getElementById('map-coords').textContent = `${cLat.toFixed(5)}, ${cLon.toFixed(5)} z${mapZoom}`;
}

function mapResize() { if (document.getElementById('map-container').style.display !== 'none') mapRender(); }
window.addEventListener('resize', mapResize);

// Sync viewport back to WASM module
function mapSyncToModule() {
  const container = document.getElementById('map-container');
  const w = container.clientWidth || 800, h = container.clientHeight || 600;
  mapLat = px2lat(mapPixelY + h / 2, mapZoom);
  mapLon = px2lon(mapPixelX + w / 2, mapZoom);
  if (instance) {
    msgQueue.push(enc.encode(JSON.stringify({ type: 'setViewport', lat: mapLat, lon: mapLon, zoom: mapZoom })));
    instance.exports.module_handle_event();
    drainOutbox();
  }
}

// ── Map mouse/touch events ───────────────────────────────────────────
const mc = document.getElementById('map-container');

mc.addEventListener('mousedown', (e) => {
  mapDragging = true; mapDragStartX = e.clientX; mapDragStartY = e.clientY;
  mapDragPxX = mapPixelX; mapDragPxY = mapPixelY;
});
window.addEventListener('mousemove', (e) => {
  if (!mapDragging) return;
  mapPixelX = mapDragPxX - (e.clientX - mapDragStartX);
  mapPixelY = mapDragPxY - (e.clientY - mapDragStartY);
  mapRender();
});
window.addEventListener('mouseup', () => {
  if (mapDragging) { mapDragging = false; mapSyncToModule(); }
});
mc.addEventListener('wheel', (e) => {
  e.preventDefault();
  const container = document.getElementById('map-container');
  const rect = container.getBoundingClientRect();
  // Zoom towards cursor position
  const mx = e.clientX - rect.left, my = e.clientY - rect.top;
  const worldX = mapPixelX + mx, worldY = mapPixelY + my;
  const oldZoom = mapZoom;
  if (e.deltaY < 0 && mapZoom < 18) mapZoom++;
  else if (e.deltaY > 0 && mapZoom > 2) mapZoom--;
  if (mapZoom !== oldZoom) {
    const scale = Math.pow(2, mapZoom - oldZoom);
    mapPixelX = worldX * scale - mx;
    mapPixelY = worldY * scale - my;
    // Clear old zoom tiles
    for (const [key, img] of tileCache) {
      if (!key.startsWith(mapZoom + '/')) { if (img.parentNode) img.parentNode.removeChild(img); tileCache.delete(key); }
    }
    mapRender();
    mapSyncToModule();
  }
}, { passive: false });

// Touch support
let touchDist = 0;
mc.addEventListener('touchstart', (e) => {
  if (e.touches.length === 1) {
    mapDragging = true; mapDragStartX = e.touches[0].clientX; mapDragStartY = e.touches[0].clientY;
    mapDragPxX = mapPixelX; mapDragPxY = mapPixelY;
  } else if (e.touches.length === 2) {
    mapDragging = false;
    touchDist = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY);
  }
}, { passive: true });
mc.addEventListener('touchmove', (e) => {
  e.preventDefault();
  if (e.touches.length === 1 && mapDragging) {
    mapPixelX = mapDragPxX - (e.touches[0].clientX - mapDragStartX);
    mapPixelY = mapDragPxY - (e.touches[0].clientY - mapDragStartY);
    mapRender();
  } else if (e.touches.length === 2) {
    const d = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY);
    if (d > touchDist * 1.3 && mapZoom < 18) { mapZoom++; touchDist = d; mapCenterOn(mapLat, mapLon); for (const [k, i] of tileCache) { if (i.parentNode) i.parentNode.removeChild(i); } tileCache.clear(); mapRender(); mapSyncToModule(); }
    else if (d < touchDist * 0.7 && mapZoom > 2) { mapZoom--; touchDist = d; mapCenterOn(mapLat, mapLon); for (const [k, i] of tileCache) { if (i.parentNode) i.parentNode.removeChild(i); } tileCache.clear(); mapRender(); mapSyncToModule(); }
  }
}, { passive: false });
mc.addEventListener('touchend', () => { if (mapDragging) { mapDragging = false; mapSyncToModule(); } });

// Zoom buttons
document.getElementById('map-zin').onclick = () => { if (mapZoom < 18) { mapZoom++; mapCenterOn(mapLat, mapLon); for (const [k, i] of tileCache) { if (i.parentNode) i.parentNode.removeChild(i); } tileCache.clear(); mapRender(); mapSyncToModule(); } };
document.getElementById('map-zout').onclick = () => { if (mapZoom > 2) { mapZoom--; mapCenterOn(mapLat, mapLon); for (const [k, i] of tileCache) { if (i.parentNode) i.parentNode.removeChild(i); } tileCache.clear(); mapRender(); mapSyncToModule(); } };

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
