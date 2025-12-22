# Geogram Documentation Summary

Quick reference guide to all documentation files. Use this to quickly find which specific file to read for detailed information.

## Core Architecture & APIs

### API.md
HTTP API endpoints for the Geogram server. Covers station API, device API, log API, file browsing, status endpoints, and debug API. Essential for understanding how devices communicate with the station and with each other.

### BLE.md
Bluetooth Low Energy implementation details. Describes the BLE advertisement format, HELLO handshake protocol, device discovery, GATT characteristics, and how devices exchange data over Bluetooth.

### EventBus.md
Application-wide event bus system. Explains how different parts of the application communicate via events, event types, publishers, subscribers, and the event lifecycle.

### chat-api.md
Chat-specific HTTP API endpoints. Details the REST API for chat rooms, messages, attachments, and room management. Covers both station-hosted and device-hosted chat rooms.

### command-line-switches.md
CLI arguments and flags for running the application. Documents all available command-line options, switches, and their purposes for different execution modes.

### data-transmission.md
Data transmission protocols and formats. Describes how data is packaged, compressed, and transmitted between devices across different connection types (WiFi, BLE, Internet).

### device-connection-labels.md
Connection path labels displayed in the Devices UI. Explains connection types (WiFi, Internet, Bluetooth, LoRa), verification methods, connection priority order, and how labels are added/removed based on device reachability.

### security-settings.md
Security and privacy settings documentation. Covers HTTP API toggle, debug API toggle, and location granularity settings. Explains how location privacy works and how coordinates are rounded before sharing.

### station-implementation-plan.md
Comprehensive plan for implementing station functionality (root and node stations). Includes UI specifications, models, services, channel bridging, points/reputation system, and authority management. This is a planning document for future implementation.

## Tutorials

### tutorials/publish-new-version.md
Step-by-step guide for releasing new versions. Covers version numbering, changelog updates, git tagging, automated builds, and the release script usage. Essential for anyone publishing updates.

## Implementation Plans

### plan/app-alert-fix.md
Analysis and fix plan for alert folder structure inconsistencies. Documents issues with different folder structures between clients and stations, proposes standardization using active/expired folders and timestamp-based naming.

### plan/chat-with-voice-messages.md
Detailed plan for adding voice message support to 1:1 direct messages. Covers audio format selection (Opus/WebM), storage strategy, UI widgets, bandwidth optimization, and cross-platform implementation.

### plan/irc-bridge-implementation.md
Implementation plan for IRC bridge allowing IRC clients to connect to Geogram chat. Describes server integration, channel mapping, NOSTR identity for guests, bidirectional message flow, and security considerations.

## Bridge Documentation

### bridges/IRC.md
User-facing documentation for the IRC bridge. Explains how to connect with IRC clients (irssi, WeeChat, HexChat), channel naming conventions, authentication, supported features, limitations, and troubleshooting.

## App Format Specifications

All files in `docs/apps/` define the file format and storage structure for different Geogram applications:

### apps/alert-format-specification.md
Emergency alerts and incident reports. File structure, metadata fields, status workflow (active/resolved/expired), comments, photos, and location data.

### apps/backup-format-specification.md
Backup file format for user data. Defines how user profiles, settings, and application data are backed up and restored.

### apps/blog-format-specification.md
Personal blogs and blog posts. Folder structure, post metadata, comments, attachments, RSS feed generation, and NOSTR integration.

### apps/chat-format-specification.md
Chat rooms and messages. Message format, metadata, file attachments, location sharing, polls, reactions, NOSTR signing, and room permissions.

### apps/contacts-format-specification.md
Contact directory format. How contacts are stored, shared, and synchronized between devices.

### apps/events-format-specification.md
Community events and calendar entries. Event metadata, RSVPs, location data, recurrence patterns, and notifications.

### apps/forum-format-specification.md
Forum discussions and threads. Thread structure, post format, moderation, categories, and reply threading.

### apps/groups-format-specification.md
User groups and group management. Group membership, permissions, roles, and group-specific content.

### apps/market-format-specification.md
Marketplace listings. Item listings, categories, pricing, transactions, and user reviews.

### apps/news-format-specification.md
News articles and feeds. Article format, categories, sources, and content aggregation.

### apps/places-format-specification.md
Points of interest and location data. Place metadata, categories, photos, reviews, and geographic indexing.

### apps/postcards-format-specification.md
Postcard messages format. How postcards (short location-based messages) are created, stored, and shared.

### apps/relay-format-specification.md
Station/relay configuration and metadata. Network information, node registration, authority files, and station policies.

## How to Use This Summary

1. **For API Integration**: Start with API.md and chat-api.md
2. **For Device Communication**: Read BLE.md, data-transmission.md, and device-connection-labels.md
3. **For Security/Privacy**: Check security-settings.md
4. **For Building New Features**: Review the relevant app format specification
5. **For Releasing Updates**: Follow tutorials/publish-new-version.md
6. **For Understanding Planned Features**: See files in plan/ directory
7. **For Bridge Integration**: Check bridges/ directory

## Quick File Finder

**Need to know about...**
- HTTP endpoints? → API.md, chat-api.md
- Bluetooth? → BLE.md
- Connection types? → device-connection-labels.md
- Privacy settings? → security-settings.md
- Chat format? → apps/chat-format-specification.md
- Alerts format? → apps/alert-format-specification.md
- Blog format? → apps/blog-format-specification.md
- Station setup? → station-implementation-plan.md
- IRC bridge? → bridges/IRC.md, plan/irc-bridge-implementation.md
- Voice messages? → plan/chat-with-voice-messages.md
- Releasing versions? → tutorials/publish-new-version.md
- CLI options? → command-line-switches.md
- Events system? → EventBus.md

---

*Last updated: 2025-12-22*
*This summary covers all documentation in the docs/ folder*
