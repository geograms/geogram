import 'dart:convert';

import '../util/nostr_login_scripts.dart';
import 'web_theme_service.dart';

class ConferenceWebPageConfig {
  final String roomId;
  final String roomName;
  final String hostCallsign;
  final String? hostNickname;
  final int participantCount;
  final int maxParticipants;
  final String transportMode;
  final String? signalingWsUrl;
  final String logoText;
  final String pageMode;
  final String? description;
  final String? statusText;
  final String? sessionStateUrl;
  final String? stationMeetUrl;
  final DateTime? scheduledAt;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final List<Map<String, dynamic>> initialMessages;
  final List<Map<String, dynamic>> archiveFiles;
  final List<Map<String, dynamic>> archiveRecordings;

  const ConferenceWebPageConfig({
    required this.roomId,
    required this.roomName,
    required this.hostCallsign,
    this.hostNickname,
    required this.participantCount,
    required this.maxParticipants,
    required this.transportMode,
    required this.logoText,
    this.pageMode = 'active',
    this.description,
    this.statusText,
    this.sessionStateUrl,
    this.stationMeetUrl,
    this.scheduledAt,
    this.startedAt,
    this.endedAt,
    this.initialMessages = const <Map<String, dynamic>>[],
    this.archiveFiles = const <Map<String, dynamic>>[],
    this.archiveRecordings = const <Map<String, dynamic>>[],
    this.signalingWsUrl,
  });
}

class ConferenceWebPageAssets {
  final String html;
  final String globalStyles;
  final String appStyles;

  const ConferenceWebPageAssets({
    required this.html,
    required this.globalStyles,
    required this.appStyles,
  });
}

class ConferenceWebPageService {
  static final ConferenceWebPageService _instance =
      ConferenceWebPageService._internal();

  factory ConferenceWebPageService() => _instance;

  ConferenceWebPageService._internal();

  Future<ConferenceWebPageAssets> buildJoinPage(
    ConferenceWebPageConfig config,
  ) async {
    final themeService = WebThemeService();
    await themeService.init();

    final template = await themeService.getTemplate('meet') ?? _fallbackTemplate;
    final globalStyles = await themeService.getGlobalStyles() ?? '';
    final appStyles = await themeService.getAppStyles('meet') ?? '';

    final hostDisplay = config.hostNickname != null &&
            config.hostNickname!.isNotEmpty
        ? '${config.hostNickname} (${config.hostCallsign})'
        : config.hostCallsign;

    final dataJson = _jsonForScript({
      'roomId': config.roomId,
      'roomName': config.roomName,
      'hostCallsign': config.hostCallsign,
      'hostDisplay': hostDisplay,
      'participantCount': config.participantCount,
      'maxParticipants': config.maxParticipants,
      'transportMode': config.transportMode,
      'signalingWsUrl': config.signalingWsUrl,
      'pageMode': config.pageMode,
      'sessionStateUrl': config.sessionStateUrl,
      'stationMeetUrl': config.stationMeetUrl,
      'scheduledAt': config.scheduledAt?.toIso8601String(),
      'startedAt': config.startedAt?.toIso8601String(),
      'endedAt': config.endedAt?.toIso8601String(),
      'initialMessages': config.initialMessages,
      'archiveFiles': config.archiveFiles,
      'archiveRecordings': config.archiveRecordings,
    });

    final html = themeService.processTemplate(template, {
      'TITLE': _escape(config.roomName),
      'LOGO_TEXT': _escape(config.logoText),
      'ROOM_SUBTITLE': _escape(
        'Hosted by $hostDisplay · '
        '${config.participantCount} participant${config.participantCount == 1 ? '' : 's'} · '
        'up to ${config.maxParticipants} speakers',
      ),
      'ROOM_DESCRIPTION': config.description != null
          ? _escape(config.description!)
          : '',
      'ROOM_DESCRIPTION_ATTR': config.description == null
          ? ' style="display:none"'
          : '',
      'STATUS_TEXT': config.statusText ?? 'Connect with Nostr to join',
      'DATA_JSON': dataJson,
      'SCRIPTS': '${getNostrLoginScripts()}\n$_meetingScripts',
      'NOSTR_STYLES': getNostrLoginStyles(),
      'NOSTR_HEADER': getNostrLoginHeaderHtml(),
      'GLOBAL_STYLES': globalStyles,
      'APP_STYLES': appStyles,
    });

    return ConferenceWebPageAssets(
      html: html,
      globalStyles: globalStyles,
      appStyles: appStyles,
    );
  }

  String _escape(String value) => htmlEscape.convert(value);

  String _jsonForScript(Map<String, dynamic> data) {
    return jsonEncode(data).replaceAll('</', '<\\/');
  }

