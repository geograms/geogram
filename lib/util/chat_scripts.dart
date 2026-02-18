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

      function switchRoom(roomId) {
        if (roomId === currentRoom && lastTimestamp !== null) return;
        currentRoom = roomId;
        lastTimestamp = null;
        hasMore = true;
        loadingOlder = false;

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

      function appendMessage(msg) {
        const container = document.getElementById('messages');
        const div = document.createElement('div');
        div.className = 'message';
        div.dataset.timestamp = msg.timestamp;

        const time = parseMsgTime(msg.timestamp);
        const author = msg.author || msg.senderCallsign || 'anonymous';
        const content = msg.content || '';

        div.innerHTML = '<div class="message-header">' +
                       '<span class="message-author">' + escapeHtml(author) + '</span>' +
                       '<span class="message-time">' + time + '</span>' +
                       '</div>' +
                       '<div class="message-content">' + escapeHtml(content) + '</div>';

        container.appendChild(div);
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
            const author = msg.author || msg.senderCallsign || 'anonymous';
            const content = msg.content || '';
            div.innerHTML = '<div class="message-header">' +
                           '<span class="message-author">' + escapeHtml(author) + '</span>' +
                           '<span class="message-time">' + time + '</span>' +
                           '</div>' +
                           '<div class="message-content">' + escapeHtml(content) + '</div>';
            fragment.appendChild(div);
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
            parsed.messages.forEach(msg => {
              if (msg.timestamp > lastTimestamp) {
                appendMessage(msg);
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
        pollInterval = setInterval(pollNewMessages, 5000);
      }

      function isNearBottom() {
        const container = document.getElementById('messages');
        if (!container) return true;
        const threshold = 100;
        return container.scrollHeight - container.scrollTop - container.clientHeight < threshold;
      }

      function scrollToBottom(force) {
        const container = document.getElementById('messages');
        if (container && (force || isNearBottom())) {
          container.scrollTop = container.scrollHeight;
        }
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
          const createdAt = Math.floor(Date.now() / 1000);
          const unsignedEvent = {
            kind: 1,
            created_at: createdAt,
            tags: [['t', 'chat'], ['room', currentRoom], ['callsign', nostr.callsign]],
            content: content,
          };

          const signedEvent = await window.nostr.signEvent(unsignedEvent);

          const body = {
            callsign: nostr.callsign,
            content: content,
            pubkey: signedEvent.pubkey,
            event_id: signedEvent.id,
            signature: signedEvent.sig,
            created_at: signedEvent.created_at,
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
            const newMsg = { timestamp: ts, author: nostr.callsign, content: content };
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

      document.addEventListener('DOMContentLoaded', function() {
        initChannels();
        scrollToBottom(true);
        startPolling();

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
