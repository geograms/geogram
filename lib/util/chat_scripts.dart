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

        document.querySelectorAll('.channel-item').forEach(item => {
          item.classList.toggle('active', item.dataset.roomId === roomId);
        });

        document.getElementById('current-room').textContent = roomId;
        document.getElementById('messages').innerHTML = '<div class="status-message">Loading messages...</div>';
        loadMessages();
      }

      async function loadMessages() {
        try {
          const url = data.apiBasePath + '/' + encodeURIComponent(currentRoom) + '/messages';
          const response = await fetch(url);
          if (!response.ok) {
            document.getElementById('messages').innerHTML = '<div class="empty-state">Failed to load messages</div>';
            return;
          }

          const result = await response.json();
          let messages = [];
          if (Array.isArray(result)) {
            messages = result;
          } else if (result && Array.isArray(result.messages)) {
            messages = result.messages;
          }

          const container = document.getElementById('messages');
          container.innerHTML = '';

          if (messages.length === 0) {
            container.innerHTML = '<div class="empty-state">No messages yet</div>';
            return;
          }

          let currentDate = null;
          messages.forEach(msg => {
            const msgDate = msg.timestamp.split(' ')[0];
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

          scrollToBottom(true);
        } catch (e) {
          console.error('Error loading messages:', e);
          document.getElementById('messages').innerHTML = '<div class="empty-state">Error loading messages</div>';
        }
      }

      function appendMessage(msg) {
        const container = document.getElementById('messages');
        const div = document.createElement('div');
        div.className = 'message';
        div.dataset.timestamp = msg.timestamp;

        const timeParts = msg.timestamp.split(' ');
        const time = timeParts.length > 1 ? timeParts[1].replace('_', ':').substring(0, 5) : '00:00';
        const author = msg.author || msg.senderCallsign || 'anonymous';
        const content = msg.content || '';

        div.innerHTML = '<div class="message-header">' +
                       '<span class="message-author">' + escapeHtml(author) + '</span>' +
                       '<span class="message-time">' + time + '</span>' +
                       '</div>' +
                       '<div class="message-content">' + escapeHtml(content) + '</div>';

        container.appendChild(div);
      }

      async function pollNewMessages() {
        if (!lastTimestamp) return;

        try {
          const url = data.apiBasePath + '/' + encodeURIComponent(currentRoom) + '/messages?after=' + encodeURIComponent(lastTimestamp);
          const response = await fetch(url);
          if (!response.ok) return;

          const result = await response.json();
          let messages = [];
          if (Array.isArray(result)) {
            messages = result;
          } else if (result && Array.isArray(result.messages)) {
            messages = result.messages;
          }

          if (messages.length > 0) {
            const shouldScroll = isNearBottom();
            messages.forEach(msg => {
              if (msg.timestamp > lastTimestamp) {
                appendMessage(msg);
                lastTimestamp = msg.timestamp;
              }
            });
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

      // --- NIP-07 Nostr Extension Integration ---
      let nostrPubkey = null;
      let nostrCallsign = null;
      let sending = false;

      const BECH32_CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

      function deriveCallsign(hexPubkey) {
        // Convert first 3 hex bytes to byte array
        const bytes = [];
        for (let i = 0; i < 6 && i < hexPubkey.length; i += 2) {
          bytes.push(parseInt(hexPubkey.substr(i, 2), 16));
        }
        // Convert 8-bit groups to 5-bit groups
        let acc = 0, bits = 0;
        const groups = [];
        for (const b of bytes) {
          acc = (acc << 8) | b;
          bits += 8;
          while (bits >= 5) {
            bits -= 5;
            groups.push((acc >> bits) & 31);
          }
        }
        // Map through bech32 charset, take first 4, uppercase
        const suffix = groups.slice(0, 4).map(v => BECH32_CHARSET[v]).join('').toUpperCase();
        return 'X1' + suffix;
      }

      function detectNostr(attempts) {
        if (window.nostr) {
          document.getElementById('nostr-login').style.display = '';
          return;
        }
        if (attempts > 0) {
          setTimeout(() => detectNostr(attempts - 1), 200);
        } else {
          document.getElementById('nostr-unavailable').style.display = '';
        }
      }

      async function connectNostr() {
        try {
          nostrPubkey = await window.nostr.getPublicKey();
          nostrCallsign = deriveCallsign(nostrPubkey);
          document.getElementById('nostr-login').style.display = 'none';
          document.getElementById('chat-input-area').style.display = '';
          document.getElementById('chat-input').focus();
        } catch (e) {
          console.error('Nostr connect error:', e);
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
        const input = document.getElementById('chat-input');
        const content = input.value.trim();
        if (!content || !nostrPubkey || sending) return;

        sending = true;
        const sendBtn = document.getElementById('chat-send');
        sendBtn.disabled = true;

        try {
          const createdAt = Math.floor(Date.now() / 1000);
          const unsignedEvent = {
            kind: 1,
            created_at: createdAt,
            tags: [['t', 'chat'], ['room', currentRoom], ['callsign', nostrCallsign]],
            content: content,
          };

          const signedEvent = await window.nostr.signEvent(unsignedEvent);

          const body = {
            callsign: nostrCallsign,
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
            // Optimistic: append message immediately
            const now = new Date();
            const pad = (n) => n.toString().padStart(2, '0');
            const ts = now.getFullYear() + '-' + pad(now.getMonth()+1) + '-' + pad(now.getDate()) + ' ' + pad(now.getHours()) + ':' + pad(now.getMinutes()) + '_' + pad(now.getSeconds());
            appendMessage({ timestamp: ts, author: nostrCallsign, content: content });
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

        // NIP-07 detection (poll for up to 2 seconds)
        detectNostr(10);

        document.getElementById('nostr-connect').addEventListener('click', connectNostr);
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