  static const String _fallbackTemplate = '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>{{TITLE}}</title>
  <style>{{GLOBAL_STYLES}}</style>
  <style>{{APP_STYLES}}</style>
  {{NOSTR_STYLES}}
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <div class="logo">{{LOGO_TEXT}}</div>
      </div>
      {{NOSTR_HEADER}}
    </div>
  </header>
  <main class="main">
    <div class="meeting-shell">
      <section class="meeting-card">
        <div class="meeting-description"{{ROOM_DESCRIPTION_ATTR}}>{{ROOM_DESCRIPTION}}</div>
        <div class="meeting-subtitle">{{ROOM_SUBTITLE}}</div>
        <div id="status">{{STATUS_TEXT}}</div>
        <div id="meeting-note" class="meeting-note"></div>
        <div id="nostr-gate-msg">Use the identity button above to authenticate before joining the meeting.</div>
        <div id="join-form">
          <label for="nickname" class="nickname-label">Enter your name to join</label>
          <input id="nickname" type="text" placeholder="Your name" maxlength="20" autofocus>
          <div class="button-row">
            <button id="btn-join" type="button">Join</button>
          </div>
        </div>
      </section>
      <section id="call-ui">
        <div class="meeting-layout">
          <div class="stage">
            <div class="stage-panel" id="screen-share-shell">
              <div class="stage-label">
                <div id="screen-share-label">Shared screen</div>
                <button id="btn-screen-fullscreen" type="button">Full screen</button>
              </div>
              <video id="screen-share-video" autoplay playsinline muted></video>
              <div id="screen-share-placeholder">No screen is being shared right now.</div>
            </div>
            <div class="stage-panel">
              <div class="meeting-controls">
                <button id="btn-mute" type="button" style="display:none;">Mute</button>
                <button id="btn-request-speaker" type="button" style="display:none;">Request Mic</button>
                <button id="btn-leave" type="button">Leave</button>
              </div>
            </div>
          </div>
          <aside class="sidebar-panel">
            <div class="sidebar-title">People</div>
            <ul id="participants"></ul>
            <div id="chat-shell">
              <div class="sidebar-title">Chat</div>
              <div id="chat-messages"></div>
              <div class="chat-input-row">
                <input id="chat-input" type="text" placeholder="Type a message..." maxlength="500">
                <button id="btn-send-chat" type="button">Send</button>
              </div>
            </div>
            <div id="archive-assets-shell">
              <div class="sidebar-title">Archive</div>
              <div id="archive-assets"></div>
            </div>
          </aside>
        </div>
      </section>
    </div>
  </main>
</div>
<script>
window.GEOGRAM_MEETING = {{DATA_JSON}};
{{SCRIPTS}}
</script>
</body>
</html>
''';

  static const String _meetingScripts = r'''
'use strict';

const CONFIG = window.GEOGRAM_MEETING || {};
const loc = window.location;

let ws = null;
let helloFallbackTimer = null;
let screenReconnectTimer = null;
let helloSent = false;
let joinRequested = false;
let localStream = null;
let myCallsign = '';
let myRole = 'listener';
let muted = false;
let hostPc = null;
let pendingIce = [];
let activeScreenSharer = null;
const audioElements = {};
const participants = {};
const chatMessages = [];

const statusEl = document.getElementById('status');
const joinForm = document.getElementById('join-form');
const callUi = document.getElementById('call-ui');
const participantsEl = document.getElementById('participants');
const screenShellEl = document.getElementById('screen-share-shell');
const screenLabelEl = document.getElementById('screen-share-label');
const screenVideoEl = document.getElementById('screen-share-video');
const screenPlaceholderEl = document.getElementById('screen-share-placeholder');
const muteBtn = document.getElementById('btn-mute');
const requestSpeakerBtn = document.getElementById('btn-request-speaker');
const joinBtn = document.getElementById('btn-join');
const nostrGateMsg = document.getElementById('nostr-gate-msg');
const nicknameInput = document.getElementById('nickname');
const leaveBtn = document.getElementById('btn-leave');
const chatInput = document.getElementById('chat-input');
const chatMessagesEl = document.getElementById('chat-messages');
const sendChatBtn = document.getElementById('btn-send-chat');
const fullscreenBtn = document.getElementById('btn-screen-fullscreen');
const meetingNoteEl = document.getElementById('meeting-note');
const archiveAssetsShellEl = document.getElementById('archive-assets-shell');
const archiveAssetsEl = document.getElementById('archive-assets');
const PAGE_MODE = CONFIG.pageMode || 'active';
let sessionStateTimer = null;

screenVideoEl.muted = true;

function setStatus(msg) {
  if (statusEl) {
    statusEl.textContent = msg;
  }
}

function makeSessionId() {
  return Date.now().toString(36) + '-' + Math.random().toString(16).slice(2);
}

function isNostrReady() {
  return !!(
    window.GeogramNostr &&
    window.GeogramNostr.connected &&
    window.nostr &&
    typeof window.nostr.signEvent === 'function'
  );
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function friendlyError(code) {
  var messages = {
    'room_not_found': 'This meeting is not active right now.',
    'invalid_request': 'The request could not be processed.',
    'room_full': 'The meeting has reached its maximum number of speakers.',
    'not_authorized': 'You are not authorized to perform this action.',
    'already_joined': 'You are already in this meeting.'
  };
  return messages[code] || code;
}

function getPreferredNickname() {
  return nicknameInput.value.trim() ||
    getStoredNickname() ||
    (window.GeogramNostr && window.GeogramNostr.nickname) ||
    (window.GeogramNostr && window.GeogramNostr.callsign) ||
    '';
}

function getStoredNickname() {
  try {
    return localStorage.getItem('geogram_nostr_nickname') || '';
  } catch (_) {
    return '';
  }
}

function formatDateTimeLabel(value) {
  if (!value) {
    return '';
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  var y = date.getFullYear();
  var m = String(date.getMonth() + 1).padStart(2, '0');
  var d = String(date.getDate()).padStart(2, '0');
  var h = String(date.getHours()).padStart(2, '0');
  var min = String(date.getMinutes()).padStart(2, '0');
  var sec = String(date.getSeconds()).padStart(2, '0');
  return y + '-' + m + '-' + d + ' ' + h + ':' + min + ':' + sec;
}

function enableJoinButtons() {
  joinBtn.disabled = false;
}

function syncJoinGate() {
  const ready = isNostrReady();
  const allowJoin = PAGE_MODE === 'active';
  nostrGateMsg.style.display = allowJoin ? (ready ? 'none' : '') : 'none';
  joinForm.style.display =
    allowJoin && ready && callUi.style.display !== 'block' ? 'flex' : 'none';
  if (!nicknameInput.value) {
    nicknameInput.value = getPreferredNickname();
  }
}

function resolveStationWsUrl() {
  if (CONFIG.signalingWsUrl) {
    return CONFIG.signalingWsUrl;
  }
  const pathSegments = loc.pathname.split('/').filter(Boolean);
  const prefixSegments = pathSegments.length >= 3 &&
      pathSegments[pathSegments.length - 2] === 'meet'
    ? pathSegments.slice(0, -3)
    : [];
  const basePath = prefixSegments.length ? ('/' + prefixSegments.join('/')) : '';
  return (loc.protocol === 'https:' ? 'wss://' : 'ws://') + loc.host + basePath + '/';
}

function resolveLanWsUrl() {
  if (CONFIG.signalingWsUrl) {
    return CONFIG.signalingWsUrl;
  }
  return (loc.protocol === 'https:' ? 'wss://' : 'ws://') + loc.host + '/meet/ws';
}

function signalingWsUrl() {
  return CONFIG.transportMode === 'lan' ? resolveLanWsUrl() : resolveStationWsUrl();
}

function asTimestamp(date) {
  const pad = function(value) { return String(value).padStart(2, '0'); };
  return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) +
    ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes()) + '_' + pad(date.getSeconds());
}

function messageKey(message) {
  const metadata = message.metadata || {};
  return metadata.conference_id || [message.author, message.timestamp, message.content].join('|');
}

function closeSocket() {
  if (!ws) {
    return;
  }
  const activeSocket = ws;
  ws = null;
  activeSocket.onclose = null;
  activeSocket.onerror = null;
  activeSocket.onmessage = null;
  activeSocket.onopen = null;
  try { activeSocket.close(); } catch (_) {}
}

function clearScreenReconnectTimer() {
  if (screenReconnectTimer) {
    clearTimeout(screenReconnectTimer);
    screenReconnectTimer = null;
  }
}

function sortParticipants() {
  return Object.keys(participants).sort(function(a, b) {
    if (a === CONFIG.hostCallsign) return -1;
    if (b === CONFIG.hostCallsign) return 1;
    if (a === myCallsign) return -1;
    if (b === myCallsign) return 1;
    return a.localeCompare(b);
  });
}

function updateParticipants() {
  participantsEl.innerHTML = '';
  sortParticipants().forEach(function(callsign) {
    const info = participants[callsign] || { role: 'listener', connected: false };
    const li = document.createElement('li');
    const name = callsign +
      (callsign === myCallsign ? ' (You)' : '') +
      (callsign === CONFIG.hostCallsign ? ' (Host)' : '');
    const state = info.mediaState || '';
    li.innerHTML =
      '<div><div>' + escapeHtml(name) + '</div><div class="participant-role">' +
      escapeHtml(info.role || 'listener') +
      (info.screenSharing ? ' · screen' : '') +
      '</div></div>' +
      '<div class="participant-role participant-state">' +
      (state ? escapeHtml(state) : '') +
      '</div>';
    participantsEl.appendChild(li);
  });
}

function syncSelfControls() {
  muteBtn.style.display = myRole === 'speaker' && localStream ? '' : 'none';
  const canRequestSpeaker = myRole !== 'speaker' && myCallsign && myCallsign !== CONFIG.hostCallsign;
  requestSpeakerBtn.style.display = canRequestSpeaker ? '' : 'none';
  const canChat = ws && ws.readyState === WebSocket.OPEN && callUi.style.display === 'block';
  chatInput.disabled = !canChat;
  sendChatBtn.disabled = !canChat;
}

function updateScreenState() {
  if (!activeScreenSharer) {
    screenShellEl.classList.remove('active');
    screenPlaceholderEl.textContent = 'No screen is being shared right now.';
    screenPlaceholderEl.style.display = 'flex';
    screenVideoEl.pause();
    screenVideoEl.srcObject = null;
    clearScreenReconnectTimer();
    return;
  }

  screenShellEl.classList.add('active');
  screenLabelEl.textContent = activeScreenSharer + ' is sharing a screen';
  const stream = screenVideoEl.srcObject;
  const hasVideo = !!(
    stream &&
    typeof stream.getVideoTracks === 'function' &&
    stream.getVideoTracks().length > 0
  );
  screenPlaceholderEl.textContent = hasVideo
    ? 'Connecting screen share...'
    : 'Connecting screen share...';
  screenPlaceholderEl.style.display = hasVideo ? 'none' : 'flex';
}

function setActiveScreenSharer(callsign) {
  activeScreenSharer = callsign || null;
  Object.keys(participants).forEach(function(participantCallsign) {
    participants[participantCallsign].screenSharing =
      participantCallsign === activeScreenSharer;
  });
  updateParticipants();
  updateScreenState();
}

function normalizeChatMessage(message, fallbackAuthor) {
  const normalized = Object.assign({}, message || {});
  if (!normalized.author && fallbackAuthor) {
    normalized.author = fallbackAuthor;
  }
  if (!normalized.timestamp) {
    normalized.timestamp = asTimestamp(new Date());
  }
  if (!normalized.metadata) {
    normalized.metadata = {};
  }
  return normalized;
}

function renderChatMessages() {
  chatMessagesEl.innerHTML = '';
  chatMessages.forEach(function(message) {
    const row = document.createElement('div');
    row.className = 'chat-message';
    row.innerHTML = '<div class="chat-meta"><span class="chat-author">' +
      escapeHtml(message.author || '') + '</span><span>' +
      escapeHtml((message.timestamp || '').replace('_', ':').slice(11, 16)) +
      '</span></div><div>' + escapeHtml(message.content || '') + '</div>';
    chatMessagesEl.appendChild(row);
  });
  chatMessagesEl.scrollTop = chatMessagesEl.scrollHeight;
}

function renderArchiveAssets() {
  if (!archiveAssetsShellEl || !archiveAssetsEl) {
    return;
  }
  const recordings = Array.isArray(CONFIG.archiveRecordings) ? CONFIG.archiveRecordings : [];
  const files = Array.isArray(CONFIG.archiveFiles) ? CONFIG.archiveFiles : [];

  // Auto-play first recording in the stage area
  if (recordings.length > 0 && screenShellEl && screenVideoEl) {
    const first = recordings[0];
    screenShellEl.classList.add('active');
    screenShellEl.style.display = 'block';
    screenVideoEl.muted = true;
    screenVideoEl.controls = true;
    screenVideoEl.src = (first.url || '') + '?inline=1';
    screenVideoEl.play().catch(function() {});
    if (screenLabelEl) screenLabelEl.textContent = first.name || 'Recording';
    if (screenPlaceholderEl) screenPlaceholderEl.style.display = 'none';
  }

  const assets = recordings.map(function(item) {
    return Object.assign({ kind: 'Recording' }, item);
  }).concat(files.map(function(item) {
    return Object.assign({ kind: 'File' }, item);
  }));

  if (!assets.length) {
    archiveAssetsShellEl.style.display = 'none';
    archiveAssetsEl.innerHTML = '';
    return;
  }

  archiveAssetsShellEl.style.display = 'block';
  archiveAssetsEl.innerHTML = '';
  assets.forEach(function(asset) {
    const sizeLabel = asset.size ? Math.max(1, Math.round(asset.size / 1024)) + ' KB' : '';
    const row = document.createElement('a');
    row.className = 'archive-asset';
    row.href = asset.url || '#';
    row.innerHTML =
      '<div><div class="archive-asset-title">' + escapeHtml(asset.name || asset.path || asset.kind) +
      '</div><div class="participant-role">' + escapeHtml(asset.kind) +
      (sizeLabel ? ' \u00b7 ' + escapeHtml(sizeLabel) : '') + '</div></div>';
    archiveAssetsEl.appendChild(row);
  });
}

function renderArchiveSummary() {
  if (!participantsEl) {
    return;
  }
  participantsEl.innerHTML = '';
  const items = [];
  if (CONFIG.hostCallsign) items.push(['Host', CONFIG.hostDisplay || CONFIG.hostCallsign]);
  if (CONFIG.scheduledAt) items.push(['Scheduled', formatDateTimeLabel(CONFIG.scheduledAt)]);
  if (CONFIG.startedAt) items.push(['Started', formatDateTimeLabel(CONFIG.startedAt)]);
  if (CONFIG.endedAt) items.push(['Ended', formatDateTimeLabel(CONFIG.endedAt)]);
  items.forEach(function(item) {
    const li = document.createElement('li');
    li.innerHTML =
      '<div><div>' + escapeHtml(item[0]) + '</div></div>' +
      '<div class="participant-role participant-state">' + escapeHtml(item[1]) + '</div>';
    participantsEl.appendChild(li);
  });
}

function stopSessionStatePolling() {
  if (sessionStateTimer) {
    clearInterval(sessionStateTimer);
    sessionStateTimer = null;
  }
}

function startSessionStatePolling() {
  if (!CONFIG.sessionStateUrl || PAGE_MODE !== 'scheduled' || sessionStateTimer) {
    return;
  }
  sessionStateTimer = setInterval(async function() {
    try {
      const response = await fetch(CONFIG.sessionStateUrl, { cache: 'no-store' });
      if (!response.ok) {
        return;
      }
      const data = await response.json();
      if (data.state === 'active' || data.state === 'archive') {
        window.location.reload();
      }
    } catch (_) {}
  }, 15000);
}

function applyStaticMode() {
  if (PAGE_MODE === 'archive') {
    setStatus('Meeting ended. Chat and files remain available read-only.');
    if (meetingNoteEl) {
      meetingNoteEl.textContent =
        CONFIG.endedAt
          ? 'Archive available since ' + formatDateTimeLabel(CONFIG.endedAt) + '.'
          : 'Archive available in read-only mode.';
    }
    nostrGateMsg.style.display = 'none';
    joinForm.style.display = 'none';
    callUi.style.display = 'block';
    if (muteBtn) muteBtn.style.display = 'none';
    if (requestSpeakerBtn) requestSpeakerBtn.style.display = 'none';
    if (leaveBtn) leaveBtn.style.display = 'none';
    if (chatInput) {
      chatInput.disabled = true;
      chatInput.placeholder = 'Read-only archive';
    }
    if (sendChatBtn) sendChatBtn.disabled = true;
    renderArchiveSummary();
    (CONFIG.initialMessages || []).forEach(function(message) {
      appendChatMessage(message, message.author || CONFIG.hostCallsign || '');
    });
    renderArchiveAssets();
    return;
  }

  if (archiveAssetsShellEl) {
    archiveAssetsShellEl.style.display = 'none';
  }
  if (PAGE_MODE === 'scheduled') {
    setStatus(CONFIG.statusText || 'Meeting scheduled');
    if (meetingNoteEl) {
      meetingNoteEl.textContent = CONFIG.scheduledAt
        ? 'Scheduled for ' + formatDateTimeLabel(CONFIG.scheduledAt) + '. This page will update when the host starts the meeting.'
        : 'This meeting is scheduled. Return here when the host starts it.';
    }
    nostrGateMsg.style.display = 'none';
    joinForm.style.display = 'none';
    callUi.style.display = 'block';
    if (screenShellEl) screenShellEl.style.display = 'none';
    if (muteBtn) muteBtn.style.display = 'none';
    if (requestSpeakerBtn) requestSpeakerBtn.style.display = 'none';
    if (leaveBtn) leaveBtn.style.display = 'none';
    if (chatInput) {
      chatInput.disabled = true;
      chatInput.placeholder = 'Chat opens when the meeting starts';
    }
    if (sendChatBtn) sendChatBtn.disabled = true;
    renderArchiveSummary();
    startSessionStatePolling();
  }
}

function appendChatMessage(message, fallbackAuthor) {
  const normalized = normalizeChatMessage(message, fallbackAuthor);
  const key = messageKey(normalized);
  if (chatMessages.some(function(item) { return messageKey(item) === key; })) {
    return;
  }
  chatMessages.push(normalized);
  chatMessages.sort(function(a, b) {
    return (a.timestamp || '').localeCompare(b.timestamp || '');
  });
  renderChatMessages();
}

function playMediaElement(element) {
  if (!element || typeof element.play !== 'function') {
    return;
  }
  const result = element.play();
  if (result && typeof result.catch === 'function') {
    result.catch(function() {});
  }
}

function attachRemoteScreenStream(stream, track) {
  screenVideoEl.srcObject = stream;
  screenVideoEl.onloadedmetadata = function() {
    screenPlaceholderEl.style.display = 'none';
    playMediaElement(screenVideoEl);
    updateScreenState();
  };
  if (track && 'onunmute' in track) {
    track.onunmute = function() {
      screenPlaceholderEl.style.display = 'none';
      playMediaElement(screenVideoEl);
      updateScreenState();
    };
  }
  setTimeout(function() {
    if (screenVideoEl.srcObject === stream) {
      playMediaElement(screenVideoEl);
    }
  }, 0);
  clearScreenReconnectTimer();
  updateScreenState();
}

function stopLocalAudioCapture() {
  if (localStream) {
    localStream.getTracks().forEach(function(track) { track.stop(); });
    localStream = null;
  }
  muted = false;
  muteBtn.textContent = 'Mute';
  muteBtn.classList.remove('muted');
}

function removeLocalAudioSenders() {
  if (!hostPc || typeof hostPc.getSenders !== 'function') {
    return;
  }
  hostPc.getSenders().forEach(function(sender) {
    if (sender.track && sender.track.kind === 'audio') {
      try {
        hostPc.removeTrack(sender);
      } catch (_) {}
    }
  });
}

async function ensureLocalAudioCapture() {
  if (localStream) {
    return true;
  }
  try {
    localStream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      },
      video: false
    });
    if (muted) {
      localStream.getAudioTracks().forEach(function(track) {
        track.enabled = false;
      });
    }
    return true;
  } catch (_) {
    setStatus('Microphone access denied');
    return false;
  }
}

