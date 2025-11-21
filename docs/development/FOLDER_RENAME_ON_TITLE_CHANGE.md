# Folder Rename on Title Change

## Overview
When you change a collection's title in settings, the physical folder on disk is automatically renamed to match the new title.

## Implementation

### 1. Automatic Folder Renaming
**Location**: `lib/services/collection_service.dart:339-408`

When the collection title is updated in settings:
1. Old title is captured before changes
2. Title is updated in collection object
3. System detects title change
4. Folder is renamed on disk
5. `storagePath` is updated to new location
6. Metadata files are updated

### 2. Folder Name Sanitization
**Location**: `lib/services/collection_service.dart:380-408`

The new folder name is sanitized to ensure compatibility with both Windows and Linux:

#### Rules Applied:
1. **Spaces → Underscores**: "My Collection" → "my_collection"
2. **Invalid characters removed/replaced**: `\ / : * ? " < > |`
3. **Control characters removed**: ASCII 0-31 and 127
4. **Lowercase conversion**: "Books" → "books"
5. **Length limit**: Maximum 50 characters
6. **Trailing dots/underscores removed**: Windows compatibility
7. **Empty fallback**: Defaults to "collection" if sanitization results in empty string

#### Examples:
```dart
"My Books"           → "my_books"
"Photos: 2024"       → "photos__2024"
"Work/Personal"      → "work_personal"
"Test*File?"         → "test_file_"
"VERY LONG TITLE..." → "very_long_title..." (truncated to 50 chars)
"..."                → "collection" (fallback)
```

### 3. Duplicate Handling
If the new folder name already exists, a counter is appended:
```
my_books      (first)
my_books_1    (if "my_books" exists)
my_books_2    (if "my_books_1" exists)
```

### 4. Settings Dialog Integration
**Location**: `lib/main.dart:1600-1646`

The save method captures the old title and passes it to `updateCollection()`:

```dart
// Capture old title before updating
final oldTitle = widget.collection.title;

// Update collection properties
widget.collection.title = title;

// Save to disk (will rename folder if title changed)
await _collectionService.updateCollection(
  widget.collection,
  oldTitle: oldTitle,
);
```

## User Experience

### Normal Flow
1. User opens collection settings (⚙️ icon)
2. Changes title from "My Books" to "Work Documents"
3. Clicks "Save"
4. Folder renamed: `my_books` → `work_documents`
5. All files preserved
6. Collection continues to work normally

### Edge Cases

#### Same Title
If title hasn't changed, no folder rename occurs:
```dart
Old: "My Books"
New: "My Books"
Result: No action taken
```

#### Only Capitalization Changed
If only capitalization changes, behavior depends on filesystem:
- **Case-sensitive (Linux)**: Folder renamed
- **Case-insensitive (Windows/macOS)**: May skip rename
```dart
Old: "books"
New: "Books"
Result: Depends on filesystem
```

#### Special Characters
Special characters are handled gracefully:
```dart
Old: "Books"
New: "Books & Articles"
Folder: "books" → "books___articles"
```

#### Very Long Titles
Long titles are truncated to prevent issues:
```dart
Title: "A Very Long Collection Name That Exceeds The Maximum Length"
Folder: "a_very_long_collection_name_that_exceeds_the_m"
```

## Error Handling

### Folder Doesn't Exist
If the original folder doesn't exist:
```
Exception: Collection folder does not exist
```

### Rename Permission Denied
If the system can't rename the folder (permissions, locked files):
```
Exception: Failed to rename collection folder: [error details]
```

### Folder Already Exists
If target folder exists, counter is appended automatically:
```
my_collection → my_collection_1
```

## Logging

All rename operations are logged to console and log file:

```
Renaming folder: /path/to/old_folder -> /path/to/new_folder
Folder renamed successfully
Updated collection: New Title
```

If rename fails:
```
Error renaming folder: [error message]
ERROR updating collection: Failed to rename collection folder: [details]
Stack trace: [trace]
```

## Technical Details

### File Structure Before
```
~/Documents/geogram/collections/
└── my_books/
    ├── collection.js
    ├── extra/
    │   ├── security.json
    │   └── tree-data.js
    ├── book1.pdf
    └── book2.pdf
```

