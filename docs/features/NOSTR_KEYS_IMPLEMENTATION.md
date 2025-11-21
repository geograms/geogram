# NOSTR Keys Implementation

## Overview
Collections now use NOSTR npub/nsec key pairs instead of timestamp-based IDs. The npub serves as the collection ID, and the nsec is securely stored in config.json.

## Implementation

### 1. Key Generation
**Location**: `lib/util/nostr_key_generator.dart`

- Generates cryptographically secure 32-byte keys
- Uses `Random.secure()` for entropy
- Format: `npub1[59 hex chars]`, `nsec1[59 hex chars]`
- Fallback mechanism if secure random fails

```dart
final keys = NostrKeyGenerator.generateKeyPair();
// keys.npub -> "npub1abc123..."
// keys.nsec -> "nsec1xyz789..."
```

### 2. Key Storage
**Location**: `lib/services/config_service.dart`

Keys are stored in `~/Documents/geogram/config.json`:

```json
{
  "version": "1.0.0",
  "created": "2025-11-18T...",
  "collections": {
    "favorites": []
  },
  "collectionKeys": {
    "npub1abc123...": {
      "npub": "npub1abc123...",
      "nsec": "nsec1xyz789...",
      "created": 1700312345678
    }
  }
}
```

New methods added:
- `storeCollectionKeys(NostrKeys)` - Store npub/nsec pair
- `getNsec(String npub)` - Retrieve nsec for an npub
- `isOwnedCollection(String npub)` - Check if we have the nsec
- `getAllOwnedCollections()` - Get all owned collection keys

### 3. Collection Creation
**Location**: `lib/services/collection_service.dart:176-184`

When creating a collection:
1. Generate NOSTR key pair
2. Use npub as collection ID
3. Store keys in config.json
4. Create collection with npub as ID

```dart
// Before:
final id = 'collection_${DateTime.now().millisecondsSinceEpoch}';

// After:
final keys = NostrKeyGenerator.generateKeyPair();
final id = keys.npub;
await _configService.storeCollectionKeys(keys);
```

### 4. Collection Metadata
**Location**: `collection.js` format

```javascript
window.COLLECTION_DATA = {
  "collection": {
    "id": "npub1abc123...",  // NOSTR npub
    "title": "My Collection",
    "description": "...",
    "updated": "2025-11-18T..."
  }
};
```

## Security Considerations

### Private Key Storage
- nsec stored in plain text in config.json (local only)
- File permissions should restrict access to user only
- Future: Consider encrypting nsec with user password

### Key Ownership
- Having the nsec proves collection ownership
- Can be used for signing/verification in future
- Enables decentralized collection sharing

### Backup & Recovery
- config.json should be backed up
- Losing nsec means losing ability to prove ownership
- Consider export/import functionality

## Usage Examples

### Create Collection
```bash
# User creates collection "Books"
# System generates: npub1a2b3c4d5e6f...
# Stores nsec in config.json
# Collection folder: ~/Documents/geogram/collections/books/
```

### Verify Ownership
```dart
final npub = "npub1abc...";
if (configService.isOwnedCollection(npub)) {
  // We have the nsec - this is our collection
  print("Owned collection");
} else {
  // We don't have the nsec - shared/downloaded collection
  print("Shared collection");
}
```

### Get Private Key
```dart
final npub = collection.id; // npub1abc...
final nsec = configService.getNsec(npub);
if (nsec != null) {
  // Use nsec for signing, encryption, etc.
}
```

## Future Enhancements

### Signing
- Sign collection updates with nsec
- Verify signatures with npub
- Enables tamper detection

### Sharing
- Export collection with npub (no nsec)
- Others can verify but not modify
- Import creates read-only collection

### Encryption
- Use nsec/npub for encryption keys
- Encrypted collections readable only by owner
- Share decryption keys via NOSTR DMs

### Relay Integration
- Publish collections to NOSTR relays
- Use npub as author identifier
- Subscribe to collection updates

## Migration from Old IDs

Existing collections with timestamp IDs:
- Still work with old ID format
- Can be migrated to npub format
- Migration tool could generate keys for old collections

## Files Changed

1. **lib/util/nostr_key_generator.dart** (NEW)
   - NostrKeyGenerator class
   - NostrKeys data class
   - Secure key generation

2. **lib/services/config_service.dart**
   - Added key storage methods
   - collectionKeys section in config

3. **lib/services/collection_service.dart**
   - Updated createCollection to use npub
   - Stores keys when creating

## Testing

```bash
# Create a new collection
./launch-desktop.sh

# Steps:
1. Create a new collection
2. Check config.json for keys:
   cat ~/Documents/geogram/config.json | jq '.collectionKeys'
3. Verify collection ID is npub format
4. Check collection.js has npub as ID
```

Example output:
```json
{
  "npub1a2b3c...": {
    "npub": "npub1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p7q8r9s0t1u2v3w4x5y6z7a",
    "nsec": "nsec1x9y8z7a6b5c4d3e2f1g0h9i8j7k6l5m4n3o2p1q0r9s8t7u6v5w4x",
    "created": 1700312345678
  }
}
```

## Compatibility with Android App

Matches Android implementation:
- Same key generation approach
- Same storage format (config JSON)
- Same npub/nsec format
- Cross-platform compatible

Collections created on desktop can be:
- Copied to Android and vice versa
- Keys in config.json work on both platforms
- Same collection ID (npub) on all devices
