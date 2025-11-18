# Bug Fix: Collections Not Appearing in UI

## Issue
Collections were being created but not appearing in the UI after creation.

## Root Cause
The `collection.js` file was being generated with malformed JSON. The `_prettyJson()` method was manually constructing JSON strings, which resulted in:

```javascript
// BROKEN (missing opening brace):
window.COLLECTION_DATA =   "collection": {
  ...
};
```

Instead of the correct format:

```javascript
// CORRECT:
window.COLLECTION_DATA = {
  "collection": {
    ...
  }
};
```

## Solution
Replaced manual JSON string construction with Dart's built-in `JsonEncoder`:

```dart
// Before: Manual string building (error-prone)
String _prettyJson(Map<String, dynamic> data) {
  return data.entries.map((e) { ... }).join(',\n');
}

// After: Use JsonEncoder (reliable)
final jsonStr = JsonEncoder.withIndent('  ').convert(data);
```

## Additional Fix
Added Enter key support in the Create Collection dialog:
- Pressing Enter in the description field now triggers the Create button
- Added `textInputAction: TextInputAction.done`
- Added `onSubmitted` callback

## Testing
1. Delete any malformed collections: `rm -rf ~/Documents/geogram/collections/*`
2. Restart the app: `./launch-desktop.sh`
3. Create a new collection
4. Collection should now appear immediately in the UI
5. Test Enter key in description field

## Files Changed
- `lib/models/collection.dart` - Fixed JSON generation
- `lib/main.dart` - Added Enter key support