async function applyLocalRole(newRole) {
  myRole = newRole;
  participants[myCallsign] = participants[myCallsign] || {
    role: newRole,
    connected: true,
    mediaState: '',
    screenSharing: false
  };
  participants[myCallsign].role = newRole;
  participants[myCallsign].connected = true;
  participants[myCallsign].mediaState = '';

  if (newRole === 'speaker') {
    const hadStream = !!localStream;
    const audioReady = await ensureLocalAudioCapture();
    if (audioReady && hostPc && !hadStream) {
      localStream.getAudioTracks().forEach(function(track) {
        hostPc.addTrack(track, localStream);
      });
    }
  } else {
    removeLocalAudioSenders();
    stopLocalAudioCapture();
  }

  syncSelfControls();
  updateParticipants();
}

function scheduleLegacyHelloFallback() {
  if (helloFallbackTimer) {
    clearTimeout(helloFallbackTimer);
  }
  helloFallbackTimer = setTimeout(function() {
    if (!helloSent && ws && ws.readyState === WebSocket.OPEN) {
      sendHello(null);
    }
  }, 1200);
}

async function sendHello(challengeNonce) {
  if (!ws || ws.readyState !== WebSocket.OPEN || helloSent) {
    return;
  }
  helloSent = true;
  if (helloFallbackTimer) {
    clearTimeout(helloFallbackTimer);
    helloFallbackTimer = null;
  }

  const tags = [
    ['callsign', myCallsign],
    ['platform', 'Web']
  ];
  const nickname = getPreferredNickname();
  if (nickname) {
    tags.push(['nickname', nickname]);
  }
  if (challengeNonce) {
    tags.push(['challenge', challengeNonce]);
  }

  setStatus(challengeNonce ? 'Authenticating with station...' : 'Authenticating...');
  try {
    const helloEvent = await window.nostr.signEvent({
      kind: 0,
      created_at: Math.floor(Date.now() / 1000),
      tags: tags,
      content: 'Geogram Web'
    });
    ws.send(JSON.stringify({
      type: 'hello',
      protocol: challengeNonce ? 2 : 1,
      event: helloEvent
    }));
  } catch (error) {
    helloSent = false;
    setStatus('Authentication failed: ' + (error && error.message ? error.message : error));
    enableJoinButtons();
    closeSocket();
  }
}

