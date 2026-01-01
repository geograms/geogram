# Geogram

When the internet goes down, most apps stop working. Geogram keeps going.

Geogram connects people directly—phone to phone, laptop to laptop—without requiring servers, accounts, or infrastructure you don't control. Messages hop between devices over whatever path works: WiFi when available, Bluetooth when it's not, internet when you want global reach.

Every message is signed with cryptographic keys, so you always know who you're talking to. No spoofing, no impersonation, no "trust us" from a company that might not exist next year.

Built for communities that need to communicate when things get difficult: remote areas, disaster response, places where the network is censored or unreliable, or simply people who believe their conversations shouldn't depend on corporate infrastructure.

## Station Server

Your phone can be a server. Your laptop can be a server. That old Raspberry Pi collecting dust can be a server. Geogram runs station software on any device, turning personal hardware into community infrastructure. Nothing lives on someone else's cloud.

Want your blog readable from the internet? Connect your station and it serves pages to any browser. Prefer to stay local? The same station serves your neighborhood over WiFi or syncs with phones over Bluetooth as people walk by. You decide what's reachable and when.

A station at a community center might serve visitors during open hours, then continue syncing with members who pass by after closing. A station on a boat might collect messages while at sea and deliver them when returning to port. The software doesn't care about your connectivity situation—it works with whatever you have.

No monthly fees. No account required. No company can shut down your community's infrastructure because you own it.

## Offline Maps

Geogram includes worldwide satellite imagery and street maps that work without internet. Pan and zoom anywhere on the planet using cached tiles stored locally on your device or synced from a nearby station.

Stations can cache map tiles for their region, serving them to connected devices over WiFi or Bluetooth. A field team downloads tiles before heading out; a community station keeps regional maps available for anyone who connects. No Google, no Mapbox, no API keys, no usage limits.

The map is also your interface to local information. Events, relevant places, and active alerts appear directly on the map—tap to see details, get directions, or add your own. The same map works whether you're online in a city or offline in the wilderness.

## Device Discovery

Geogram finds other devices around you automatically. Someone running Geogram on the same WiFi network? They appear in your device list. Someone within Bluetooth range? They show up too. Connected to a station that knows about other devices? You can reach them as well.

Once you see a device, you can communicate directly—send messages, sync data, share files. Geogram picks the fastest path available: local network when you're on the same WiFi, direct Bluetooth when you're nearby, internet relay when nothing else works. You don't choose the transport; Geogram figures out what's available and uses it.

This means the same conversation continues regardless of how you're connected. Start chatting over WiFi at home, keep talking over Bluetooth while walking together, sync up later through a station when you're apart. The communication adapts; you just talk.

## Apps

Geogram provides a suite of apps designed for community coordination and information sharing. Each app stores data in human-readable text formats that sync between devices through any available transport.

### [Chat](docs/apps/chat-format-specification.md)

Real-time messaging with room-based channels and direct messages. Chat supports file attachments, voice messages, location sharing, and polls. Messages can be cryptographically signed to verify sender identity. The chat system works across all connection types, from high-speed LAN to low-bandwidth Bluetooth, automatically adapting message delivery to available transports.

In off-grid scenarios, chat enables coordination between field teams, emergency responders, or community members who come within Bluetooth range of each other. Messages queue locally and sync when devices reconnect, ensuring nothing is lost even with intermittent connectivity.

### [Blog](docs/apps/blog-format-specification.md)

Long-form publishing with markdown content, drafts, tags, and comments. Blogs provide individual or organizational publishing platforms that work entirely offline. Posts organize chronologically with year-based folders and support file attachments through SHA1-based deduplication.

Blogs enable local journalism, community newsletters, and personal documentation in environments without internet hosting. A local publication can distribute articles to readers who sync when they visit community gathering points, creating a sneakernet distribution network for information.

### [Events](docs/apps/events-format-specification.md)

Community calendars with event details, locations, media galleries, and participant tracking. Events support both physical locations with GPS coordinates and online gatherings. Multi-day events, registration systems, and update timelines keep communities informed about activities.

For organizing community gatherings, emergency drills, or mutual aid distributions, events provide the scheduling and coordination layer. Information propagates through the network as devices sync, ensuring even members with intermittent connectivity learn about upcoming activities.

