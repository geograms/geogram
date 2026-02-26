# APRS Bulletins & Group Bulletins

**Version**: 0.1 (research draft)
**Status**: Evaluating
**Last Updated**: 2026-02-25

## Table of Contents

- [Overview](#overview)
- [Protocol Specification](#protocol-specification)
- [Group Bulletins as Chatrooms](#group-bulletins-as-chatrooms)
- [Current Geogram Implementation](#current-geogram-implementation)
- [Gap Analysis](#gap-analysis)
- [Open Questions](#open-questions)

## Overview

APRS has a native bulletin system defined in APRS101 Chapter 14. Bulletins are one-to-many broadcast messages addressed to special pseudo-callsigns (`BLN0`–`BLN9`). **Group bulletins** extend this by adding a group name to the addressee, creating named channels — the APRS equivalent of chatrooms.

All APRS clients worldwide can receive and display bulletins. Unlike Geogram's current `#tag` convention (which only Geogram understands), group bulletins are part of the official protocol and interoperable with any APRS software.

## Protocol Specification

### The 9-Character Addressee Field

All APRS messages (direct, bulletin, announcement) use the same wire format. The addressee is always **exactly 9 characters**, padded with spaces:

```
:ADDRESSEE:message text{seqno

 ^^^^^^^^^ 9 chars, space-padded
```

### Standard Bulletins (BLN + digit)

Broadcast messages addressed to `BLN0` through `BLN9`:

```
FROM>APRS::BLN0     :Severe weather warning — stay indoors
FROM>APRS::BLN3     :ARES net tonight 147.000 at 2000L
```

- **Line number** (0–9): not a sequence number — it's a display slot. Sending a new `BLN3` replaces the previous `BLN3` from the same station.
- **Never ACKed**: bulletins are fire-and-forget broadcasts.
- **Decay**: retransmitted with increasing intervals until they expire.
- Up to **10 simultaneous bulletin lines** per station.

### Announcements (BLN + letter)

Same format, but use `BLNA` through `BLNZ` instead of digits:

```
FROM>APRS::BLNA     :Weekly net Wednesdays 2000L 146.520
FROM>APRS::BLNZ     :Field Day this weekend — all welcome
```

- **26 announcement slots** (A–Z) per station.
- Longer persistence / slower decay than bulletins.

### Group Bulletins (BLN + digit + group name)

The key feature. A group name (1–5 alphanumeric chars) is appended after the line digit, all within the 9-character addressee field:

```
Position:  123456789
Layout:    BLNnGGGGG     (padded to 9 with spaces)

BLN   = fixed prefix         (3 chars)
n     = line number 0-9      (1 char)
GGGGG = group name, 1-5 chars (rest of 9-char field)
```

**Examples:**

```
FROM>APRS::BLN0WX   :Tornado watch until 2300Z for county X
FROM>APRS::BLN1WX   :Flash flood warning river valley
FROM>APRS::BLN0CQ   :Good morning from Portugal!
FROM>APRS::BLN0GEO  :Geogram users net check-in
FROM>APRS::BLN0CHAT :Anyone on frequency today?
```

**Rules:**
- All APRS stations receive group bulletins (no opt-in needed on the protocol level).
- Clients filter locally by group name if desired.
- Group names are case-insensitive by convention (most clients uppercase).
- Max group name: 5 characters (9 - 3 for `BLN` - 1 for digit = 5).

### Wire Format Summary

| Type | Addressee | Example | ACKed? |
|------|-----------|---------|--------|
| Direct message | `CALLSIGN ` (9 chars) | `:N0CALL   :Hello{42` | Yes |
| Bulletin | `BLNn     ` (digit + spaces) | `:BLN3     :Weather alert` | No |
| Announcement | `BLNx     ` (letter + spaces) | `:BLNA     :Weekly net` | No |
| Group bulletin | `BLNnGROUP` (digit + name + spaces) | `:BLN0CQ   :Hello all!` | No |

## Group Bulletins as Chatrooms

### The Mental Model

A group bulletin group name maps directly to a chatroom/channel:

| Chat concept | APRS equivalent |
|-------------|-----------------|
| Room name | Group name (`CQ`, `WX`, `GEO`) |
| Message sender | From-callsign in TNC2 header |
| Message body | Bulletin text |
| Room is public | All APRS stations receive all bulletins |

### Example Chat Session

Room: `CQ` (general calling channel)

```
CR7BBQ>APRS::BLN0CQ   :Bom dia from Lisbon!
DJ3CE-10>APRS::BLN0CQ :Guten Morgen! 73 from Berlin
N0CALL-9>APRS::BLN0CQ :GM all, checking in from Colorado
CR7BBQ>APRS::BLN0CQ   :Nice to hear you both — how's propagation?
```

Each message is a separate group bulletin. Any APRS client in the world with bulletin reception enabled sees all of these.

### Line Number Strategy for Chat

The original bulletin design uses lines 0–9 as **display slots** (like a 10-line bulletin board where each line is independently updatable). For real-time chat this doesn't map well. Two strategies:

**Strategy A: Always use line 0**
- Simplest — every chat message uses `BLN0<GROUP>`
- Downside: Traditional APRS clients will only show the latest line-0 from each station

**Strategy B: Rotate lines 0–9**
- Cycle through `BLN0<GROUP>`, `BLN1<GROUP>`, ... `BLN9<GROUP>`
- Traditional APRS clients show up to 10 recent messages per station
- Slightly better bulletin board display compatibility

For Geogram's chatroom use case, **Strategy A is simplest** and we display messages as a chat timeline regardless.

## Current Geogram Implementation

### What Exists Today

Geogram's APRS module has a `#tag` convention for group messaging:

1. **Sending**: Tag messages are sent as `BLN1` bulletins with the tag in the message text:
   ```
   MYCALL>APRS::BLN1     :#cq Hello everyone!
   ```

2. **Receiving**: Incoming messages are checked for `messageText.startsWith('#')`. If the tag is subscribed, the message is grouped into a tag conversation.

3. **Conversation types**: `direct` (1:1 by callsign) and `tag` (by `#hashtag`).

4. **APRS-IS filter**: `filter r/LAT/LON/RADIUS g/MYCALL` — only receives position packets in radius and messages addressed to our callsign. **Does not receive bulletins.**

### Why Tags Work (Sort Of)

The `r/` radius filter catches nearby position packets. When those stations also send `BLN1` bulletins with `#tag` text, the packets arrive because they're within radius. But this is incidental — there's no explicit bulletin filter.

Messages from **outside the radius** (e.g., a station 500km away sending `#cq`) are never received because neither the `r/` nor `g/` filter matches them.

## Gap Analysis

### What's Missing for Proper Group Bulletin Support

| Gap | Current | Needed |
|-----|---------|--------|
| **APRS-IS filter** | `g/MYCALL` only | Add `g/BLN*` to receive all bulletins |
| **Bulletin reception** | Bulletins dropped if no coordinates | Allow `BLN*` addressee to bypass coordinate requirement |
| **Group name parsing** | Not implemented | Parse `BLN<digit><group>` from `messageAddressee` |
| **Conversation type** | Only `direct` and `tag` | Add `bulletin` type (or map groups to existing `tag` type) |
| **Sending format** | `BLN1` + `#tag text` | `BLN0<GROUP>` + plain text (no `#` prefix needed) |
| **Interoperability** | Only Geogram understands `#tag` | Standard group bulletins visible to all APRS clients |

### Key Code Paths Affected

| File | What changes |
|------|-------------|
| `lib/teleport/aprs/aprs_is_client.dart` (line ~400) | Add `g/BLN*` to filter string |
| `lib/teleport/aprs/aprs_service.dart` (`addPacket`, line ~558) | Bypass coordinate check for `BLN*` addressees |
| `lib/teleport/aprs/aprs_service.dart` (`getConversations`, line ~391) | Add bulletin grouping logic |
| `lib/teleport/aprs/aprs_service.dart` (`sendMessage`, line ~495) | Use `BLN0<GROUP>` format |
| `lib/teleport/aprs/models/aprs_conversation.dart` | Possibly add `bulletin` conversation type |
| `lib/teleport/aprs/models/aprs_packet.dart` | Add `bulletinGroup` getter to parse group name |

## Open Questions

1. **Replace or coexist with `#tag`?** Should group bulletins replace the current `#tag` system entirely, or should both work? The `#tag` convention is Geogram-only but unlimited in name length. Group bulletins are standard but limited to 5-char names.

2. **Default subscribed groups?** Currently `#cq` is the default tag. Should we subscribe to group `CQ` by default? Should users be able to subscribe/unsubscribe to bulletin groups?

3. **Backwards compatibility**: If we switch from `#tag` to proper group bulletins, existing Geogram users sending `#cq` style messages would need to transition. Should we support both formats during a transition period?

4. **Volume concerns**: Adding `g/BLN*` to the APRS-IS filter will bring in **all** bulletin traffic worldwide (not just nearby). This could be noisy. Should we filter client-side by subscribed groups? Or is the volume manageable?

5. **Line number handling**: Use fixed line 0 for all chat messages? Or rotate 0–9 for better compatibility with traditional bulletin board displays?

6. **Announcement support**: Should we also handle `BLNA`–`BLNZ` announcements, or focus only on group bulletins?

---

*Sources: [APRS101.PDF](https://www.aprs.org/doc/APRS101.PDF), [APRS PROTOCOL.TXT](https://www.aprs.org/APRS-docs/PROTOCOL.TXT), [APRS-IS Filter Reference](http://www.aprs-is.net/javAPRSFilter.aspx), [Xastir Bulletin Scripting](https://kk4vcz.com/posts/xastir-bulletin/)*
