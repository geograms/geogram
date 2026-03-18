/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

// Shared feedback HTML widgets for NDF web viewers.
// Extracted from NdfWebViewerService for reuse across document types.
// Pure Dart, no Flutter dependencies.

import 'feedback_comment_utils.dart';
import 'html_utils.dart';
import '../work/models/ndf_interaction_settings.dart';

/// Build the feedback HTML section (likes + comments).
/// Returns empty string if no interactions are enabled.
String buildFeedbackHtml(
  NdfInteractionSettings interaction,
  int likesCount,
  List<FeedbackComment> comments,
) {
  if (!interaction.hasAnyInteraction) return '';
  final buf = StringBuffer();

  // Likes section (hidden until Nostr connects)
  if (interaction.permitLikes) {
    buf.write('''
      <div class="feedback-section" id="feedback-section" style="display: none;">
        <button class="like-button" id="like-button" onclick="toggleLike()">
          <span id="like-icon">\u2661</span>
          <span>Like</span>
        </button>
        <span class="like-count" id="like-count">${likesCount > 0 ? "$likesCount like${likesCount != 1 ? "s" : ""}" : ""}</span>
      </div>''');
  }

  // Comments section
  if (interaction.permitComments) {
    buf.write('<div class="comments-section" id="comments-section">');
    buf.write('<h3>Comments${comments.isNotEmpty ? " (${comments.length})" : ""}</h3>');

    for (final c in comments) {
      buf.write('''
        <div class="comment" data-comment-id="${escapeHtml(c.id)}" data-comment-npub="${escapeHtml(c.npub ?? '')}">
          <div class="comment-meta">
            <span class="comment-author">${escapeHtml(c.author)}</span>
            <span class="comment-date">${escapeHtml(c.created)}</span>
            <button class="comment-delete" onclick="deleteComment('${escapeHtml(c.id)}')" style="display:none" title="Delete">\u2715</button>
          </div>
          <p>${escapeHtml(c.content)}</p>
        </div>''');
    }

    // Comment form (hidden until Nostr connects)
    buf.write('''
      <div class="comment-form" id="comment-form" style="display: none;">
        <textarea id="comment-input" placeholder="Write a comment..." rows="3"></textarea>
        <button id="comment-submit" onclick="submitComment()">Post Comment</button>
      </div>''');
    buf.write('</div>');
  }

  return buf.toString();
}

/// Build the likes JS script block.
String getLikesScript(String authorNpub, int likesCount, List<String> likedHexPubkeys, String filename) {
  final encodedFilename = Uri.encodeComponent(filename);
  return '''
<script>
(function() {
  const authorNpub = '${escapeHtml(authorNpub)}';
  const likedPubkeys = ${toJsonArray(likedHexPubkeys)};
  const apiBase = '$encodedFilename';
  let userPubkey = null;
  let isLiked = false;

  function onNostrConnected(pubkey) {
    userPubkey = pubkey;
    var sec = document.getElementById('feedback-section');
    if (sec) sec.style.display = 'flex';
    if (likedPubkeys.includes(pubkey)) {
      isLiked = true;
      updateUI($likesCount);
    }
  }

  function init() {
    document.addEventListener('nostr-connected', function(e) {
      onNostrConnected(e.detail.pubkey);
    });
    if (window.GeogramNostr && window.GeogramNostr.connected && window.GeogramNostr.pubkey) {
      onNostrConnected(window.GeogramNostr.pubkey);
    }
  }

  window.toggleLike = async function() {
    if (!userPubkey || !window.nostr) { alert('Please connect with Nostr first'); return; }
    var button = document.getElementById('like-button');
    button.disabled = true;
    try {
      var unsignedEvent = {
        pubkey: userPubkey,
        created_at: Math.floor(Date.now() / 1000),
        kind: 7,
        tags: [['p', authorNpub], ['type', 'likes']],
        content: 'like'
      };
      var signedEvent = await window.nostr.signEvent(unsignedEvent);
      if (!signedEvent || !signedEvent.sig) throw new Error('Signing failed');
      var response = await fetch(apiBase + '/like', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(signedEvent)
      });
      var result = await response.json();
      if (result.success) { isLiked = result.liked; updateUI(result.like_count); }
    } catch (e) { console.error('Like error:', e); }
    finally { button.disabled = false; }
  };

  function updateUI(count) {
    var button = document.getElementById('like-button');
    var icon = document.getElementById('like-icon');
    var countEl = document.getElementById('like-count');
    button.classList.toggle('liked', isLiked);
    icon.textContent = isLiked ? '\\u2665' : '\\u2661';
    countEl.textContent = count > 0 ? count + ' like' + (count !== 1 ? 's' : '') : '';
  }

  document.addEventListener('DOMContentLoaded', init);
})();
</script>''';
}