function scheduleScreenReconnect() {
  clearScreenReconnectTimer();
  if (
    !activeScreenSharer ||
    !hostPc ||
    !ws ||
    ws.readyState !== WebSocket.OPEN ||
    !(hostPc.remoteDescription || hostPc.currentRemoteDescription)
  ) {
    return;
  }
  const stream = screenVideoEl.srcObject;
  const hasVideo = !!(
    stream &&
    typeof stream.getVideoTracks === 'function' &&
    stream.getVideoTracks().length > 0
  );
  if (hasVideo) {
    return;
  }
  screenReconnectTimer = setTimeout(function() {
    if (
      activeScreenSharer &&
      hostPc &&
      hostPc.signalingState === 'stable' &&
      ws &&
      ws.readyState === WebSocket.OPEN
    ) {
      renegotiateWithHost();
    }
  }, 1600);
}

document.addEventListener('nostr-connected', function() {
  syncJoinGate();
  if (PAGE_MODE === 'active') {
    setStatus('Ready to join');
  }
  const nick = getPreferredNickname();
  if (nick && !nicknameInput.value) {
    nicknameInput.value = nick;
  }
});

joinBtn.addEventListener('click', function() { joinConference('listener'); });
leaveBtn.addEventListener('click', leaveConference);
muteBtn.addEventListener('click', toggleMute);
requestSpeakerBtn.addEventListener('click', requestSpeaker);
sendChatBtn.addEventListener('click', sendChat);
chatInput.addEventListener('keydown', function(event) {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    sendChat();
  }
});
fullscreenBtn.addEventListener('click', async function() {
  if (!screenVideoEl.srcObject) return;
  if (screenVideoEl.requestFullscreen) {
    await screenVideoEl.requestFullscreen();
  } else if (screenVideoEl.webkitRequestFullscreen) {
    screenVideoEl.webkitRequestFullscreen();
  }
});

