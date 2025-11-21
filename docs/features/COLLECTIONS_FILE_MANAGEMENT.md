# Collections File Management Implementation

## Overview
Added comprehensive file management functionality to collections, including adding files/folders, viewing file trees, and editing collection settings.

## Features Implemented

### 1. File Browser Page
**Location**: `lib/main.dart` (lines 1170-1411)

When you click on a collection, you'll see:
- **Collection Info Bar**: Shows description, file count, total size, and visibility status
- **Add Files Button**: Opens file picker to select multiple files to add
- **Add Folder Button**: Opens directory picker to select a folder to add
- **File Tree View**: Displays all files and folders in the collection with:
  - Icons for files and folders
  - File sizes
  - Nested directory structure (indented display)
  - Pull to refresh functionality

### 2. Collection Settings Dialog
**Location**: `lib/main.dart` (lines 1472-1680)

Access via the settings icon (⚙️) in the collection browser. Features:
- **Collection ID**: Read-only display of the collection ID (selectable for copying)
- **Title**: Edit the collection name
- **Description**: Edit the collection description
- **Permissions Section**:
  - **Visibility**: Public, Private, or Restricted
  - **Encryption**: None or AES-256

All changes update `collection.js` and `security.json` with new timestamps.

### 3. File Operations (CollectionService)
**Location**: `lib/services/collection_service.dart`

New methods added:
- `loadFileTree(Collection)`: Loads the file tree from a collection
- `addFiles(Collection, List<String>)`: Adds multiple files to collection (copies, not moves)
- `addFolder(Collection, String)`: Recursively copies a folder to collection
- `updateCollection(Collection)`: Updates collection metadata and timestamps
- `_loadSecuritySettings()`: Loads permissions from `security.json`
- `_buildFileTree()`: Scans collection directory and builds FileNode tree
- `_updateTreeData()`: Updates `tree-data.js` with current file structure

### 4. Enhanced Collection Model
**Location**: `lib/models/collection.dart`

Added:
- **FileNode class**: Represents files/folders in the tree structure
  - `path`: Relative path within collection
  - `name`: File/folder name
  - `size`: Size in bytes
  - `isDirectory`: Boolean flag
  - `hash`: SHA256 hash (for future use)
  - `children`: Nested files/folders

- **Security properties in Collection**:
  - `visibility`: 'public', 'private', 'restricted'
  - `allowedReaders`: List of npub keys (for future use)
  - `encryption`: 'none', 'aes256'

- **Updated generation methods**:
  - `generateTreeDataJs(List<FileNode>)`: Generates tree-data.js with actual file structure
  - `generateSecurityJson()`: Uses actual security settings

## File Structure

When files are added to a collection:

```
~/Documents/geogram/collections/collection_name/
├── collection.js          # Collection metadata (updated timestamp)
├── extra/
│   ├── security.json      # Permissions and encryption settings
│   └── tree-data.js       # File tree structure (updated on add/remove)
├── file1.txt              # Your files
├── file2.pdf
└── folder/                # Your folders (recursively copied)
    ├── subfile1.txt
    └── subfile2.txt
```

## tree-data.js Format

Example generated structure:
```javascript
window.TREE_DATA = {
  "files": [
    {
      "path": "document.pdf",
      "name": "document.pdf",
      "size": 1024000,
      "type": "file"
    },
    {
      "path": "photos",
      "name": "photos",
      "size": 5120000,
      "type": "directory",
      "children": [
        {
          "path": "photos/vacation.jpg",
          "name": "vacation.jpg",
          "size": 2560000,
          "type": "file"
        }
      ]
    }
  ]
}
```

## collection.js Updates

Every time files are added or settings are changed, `collection.js` is updated with:
- New `updated` timestamp
- Current title and description
- All changes logged to console and log.txt

## security.json Format

```json
{
  "visibility": "public",
  "allowedReaders": [],
  "encryption": "none"
}
```

## Usage Flow

1. **Create a Collection**
   - Click "New Collection" button
   - Enter title and description
   - Choose folder location (optional)
   - Collection created with empty file tree

2. **Add Files to Collection**
   - Click on collection to open browser
   - Click "Add Files" to select multiple files
   - Files are copied to collection directory
   - tree-data.js automatically updated
   - collection.js timestamp updated
   - File count and size recalculated

3. **Add Folder to Collection**
   - Click "Add Folder" in collection browser
   - Select a directory
   - Entire folder structure copied recursively
   - All metadata files updated

4. **Edit Collection Settings**
   - Click settings icon (⚙️) in collection browser
   - Modify title, description, visibility, or encryption
   - Click "Save" to update all metadata files
   - Changes reflected immediately in UI

5. **View Files**
   - File tree displayed with proper indentation
   - Folders show total size of contents
   - Files show individual sizes
   - Pull down to refresh file list

## Logging

All operations are logged to:
- Console output (for development)
- `~/Documents/geogram/log.txt` (for debugging)

Log examples:
```
2025-11-18 15:30:45.123 | Adding 3 files to collection
2025-11-18 15:30:46.456 | Files added successfully
2025-11-18 15:30:46.789 | Updated tree-data.js with 5 top-level items
2025-11-18 15:31:12.345 | Updated collection settings: My Collection
```

## Files Changed

1. `lib/models/collection.dart`
   - Added FileNode class
   - Added security properties
   - Updated JSON generation methods

2. `lib/services/collection_service.dart`
   - Added file operations methods
   - Added security loading
   - Added tree building functionality

3. `lib/main.dart`
   - Added CollectionBrowserPage
   - Added EditCollectionDialog
   - Added _FileNodeTile widget
   - Connected collection tap to browser navigation

## Testing

To test the implementation:

```bash
# Run the app
./launch-desktop.sh

# Test flow:
1. Create a new collection
2. Click on the collection to open browser
3. Click "Add Files" and select some files
4. Click "Add Folder" and select a folder
5. Verify files appear in the list
6. Click settings icon and edit collection properties
7. Verify changes are saved
8. Check ~/Documents/geogram/collections/[collection]/
   - Verify files are copied
   - Check collection.js for updated timestamp
   - Check tree-data.js for file structure
   - Check security.json for permissions
```

## Future Enhancements

Possible improvements:
- File deletion functionality
- File download/export
- Directory expansion/collapse state
- File search within collection
- File preview/thumbnails
- Progress indicators for large file operations
- Conflict resolution for duplicate filenames
- Actual encryption implementation for AES-256
- npub-based access control for restricted collections