/// Build the comments JS script block.
String getCommentsScript(String ownerNpub, String filename) {
  final encodedFilename = Uri.encodeComponent(filename);
  return '''
<script>
(function() {
  const ownerNpub = '${escapeHtml(ownerNpub)}';
  const apiBase = '$encodedFilename';
  let userPubkey = null;
  let userNpub = null;
  let userCallsign = null;

  function onConnected(pubkey) {
    userPubkey = pubkey;
    userNpub = window.GeogramNostr ? window.GeogramNostr.npub : null;
    userCallsign = window.GeogramNostr ? (window.GeogramNostr.callsign || window.GeogramNostr.nickname || 'anon') : 'anon';
    var form = document.getElementById('comment-form');
    if (form) form.style.display = 'block';
    // Show delete buttons for own comments and if user is owner
    document.querySelectorAll('.comment').forEach(function(el) {
      var npub = el.getAttribute('data-comment-npub');
      var btn = el.querySelector('.comment-delete');
      if (btn && (npub === userNpub || userNpub === ownerNpub)) {
        btn.style.display = 'inline';
      }
    });
  }

  document.addEventListener('nostr-connected', function(e) { onConnected(e.detail.pubkey); });
  if (window.GeogramNostr && window.GeogramNostr.connected && window.GeogramNostr.pubkey) {
    onConnected(window.GeogramNostr.pubkey);
  }

  window.submitComment = async function() {
    if (!userPubkey || !window.nostr) { alert('Connect with Nostr first'); return; }
    var input = document.getElementById('comment-input');
    var content = input.value.trim();
    if (!content) return;
    var btn = document.getElementById('comment-submit');
    btn.disabled = true;
    try {
      var unsignedEvent = {
        pubkey: userPubkey,
        created_at: Math.floor(Date.now() / 1000),
        kind: 1,
        tags: [['t', 'ndf-comment'], ['callsign', userCallsign]],
        content: content
      };
      var signedEvent = await window.nostr.signEvent(unsignedEvent);
      if (!signedEvent || !signedEvent.sig) throw new Error('Signing failed');
      var resp = await fetch(apiBase + '/comment', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ author: userCallsign, content: content, npub: userNpub, signature: signedEvent.sig })
      });
      var result = await resp.json();
      if (result.success) { input.value = ''; location.reload(); }
    } catch(e) { console.error('Comment error:', e); }
    finally { btn.disabled = false; }
  };

  window.deleteComment = async function(commentId) {
    if (!userNpub) return;
    if (!confirm('Delete this comment?')) return;
    try {
      var resp = await fetch(apiBase + '/comment/' + encodeURIComponent(commentId), {
        method: 'DELETE',
        headers: { 'X-Npub': userNpub }
      });
      var result = await resp.json();
      if (result.success) { location.reload(); }
    } catch(e) { console.error('Delete error:', e); }
  };
})();
</script>''';
}

/// CSS styles for the feedback section (likes + comments).
String getFeedbackStyles() {
  return '''
/* Feedback section */
.feedback-section {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-top: 20px;
  padding-top: 15px;
  border-top: 1px solid var(--border-color);
}
.like-button {
  display: flex;
  align-items: center;
  gap: 6px;
  background: transparent;
  border: 1px solid var(--border-color);
  border-radius: 4px;
  padding: 6px 14px;
  color: var(--color);
  cursor: pointer;
  font-family: inherit;
  font-size: 0.9rem;
  transition: border-color 0.15s;
}
.like-button:hover { border-color: var(--accent); }
.like-button.liked { color: #e25555; border-color: #e25555; }
.like-count { font-size: 0.85rem; opacity: 0.7; }

/* Comments */
.comments-section {
  margin-top: 24px;
  padding-top: 15px;
  border-top: 1px solid var(--border-color);
}
.comments-section h3 { margin: 0 0 12px; }
.comment {
  padding: 10px 0;
  border-bottom: 1px solid var(--border-color);
}
.comment-meta {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 0.8rem;
  margin-bottom: 4px;
}
.comment-author { color: var(--accent); font-weight: bold; }
.comment-date { opacity: 0.5; }
.comment-delete {
  background: none;
  border: none;
  color: var(--color);
  opacity: 0.4;
  cursor: pointer;
  font-size: 0.8rem;
  padding: 0 4px;
  margin-left: auto;
}
.comment-delete:hover { opacity: 1; color: #e25555; }
.comment p { margin: 0; font-size: 0.9rem; }
.comment-form { margin-top: 16px; }
.comment-form textarea {
  width: 100%;
  background: var(--background);
  color: var(--color);
  border: 1px solid var(--border-color);
  border-radius: 4px;
  padding: 8px;
  font-family: inherit;
  font-size: 0.9rem;
  resize: vertical;
}
.comment-form button {
  margin-top: 8px;
  background: var(--accent);
  color: #000;
  border: none;
  border-radius: 4px;
  padding: 6px 16px;
  cursor: pointer;
  font-family: inherit;
  font-size: 0.85rem;
}
.comment-form button:hover { opacity: 0.9; }
.comment-form button:disabled { opacity: 0.5; cursor: not-allowed; }
''';
}