async function joinConference(role) {
  if (PAGE_MODE !== 'active') {
    return;
  }
  if (!isNostrReady()) {
    setStatus('Connect with Nostr before joining');
    return;
  }

  myRole = role;
  myCallsign = window.GeogramNostr.callsign || '';
  helloSent = false;
  joinRequested = false;
  enableJoinButtons();
  joinBtn.disabled = true;

  if (!myCallsign) {
    setStatus('Missing Nostr callsign');
    enableJoinButtons();
    return;
  }

  if (role === 'speaker') {
    setStatus('Requesting microphone...');
    const audioReady = await ensureLocalAudioCapture();
    if (!audioReady) {
      enableJoinButtons();
      return;
    }
  }

  setStatus(CONFIG.transportMode === 'lan' ? 'Connecting to host...' : 'Connecting to station...');
  ws = new WebSocket(signalingWsUrl());
  const activeSocket = ws;

  activeSocket.onopen = function() {
    if (CONFIG.transportMode === 'lan') {
      joinRequested = true;
      activeSocket.send(JSON.stringify({
        type: 'conference_hello',
        callsign: myCallsign,
        nickname: getPreferredNickname(),
        role: myRole
      }));
      setStatus('Joining conference...');
      return;
    }
    setStatus('Waiting for station challenge...');
    scheduleLegacyHelloFallback();
  };

  activeSocket.onmessage = async function(event) {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch (_) {
      return;
    }
    if (ws !== activeSocket) {
      return;
    }
    await handleMessage(message);
  };

  activeSocket.onclose = function() {
    if (ws !== activeSocket) {
      return;
    }
    ws = null;
    cleanup('Disconnected');
  };

  activeSocket.onerror = function() {
    setStatus('Connection failed');
    enableJoinButtons();
  };
}