### File Structure After (Title: "My Books" → "Work Documents")
```
~/Documents/geogram/collections/
└── work_documents/
    ├── collection.js         # Updated with new title
    ├── extra/
    │   ├── security.json     # Unchanged
    │   └── tree-data.js      # Paths updated
    ├── book1.pdf            # Files preserved
    └── book2.pdf
```

### Path Updates
- `collection.storagePath` updated to new folder path
- All relative file paths remain valid
- Absolute paths updated in collection object
- `tree-data.js` regenerated with correct paths

## Invalid Characters Reference

### Windows Invalid Characters
```
\ / : * ? " < > |
```

### Additional Restrictions
- Control characters (ASCII 0-31)
- Delete character (ASCII 127)
- Reserved names: CON, PRN, AUX, NUL, COM1-9, LPT1-9
- Trailing dots or spaces
- File names ending in a period

### Linux Invalid Characters
```
/ (forward slash)
\0 (null character)
```

Note: Linux is more permissive, but we apply Windows rules for cross-platform compatibility.

## Testing

### Test Scenarios

1. **Basic Rename**
   ```bash
   Old: "test"
   New: "new test"
   Expected: "test" → "new_test"
   ```

2. **Special Characters**
   ```bash
   Old: "test"
   New: "test: 2024 (work)"
   Expected: "test" → "test__2024__work_"
   ```

3. **Duplicate Name**
   ```bash
   Old: "books"
   New: "documents"
   Existing: "documents" folder exists
   Expected: "books" → "documents_1"
   ```

4. **No Change**
   ```bash
   Old: "test"
   New: "test"
   Expected: No rename operation
   ```

5. **Long Title**
   ```bash
   Old: "test"
   New: "A very long collection title that exceeds fifty characters limit"
   Expected: Truncated to 50 chars
   ```

### Test Commands

```bash
# Start the app
./launch-desktop.sh

# Test steps:
1. Create collection "Test Collection"
2. Check folder: ~/Documents/geogram/collections/test_collection/
3. Open settings, change title to "My Documents"
4. Save settings
5. Check folder renamed to: my_documents/
6. Verify all files still present
7. Check log: ~/Documents/geogram/log.txt
```

## Files Changed

1. **lib/services/collection_service.dart**
   - Modified `updateCollection()` to accept `oldTitle` parameter
   - Added `_renameCollectionFolder()` method
   - Added `_sanitizeFolderName()` method

2. **lib/main.dart**
   - Modified `_save()` in `_EditCollectionDialogState`
   - Captures old title before update
   - Passes old title to `updateCollection()`

## Future Enhancements

### Confirmation Dialog
Show confirmation before renaming:
```dart
showDialog(
  title: 'Rename Folder?',
  content: 'Folder will be renamed from "$oldName" to "$newName"',
  actions: ['Cancel', 'Rename'],
);
```

### Undo Functionality
Allow reverting folder rename:
```dart
// Store rename history
final renameHistory = [
  {'from': 'old_folder', 'to': 'new_folder', 'timestamp': ...}
];
```

### Custom Folder Names
Allow user to specify folder name separately from title:
```dart
TextField(
  label: 'Folder Name (optional)',
  hint: 'Leave empty to auto-generate from title',
);
```

### Validation Preview
Show what the folder name will be before saving:
```dart
Text('Folder will be renamed to: "$sanitizedName"');
```

## Compatibility

- ✅ **Linux**: Full support
- ✅ **Windows**: Full support (untested)
- ✅ **macOS**: Should work (untested)

## Known Limitations

1. **Case-insensitive filesystems**: May skip rename if only case changes
2. **Long paths**: Windows has 260 character path limit
3. **Special characters**: Some are replaced with underscores
4. **Emoji**: Not tested, likely removed by sanitization
5. **Unicode**: Should work but not extensively tested

## Best Practices

### For Users
1. Use simple, descriptive titles
2. Avoid special characters if possible
3. Keep titles reasonably short (< 30 characters recommended)
4. Close collection before renaming (to avoid file locks)

### For Developers
1. Always validate folder names before operations
2. Log all rename operations
3. Handle errors gracefully
4. Preserve data integrity during renames
5. Test on multiple platforms/filesystems
