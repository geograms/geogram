/// Shared chat page JavaScript for both Flutter and CLI modes
/// No Flutter dependencies - pure Dart only

/// Get JavaScript for chat page interactivity
/// Used by:
/// - WebThemeService (Flutter apps, device chat pages)
/// - PureStationServer (CLI mode, station chat page)
String getChatPageScripts() {
  return '''
    (function() {
      const data = window.GEOGRAM_DATA || {};
      let currentRoom = data.currentRoom || 'main';
      let lastTimestamp = null;
      let pollInterval = null;
      let loadingOlder = false;
      let hasMore = true;
      const PAGE_SIZE = 20;
      const isTouchDevice = ('ontouchstart' in window) || (navigator.maxTouchPoints > 0);

      // Nickname cache: pubkey_hex -> display_name
      const knownNicknames = {};
      // Callsign-based nickname cache: CALLSIGN_UPPER -> nickname
      const callsignNicknames = {};
      // Track pubkeys we've already requested kind 0 for
      const pendingNicknameQueries = new Set();

      function cacheKey(roomId) {
        return 'geogram_chat_' + roomId;
      }

      function cacheGet(roomId) {
        try {
          const raw = sessionStorage.getItem(cacheKey(roomId));
          return raw ? JSON.parse(raw) : null;
        } catch (e) { return null; }
      }

      function cacheSet(roomId, messages) {
        try {
          sessionStorage.setItem(cacheKey(roomId), JSON.stringify(messages));
        } catch (e) {}
      }

      function cacheAppend(roomId, newMessages) {
        const cached = cacheGet(roomId) || [];
        const existing = new Set(cached.map(m => m.timestamp));
        newMessages.forEach(m => {
          if (!existing.has(m.timestamp)) cached.push(m);
        });
        cacheSet(roomId, cached);
      }

      function cachePrepend(roomId, olderMessages) {
        const cached = cacheGet(roomId) || [];
        const existing = new Set(cached.map(m => m.timestamp));
        const toAdd = olderMessages.filter(m => !existing.has(m.timestamp));
        if (toAdd.length > 0) cacheSet(roomId, toAdd.concat(cached));
      }

      function initChannels() {
        document.querySelectorAll('.channel-item').forEach(item => {
          item.addEventListener('click', function() {
            const roomId = this.dataset.roomId;
            switchRoom(roomId);
          });
        });
      }

      function switchRoom(roomId, skipHistory) {
        if (roomId === currentRoom && lastTimestamp !== null) return;
        currentRoom = roomId;
        lastTimestamp = null;
        hasMore = true;
        loadingOlder = false;

        if (!skipHistory) {
          history.pushState(null, '', '#' + roomId);
        }

        document.querySelectorAll('.channel-item').forEach(item => {
          item.classList.toggle('active', item.dataset.roomId === roomId);
        });

        document.getElementById('current-room').textContent = roomId;
        document.getElementById('messages').innerHTML = '<div class="status-message">Loading messages...</div>';
        loadMessages();
      }

      function parseMessages(result) {
        let messages = [];
        let resultHasMore = true;
        if (Array.isArray(result)) {
          messages = result;
        } else if (result && Array.isArray(result.messages)) {
          messages = result.messages;
          if (result.has_more === false) resultHasMore = false;
        }
        return { messages, hasMore: resultHasMore };
      }

      async function loadMessages() {
        try {
          const cached = cacheGet(currentRoom);
          if (cached && cached.length > 0) {
            renderMessages(cached);
            scrollToBottom(true);
            startPolling();
            return;
          }

          const url = data.apiBasePath + '/' + encodeURIComponent(currentRoom) + '/messages?limit=' + PAGE_SIZE;
          const response = await fetch(url);
          if (!response.ok) {
            document.getElementById('messages').innerHTML = '<div class="empty-state">Failed to load messages</div>';
            return;
          }

          const result = await response.json();
          const parsed = parseMessages(result);
          hasMore = parsed.hasMore;

          const container = document.getElementById('messages');
          container.innerHTML = '';

          if (parsed.messages.length === 0) {
            container.innerHTML = '<div class="empty-state">No messages yet</div>';
            return;
          }

          cacheSet(currentRoom, parsed.messages);
          renderMessages(parsed.messages);
          scrollToBottom(true);
        } catch (e) {
          console.error('Error loading messages:', e);
          document.getElementById('messages').innerHTML = '<div class="empty-state">Error loading messages</div>';
        }
      }

      function parseMsgDate(timestamp) {
        const d = new Date(timestamp);
        if (!isNaN(d.getTime())) {
          return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');
        }
        return timestamp.split('T')[0].split(' ')[0];
      }

      function parseMsgTime(timestamp) {
        const d = new Date(timestamp);
        if (!isNaN(d.getTime())) {
          return String(d.getHours()).padStart(2,'0') + ':' + String(d.getMinutes()).padStart(2,'0');
        }
        const timeParts = timestamp.split(' ');
        return timeParts.length > 1 ? timeParts[1].replace('_', ':').substring(0, 5) : '00:00';
      }

      function renderMessages(messages) {
        const container = document.getElementById('messages');
        container.innerHTML = '';

        if (messages.length === 0) {
          container.innerHTML = '<div class="empty-state">No messages yet</div>';
          return;
        }

        let currentDate = null;
        messages.forEach(msg => {
          const msgDate = parseMsgDate(msg.timestamp);
          if (currentDate !== msgDate) {
            currentDate = msgDate;
            const sep = document.createElement('div');
            sep.className = 'date-separator';
            sep.textContent = msgDate;
            container.appendChild(sep);
          }
          appendMessage(msg);
          lastTimestamp = msg.timestamp;
        });
      }

      function resolveAuthorDisplay(callsign, pubkey) {
        if (pubkey && knownNicknames[pubkey]) {
          return knownNicknames[pubkey] + ' (' + callsign + ')';
        }
        const upper = (callsign || '').toUpperCase();
        if (callsignNicknames[upper]) {
          return callsignNicknames[upper] + ' (' + callsign + ')';
        }
        return callsign;
      }

      async function fetchCallsignNicknames() {
        try {
          const resp = await fetch('/.well-known/nostr.json');
          if (!resp.ok) return;
          const json = await resp.json();
          const names = json.names || {};

          // Group entries by hex pubkey
          const byHex = {};
          for (const [name, hex] of Object.entries(names)) {
            if (!byHex[hex]) byHex[hex] = [];
            byHex[hex].push(name);
          }

          // Callsign pattern: letter, digit, then alphanumeric (e.g. x1su86)
          const callsignRe = /^[a-z]\\d[a-z0-9]+\$/;

          for (const entries of Object.values(byHex)) {
            const callsigns = entries.filter(n => callsignRe.test(n));
            const nicknames = entries.filter(n => !callsignRe.test(n));
            if (callsigns.length > 0 && nicknames.length > 0) {
              const nick = nicknames[0];
              for (const cs of callsigns) {
                callsignNicknames[cs.toUpperCase()] = nick;
              }
            }
          }

          // Re-render existing messages with updated author names
          document.querySelectorAll('.message').forEach(function(el) {
            const authorEl = el.querySelector('.message-author');
            if (!authorEl) return;
            const currentText = authorEl.textContent;
            // Skip already-resolved names (contain parentheses)
            if (currentText.includes('(')) return;
            const upper = currentText.toUpperCase();
            if (callsignNicknames[upper]) {
              authorEl.textContent = callsignNicknames[upper] + ' (' + currentText + ')';
            }
          });
        } catch (e) {
          console.error('Error fetching callsign nicknames:', e);
        }
      }

      function requestNickname(pubkey) {
        if (!pubkey || pendingNicknameQueries.has(pubkey) || knownNicknames[pubkey]) return;
        var nostr = window.GeogramNostr || {};
        if (nostr.queryKind0) {
          pendingNicknameQueries.add(pubkey);
          nostr.queryKind0(pubkey);
        }
      }

      function appendMessage(msg) {
        const container = document.getElementById('messages');
        const div = document.createElement('div');
        div.className = 'message';
        div.dataset.timestamp = msg.timestamp;
        div.dataset.author = (msg.callsign || msg.author || msg.senderCallsign || '').toUpperCase();
        div.dataset.content = msg.content || '';

        const time = parseMsgTime(msg.timestamp);
        const callsign = msg.callsign || msg.author || msg.senderCallsign;
        const pubkey = msg.pubkey || msg.senderPubkey || null;
        const authorDisplay = resolveAuthorDisplay(callsign, pubkey);
        const content = msg.content || '';

        if (pubkey) div.dataset.pubkey = pubkey;

        div.innerHTML = '<div class="message-header">' +
                       '<span class="message-author">' + escapeHtml(authorDisplay) + '</span>' +
                       '<span class="message-time">' + time + '</span>' +
                       '</div>' +
                       '<div class="message-content">' + escapeHtml(content) + '</div>';

        container.appendChild(div);

        // Query kind 0 if we don't know this pubkey's nickname yet
        if (pubkey && !knownNicknames[pubkey]) {
          requestNickname(pubkey);
        }
      }

      async function loadOlderMessages() {
        if (loadingOlder || !hasMore) return;
        loadingOlder = true;

        const container = document.getElementById('messages');
        const firstMsg = container.querySelector('.message');
        if (!firstMsg) { loadingOlder = false; return; }

        const oldestTimestamp = firstMsg.dataset.timestamp;
        const indicator = document.createElement('div');
        indicator.className = 'status-message loading-older';
        indicator.textContent = 'Loading older messages...';
        container.insertBefore(indicator, container.firstChild);

        try {
          const url = data.apiBasePath + '/' + encodeURIComponent(currentRoom) +
            '/messages?limit=' + PAGE_SIZE + '&before=' + encodeURIComponent(oldestTimestamp);
          const response = await fetch(url);
          if (!response.ok) { loadingOlder = false; indicator.remove(); return; }

          const result = await response.json();
          const parsed = parseMessages(result);
          hasMore = parsed.hasMore;

          indicator.remove();

          if (parsed.messages.length === 0) {
            hasMore = false;
            loadingOlder = false;
            return;
          }

          cachePrepend(currentRoom, parsed.messages);

          const prevScrollHeight = container.scrollHeight;
          const prevScrollTop = container.scrollTop;

          let currentDate = null;
          const firstExisting = container.firstChild;
          const fragment = document.createDocumentFragment();

          parsed.messages.forEach(msg => {
            const msgDate = parseMsgDate(msg.timestamp);
            if (currentDate !== msgDate) {
              currentDate = msgDate;
              const sep = document.createElement('div');
              sep.className = 'date-separator';
              sep.textContent = msgDate;
              fragment.appendChild(sep);
            }
            const div = document.createElement('div');
            div.className = 'message';
            div.dataset.timestamp = msg.timestamp;
            const time = parseMsgTime(msg.timestamp);
            const callsign = msg.callsign || msg.author || msg.senderCallsign;
            const pubkey = msg.pubkey || msg.senderPubkey || null;
            const authorDisplay = resolveAuthorDisplay(callsign, pubkey);
            const content = msg.content || '';
            if (pubkey) div.dataset.pubkey = pubkey;
            div.innerHTML = '<div class="message-header">' +
                           '<span class="message-author">' + escapeHtml(authorDisplay) + '</span>' +
                           '<span class="message-time">' + time + '</span>' +
                           '</div>' +
                           '<div class="message-content">' + escapeHtml(content) + '</div>';
            fragment.appendChild(div);
            if (pubkey && !knownNicknames[pubkey]) requestNickname(pubkey);
          });

          // Remove duplicate date separators
          if (firstExisting && firstExisting.classList && firstExisting.classList.contains('date-separator')) {
            const lastAdded = fragment.lastChild;
            if (lastAdded && lastAdded.classList && lastAdded.classList.contains('date-separator') &&
                lastAdded.textContent === firstExisting.textContent) {
              firstExisting.remove();
            }
          }

          container.insertBefore(fragment, container.firstChild);

          // Preserve scroll position
          const newScrollHeight = container.scrollHeight;
          container.scrollTop = prevScrollTop + (newScrollHeight - prevScrollHeight);
        } catch (e) {
          console.error('Error loading older messages:', e);
          indicator.remove();
        } finally {
          loadingOlder = false;
        }
      }

      async function pollNewMessages() {
        if (!lastTimestamp) return;

        try {
          const url = data.apiBasePath + '/' + encodeURIComponent(currentRoom) + '/messages?after=' + encodeURIComponent(lastTimestamp);
          const response = await fetch(url);
          if (!response.ok) return;

          const result = await response.json();
          const parsed = parseMessages(result);

          if (parsed.messages.length > 0) {
            const shouldScroll = isNearBottom();
            const container = document.getElementById('messages');
            parsed.messages.forEach(msg => {
              if (msg.timestamp > lastTimestamp) {
                // Dedup: skip if same author+content exists in last few DOM messages
                const author = (msg.callsign || msg.author || '').toUpperCase();
                const content = msg.content || '';
                const recent = container.querySelectorAll('.message');
                let isDup = false;
                for (let i = recent.length - 1; i >= Math.max(0, recent.length - 5); i--) {
                  if (recent[i].dataset.author === author && recent[i].dataset.content === content) {
                    isDup = true;
                    break;
                  }
                }
                if (!isDup) appendMessage(msg);
                lastTimestamp = msg.timestamp;
              }
            });
            cacheAppend(currentRoom, parsed.messages);
            if (shouldScroll) scrollToBottom(true);
          }
        } catch (e) {
          console.error('Error polling messages:', e);
        }
      }

      function escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
      }

      function startPolling() {
        if (pollInterval) clearInterval(pollInterval);
        pollInterval = setInterval(pollNewMessages, 30000);
      }

      function isNearBottom() {
        const container = document.getElementById('messages');
        if (!container) return true;
        const threshold = 100;
        return container.scrollHeight - container.scrollTop - container.clientHeight < threshold;
      }

      function scrollToBottom(force) {
        requestAnimationFrame(() => {
          const container = document.getElementById('messages');
          if (container && (force || isNearBottom())) {
            container.scrollTop = container.scrollHeight;
          }
        });
      }

      // --- Nostr chat integration (uses window.GeogramNostr from nostr_login_scripts) ---
      let sending = false;

      function showChatInput() {
        const inputArea = document.getElementById('chat-input-area');
        if (inputArea) {
          inputArea.style.display = '';
          if (!isTouchDevice) {
            document.getElementById('chat-input').focus();
          }
          scrollToBottom(true);
        }
      }

      function showChatError(msg) {
        let el = document.getElementById('chat-error');
        if (!el) {
          el = document.createElement('div');
          el.id = 'chat-error';
          el.className = 'chat-error';
          document.getElementById('chat-input-area').appendChild(el);
        }
        el.textContent = msg;
        setTimeout(() => { if (el) el.textContent = ''; }, 5000);
      }

      async function sendMessage() {
        const nostr = window.GeogramNostr || {};
        const input = document.getElementById('chat-input');
        const content = input.value.trim();
        if (!content || !nostr.pubkey || sending) return;

        sending = true;
        const sendBtn = document.getElementById('chat-send');
        sendBtn.disabled = true;

        try {
          // Use shared GeogramNostr.signChatContent() for NOSTR signing
          const signed = nostr.signChatContent
            ? await nostr.signChatContent(content, currentRoom)
            : null;
          if (!signed) {
            showChatError('Failed to sign message — reconnect with Nostr');
            return;
          }

          const body = {
            callsign: signed.callsign,
            content: content,
            pubkey: signed.pubkey,
            event_id: signed.event_id,
            signature: signed.signature,
            created_at: signed.created_at,
          };

          const url = data.apiBasePath + '/' + encodeURIComponent(currentRoom) + '/messages';
          const resp = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
          });

          if (resp.ok) {
            input.value = '';
            const now = new Date();
            const pad = (n) => n.toString().padStart(2, '0');
            const ts = now.getFullYear() + '-' + pad(now.getMonth()+1) + '-' + pad(now.getDate()) + ' ' + pad(now.getHours()) + ':' + pad(now.getMinutes()) + '_' + pad(now.getSeconds());
            const newMsg = { timestamp: ts, author: signed.callsign, pubkey: signed.pubkey, content: content };
            appendMessage(newMsg);
            cacheAppend(currentRoom, [newMsg]);
            scrollToBottom(true);
          } else {
            const err = await resp.json().catch(() => ({}));
            showChatError(err.error || 'Failed to send message');
          }
        } catch (e) {
          console.error('Send error:', e);
          showChatError('Failed to sign or send message');
        } finally {
          sending = false;
          sendBtn.disabled = false;
        }
      }

      function getRoomFromHash() {
        const hash = location.hash.replace('#', '');
        if (!hash) return null;
        const channels = document.querySelectorAll('.channel-item');
        for (const ch of channels) {
          const id = ch.dataset.roomId || '';
          const name = (ch.textContent || '').trim();
          if (id.toLowerCase() === hash.toLowerCase() || name.toLowerCase() === hash.toLowerCase()) {
            return id;
          }
        }
        return null;
      }

      document.addEventListener('DOMContentLoaded', function() {
        initChannels();
        fetchCallsignNicknames();

        // Open room from URL hash if present
        const hashRoom = getRoomFromHash();
        if (hashRoom) {
          currentRoom = hashRoom;
          document.querySelectorAll('.channel-item').forEach(item => {
            item.classList.toggle('active', item.dataset.roomId === hashRoom);
          });
          document.getElementById('current-room').textContent = hashRoom;
        }

        // Initialize lastTimestamp from server-rendered messages
        const allMessages = document.querySelectorAll('.message[data-timestamp]');
        if (allMessages.length > 0) {
          lastTimestamp = allMessages[allMessages.length - 1].dataset.timestamp;
        }

        // If we switched to a hash room, reload messages for it
        if (hashRoom && hashRoom !== (data.currentRoom || 'main')) {
          document.getElementById('messages').innerHTML = '<div class="status-message">Loading messages...</div>';
          loadMessages();
        }

        scrollToBottom(true);
        startPolling();

        // Handle browser back/forward
        window.addEventListener('popstate', function() {
          const room = getRoomFromHash();
          if (room && room !== currentRoom) {
            switchRoom(room, true);
          }
        });

        // Scroll-up pagination
        const messagesContainer = document.getElementById('messages');
        if (messagesContainer) {
          messagesContainer.addEventListener('scroll', function() {
            if (messagesContainer.scrollTop <= 0) {
              loadOlderMessages();
            }
          });
        }

        // visualViewport handler for mobile keyboard
        if (window.visualViewport) {
          window.visualViewport.addEventListener('resize', function() {
            scrollToBottom(false);
          });
        }

        // Register kind 0 callback to update message nicknames
        if (window.GeogramNostr) {
          window.GeogramNostr._onKind0 = function(pubkey, displayName) {
            if (!pubkey || !displayName) return;
            knownNicknames[pubkey] = displayName;
            // Update all message elements with this pubkey
            document.querySelectorAll('.message[data-pubkey="' + pubkey + '"]').forEach(function(el) {
              var authorEl = el.querySelector('.message-author');
              if (authorEl) {
                // Extract callsign from current text (it's the raw callsign or already formatted)
                var currentText = authorEl.textContent;
                var callsign = currentText.includes('(') ? currentText.split('(').pop().replace(')', '').trim() : currentText;
                authorEl.textContent = displayName + ' (' + callsign + ')';
              }
            });
          };
        }

        // If already connected (auto-connect from localStorage), show chat input immediately
        if (window.GeogramNostr && window.GeogramNostr.connected) {
          showChatInput();
        }

        // Listen for nostr-connected event (user clicks connect mid-page)
        document.addEventListener('nostr-connected', function() {
          showChatInput();
        });

        document.getElementById('chat-send').addEventListener('click', sendMessage);
        document.getElementById('chat-input').addEventListener('keydown', function(e) {
          if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
          }
        });
      });
    })();
  ''';
}