async function handleMessage(message) {
  switch (message.type) {
    case 'challenge':
      await sendHello(message.nonce || null);
      break;

    case 'hello_ack':
      if (message.success === false) {
        cleanup('Authentication failed: ' + (message.message || message.error || 'unknown'));
        return;
      }
      if (joinRequested || !ws || ws.readyState !== WebSocket.OPEN) {
        break;
      }
      joinRequested = true;
      ws.send(JSON.stringify({
        type: 'conference_join',
        room_id: CONFIG.roomId,
        role: myRole
      }));
      setStatus('Joining conference...');
      break;

    case 'conference_welcome':
      joinForm.style.display = 'none';
      callUi.style.display = 'block';
      setStatus('In conference: ' + (message.room_name || CONFIG.roomName));
      Object.keys(participants).forEach(function(key) { delete participants[key]; });
      participants[CONFIG.hostCallsign] = {
        role: 'speaker',
        connected: true,
        mediaState: CONFIG.hostCallsign === myCallsign ? '' : 'Connecting to host...',
        screenSharing: false
      };
      (message.participants || []).forEach(function(callsign) {
        if (!participants[callsign]) {
          participants[callsign] = {
            role: 'listener',
            connected: true,
            mediaState: callsign === CONFIG.hostCallsign ? 'Connecting to host...' : '',
            screenSharing: false
          };
        }
      });
      (message.speakers || []).forEach(function(callsign) {
        participants[callsign] = participants[callsign] || {};
        participants[callsign].role = 'speaker';
      });
      await applyLocalRole(
        Array.isArray(message.speakers) &&
        message.speakers.indexOf(myCallsign) !== -1
          ? 'speaker'
          : 'listener'
      );
      participants[myCallsign] = participants[myCallsign] || {
        role: myRole,
        connected: true,
        mediaState: '',
        screenSharing: false
      };
      participants[myCallsign].connected = true;
      participants[myCallsign].mediaState = '';
      requestSpeakerBtn.disabled = false;
      setActiveScreenSharer(message.active_screen_sharer || null);
      updateParticipants();
      syncSelfControls();
      if (CONFIG.hostCallsign && CONFIG.hostCallsign !== myCallsign) {
        await connectToHost();
      }
      scheduleScreenReconnect();
      break;

    case 'conference_participant_joined':
      if (message.callsign === myCallsign) {
        break;
      }
      participants[message.callsign] = {
        role: message.role || 'listener',
        connected: true,
        mediaState: message.callsign === CONFIG.hostCallsign ? 'Connecting to host...' : '',
        screenSharing: activeScreenSharer === message.callsign
      };
      updateParticipants();
      break;

    case 'conference_participant_left':
      if (message.callsign === myCallsign) {
        break;
      }
      if (activeScreenSharer === message.callsign) {
        screenVideoEl.srcObject = null;
        setActiveScreenSharer(null);
      }
      delete participants[message.callsign];
      if (message.callsign === CONFIG.hostCallsign && hostPc) {
        hostPc.close();
        hostPc = null;
      }
      updateParticipants();
      break;

    case 'conference_role_change':
      participants[message.callsign] = participants[message.callsign] || {};
      participants[message.callsign].role = message.role || 'listener';
      if (message.callsign === myCallsign) {
        requestSpeakerBtn.disabled = false;
        await applyLocalRole(message.role || 'listener');
      }
      updateParticipants();
      break;

    case 'conference_screen_share_state':
      if (message.active) {
        setActiveScreenSharer(message.callsign || CONFIG.hostCallsign);
        scheduleScreenReconnect();
      } else {
        screenVideoEl.srcObject = null;
        screenPlaceholderEl.style.display = 'flex';
        setActiveScreenSharer(null);
      }
      break;

    case 'conference_chat_history':
      (message.messages || []).forEach(function(item) {
        appendChatMessage(item, message.from_callsign || CONFIG.hostCallsign);
      });
      break;

    case 'conference_chat_message':
      if (message.message) {
        appendChatMessage(message.message, message.from_callsign || '');
      }
      break;

    case 'conference_end':
      cleanup('Conference ended by host');
      break;

    case 'conference_error':
      setStatus(friendlyError(message.message || message.error || 'unknown'));
      enableJoinButtons();
      break;

    case 'conference_signal':
      await handleSignal(message);
      break;

    case 'webrtc_offer':
    case 'webrtc_answer':
    case 'webrtc_ice':
    case 'webrtc_bye':
      await handleSignal({
        signal_type: message.type,
        from_callsign: message.from_callsign,
        session_id: message.session_id,
        sdp: message.sdp,
        candidate: message.candidate
      });
      break;
  }
  syncSelfControls();
}