### [Places](docs/apps/places-format-specification.md)

Geographic points of interest organized by coordinate-based regions. Places document permanent or semi-permanent locations with descriptions, photos, and community reactions. A grid system divides the globe into manageable regions that scale automatically as density increases.

Communities can document water sources, shelter locations, supply caches, hazards, or any other geographic knowledge without relying on commercial mapping services. This information persists locally and syncs between members, building a community-maintained geographic database.

### [Alerts](docs/apps/alert-format-specification.md)

Geographic alert system with severity classification and community verification. Alerts document hazards, infrastructure problems, or situations requiring attention at specific coordinates. Four severity levels (emergency, urgent, attention, info) prioritize response while status tracking follows issues from open through resolution.

Communities use alerts to maintain shared awareness of local conditions. A downed power line, flooded road, or unsafe structure gets documented with photos and location, then verified by others who encounter it. Updates track progress as situations evolve, and resolution proof closes the loop when issues are addressed.

### [Inventory](docs/apps/inventory-format-specification.md)

Personal and shared asset tracking with folder organization up to five levels deep. Inventory tracks items with quantity, purchase date, expiration, and media attachments. Over 200 predefined item types cover off-grid contexts: vehicles, tools, food, medical supplies, communications equipment.

The borrowing system tracks who has what, with support for both callsign-identified community members and free-text entries for external borrowers. Usage and refill tracking monitors consumables. Communities can share inventory visibility through groups while keeping sensitive items private.

### [Transfer](docs/apps/transfer-format-specification.md)

Unified download and upload management across all apps. Transfer handles file movement with queue prioritization, resume capability for interrupted transfers, and patient mode that waits up to 30 days for offline peers. Automatic retry with exponential backoff handles unreliable connections.

When syncing with devices that appear intermittently, transfer queues pending files and completes them as connections become available. Priority levels (urgent, high, normal, low) ensure critical files move first. Ban lists block unwanted transfers from specific callsigns.

### [Bot](docs/apps/bot-format-specification.md)

Offline AI assistant using local GGUF models. The bot provides Q&A about station data, content moderation, semantic search, and voice transcription through Whisper. Model selection adapts to device hardware, from lightweight models on phones to larger models on capable stations.

Stations can provide AI assistance without internet API calls. Content moderation runs locally, search works across all apps, and voice input enables hands-free interaction. The bot indexes station content automatically, making accumulated knowledge searchable.

## Upcoming

The following apps are in development:

- **Forum**: Threaded discussions organized by sections and topics. Forums provide persistent, searchable archives of community knowledge with support for quoting, file attachments, and polls.

- **Market**: Decentralized commerce with shops, inventory, orders, and verified reviews. Peer-to-peer transactions without payment processors or central marketplaces.

- **News**: Short-form announcements with geographic targeting and expiry. Limited to 500 characters with urgency classification (normal, urgent, danger) for rapid information dissemination.

- **Contacts**: Decentralized address book tracking identities by callsign and NOSTR public key. Handles identity changes, revocations, and successor tracking.

- **Postcards**: Sneakernet message delivery through physical carrier chains. Messages travel via intermediate carriers who stamp them with cryptographic proof, creating tamper-proof chains of custody.

## Platforms

Geogram runs on all major platforms from a single codebase:

| Platform | Status |
|----------|--------|
| Android | Stable |
| Linux | Stable |
| Windows | Available but untested |
| macOS | Available but untested |
| iOS | Available but untested |
| Web | Available but untested |

The Android and Linux versions receive the most testing and are recommended for production use. All platforms share the same data formats and can sync with each other through any available transport.

## Download

Grab the latest release from the [releases page](https://github.com/geograms/geogram/releases).

**Android**: Download the APK and install it directly. No Play Store account needed, no approval process, no tracking. Works on any Android device.

**Linux**: Download the AppImage and run it. No installation, no root access, no package manager. Just download, make executable, and launch.

**Other platforms**: Windows, macOS, iOS, and web builds are available but receive less testing. See [docs/technical.md](docs/technical.md) for build instructions if you want to compile from source.

## Documentation

See [docs/technical.md](docs/technical.md) for architecture documentation, build instructions, and detailed specifications covering the API, transport layers, event system, and data formats.

## License

Apache-2.0