async function handleSignal(message) {
  switch (message.signal_type) {
    case 'webrtc_offer':
      await handleOffer(message);
      break;
    case 'webrtc_answer':
      await handleAnswer(message);
      break;
    case 'webrtc_ice':
      await handleIce(message);
      break;
    case 'webrtc_bye':
      if (hostPc) {
        hostPc.close();
        hostPc = null;
      }
      updateParticipants();
      break;
  }
}

function createPeerConnection() {
  const pc = new RTCPeerConnection({
    iceServers: [
      { urls: 'stun:stun.l.google.com:19302' },
      { urls: 'stun:stun1.l.google.com:19302' }
    ]
  });

  if (localStream) {
    localStream.getTracks().forEach(function(track) {
      pc.addTrack(track, localStream);
    });
  } else {
    pc.addTransceiver('audio', { direction: 'recvonly' });
  }
  pc.addTransceiver('video', { direction: 'recvonly' });

  pc.onicecandidate = function(event) {
    if (event.candidate) {
      sendSignal({
        type: 'webrtc_ice',
        to_callsign: CONFIG.hostCallsign,
        candidate: {
          candidate: event.candidate.candidate,
          sdpMid: event.candidate.sdpMid,
          sdpMLineIndex: event.candidate.sdpMLineIndex
        }
      });
    }
  };

  pc.ontrack = function(event) {
    if (!event.streams || !event.streams[0]) {
      return;
    }
    const stream = event.streams[0];
    if (event.track && event.track.kind === 'video') {
      attachRemoteScreenStream(stream, event.track);
      if (!activeScreenSharer) {
        setActiveScreenSharer(CONFIG.hostCallsign);
      }
      return;
    }

    let audio = audioElements[stream.id];
    if (!audio) {
      audio = new Audio();
      audio.autoplay = true;
      audio.playsInline = true;
      audioElements[stream.id] = audio;
    }
    audio.srcObject = stream;
    playMediaElement(audio);
  };

  pc.onconnectionstatechange = function() {
    participants[CONFIG.hostCallsign] = participants[CONFIG.hostCallsign] || {
      role: 'speaker',
      connected: true,
      screenSharing: false
    };
    participants[CONFIG.hostCallsign].connected = true;
    if (pc.connectionState === 'connected') {
      participants[CONFIG.hostCallsign].mediaState = '';
      setStatus('In conference: ' + (CONFIG.roomName || 'Meeting'));
      scheduleScreenReconnect();
    } else if (pc.connectionState === 'connecting') {
      participants[CONFIG.hostCallsign].mediaState = 'Connecting to host...';
    } else if (pc.connectionState === 'disconnected') {
      participants[CONFIG.hostCallsign].mediaState = 'Reconnecting...';
    } else if (pc.connectionState === 'failed') {
      participants[CONFIG.hostCallsign].mediaState = 'Media failed';
    }
    updateParticipants();
  };

  return pc;
}

async function renegotiateWithHost() {
  if (!hostPc || !ws || ws.readyState !== WebSocket.OPEN) {
    return;
  }
  if (hostPc.signalingState && hostPc.signalingState !== 'stable') {
    return;
  }
  const offer = await hostPc.createOffer({
    offerToReceiveAudio: true,
    offerToReceiveVideo: true
  });
  await hostPc.setLocalDescription(offer);
  sendSignal({
    type: 'webrtc_offer',
    to_callsign: CONFIG.hostCallsign,
    session_id: makeSessionId(),
    role: myRole,
    sdp: { type: offer.type, sdp: offer.sdp }
  });
}

async function connectToHost() {
  hostPc = createPeerConnection();
  await renegotiateWithHost();
}

async function handleOffer(message) {
  if (!hostPc) {
    hostPc = createPeerConnection();
  }
  const pc = hostPc;
  await pc.setRemoteDescription(
    new RTCSessionDescription({
      type: message.sdp.type,
      sdp: message.sdp.sdp
    })
  );
  while (pendingIce.length) {
    await pc.addIceCandidate(new RTCIceCandidate(pendingIce.shift()));
  }
  const answer = await pc.createAnswer({
    offerToReceiveAudio: true,
    offerToReceiveVideo: true
  });
  await pc.setLocalDescription(answer);
  sendSignal({
    type: 'webrtc_answer',
    to_callsign: message.from_callsign || CONFIG.hostCallsign,
    session_id: message.session_id,
    sdp: { type: answer.type, sdp: answer.sdp }
  });
  scheduleScreenReconnect();
}

async function handleAnswer(message) {
  if (!hostPc) {
    return;
  }
  await hostPc.setRemoteDescription(
    new RTCSessionDescription({
      type: message.sdp.type,
      sdp: message.sdp.sdp
    })
  );
  while (pendingIce.length) {
    await hostPc.addIceCandidate(new RTCIceCandidate(pendingIce.shift()));
  }
  scheduleScreenReconnect();
}

async function handleIce(message) {
  const candidate = message.candidate;
  if (!candidate) {
    return;
  }
  if (hostPc && hostPc.remoteDescription) {
    await hostPc.addIceCandidate(new RTCIceCandidate(candidate));
  } else {
    pendingIce.push(candidate);
  }
}

function sendSignal(message) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    return;
  }
  if (CONFIG.transportMode === 'lan') {
    ws.send(JSON.stringify({
      type: message.type,
      room_id: CONFIG.roomId,
      from_callsign: myCallsign,
      to_callsign: message.to_callsign,
      role: message.role,
      session_id: message.session_id,
      sdp: message.sdp,
      candidate: message.candidate
    }));
    return;
  }
  ws.send(JSON.stringify({
    type: 'conference_signal',
    signal_type: message.type,
    room_id: CONFIG.roomId,
    from_callsign: myCallsign,
    to_callsign: message.to_callsign,
    role: message.role,
    session_id: message.session_id,
    sdp: message.sdp,
    candidate: message.candidate
  }));
}

function toggleMute() {
  muted = !muted;
  if (localStream) {
    localStream.getAudioTracks().forEach(function(track) {
      track.enabled = !muted;
    });
  }
  muteBtn.textContent = muted ? 'Unmute' : 'Mute';
  muteBtn.classList.toggle('muted', muted);
}

function requestSpeaker() {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  requestSpeakerBtn.disabled = true;
  ws.send(JSON.stringify({
    type: 'conference_speaker_request',
    room_id: CONFIG.roomId,
    callsign: myCallsign
  }));
  setStatus('Speaker request sent');
}

function sendChat() {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  const content = chatInput.value.trim();
  if (!content) return;
  const message = {
    author: myCallsign,
    timestamp: asTimestamp(new Date()),
    content: content,
    metadata: {
      conference_id: Date.now().toString(36) + '-' + Math.random().toString(16).slice(2),
      room_id: CONFIG.roomId
    },
    reactions: {}
  };
  ws.send(JSON.stringify({
    type: 'conference_chat_message',
    room_id: CONFIG.roomId,
    message: message
  }));
  appendChatMessage(message);
  chatInput.value = '';
}

function leaveConference() {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'conference_leave',
      room_id: CONFIG.roomId
    }));
  }
  cleanup('Left conference');
}

function cleanup(statusMessage) {
  if (helloFallbackTimer) {
    clearTimeout(helloFallbackTimer);
    helloFallbackTimer = null;
  }
  clearScreenReconnectTimer();
  stopSessionStatePolling();
  closeSocket();
  Object.keys(audioElements).forEach(function(key) {
    audioElements[key].srcObject = null;
    delete audioElements[key];
  });
  if (hostPc) {
    hostPc.close();
    hostPc = null;
  }
  pendingIce = [];
  stopLocalAudioCapture();
  screenVideoEl.srcObject = null;
  helloSent = false;
  joinRequested = false;
  myRole = 'listener';
  myCallsign = '';
  Object.keys(participants).forEach(function(key) {
    delete participants[key];
  });
  chatMessages.splice(0, chatMessages.length);
  setActiveScreenSharer(null);
  renderChatMessages();
  updateParticipants();
  syncSelfControls();
  callUi.style.display = 'none';
  syncJoinGate();
  enableJoinButtons();
  requestSpeakerBtn.disabled = false;
  setStatus(statusMessage || (isNostrReady() ? 'Ready to join' : 'Connect with Nostr to join'));
}

applyStaticMode();
syncJoinGate();
syncSelfControls();
''';
}
