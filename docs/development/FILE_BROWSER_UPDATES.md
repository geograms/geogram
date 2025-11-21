# File Browser Updates - HTML Icons, File Count, and System Open

## Overview
Three new enhancements to the file browser: HTML file icons, folder file count display, and opening files with system default applications.

## Features Implemented

### 1. HTML File Icons
**Location**: `lib/util/file_icon_helper.dart:50-52, 194-196`

HTML files now have their own icon and color:
- **Icon**: `Icons.language` (🌐 globe/web icon)
- **Color**: Blue
- **Extensions**: `.html`, `.htm`

**Examples**:
```
index.html     → 🌐 Blue globe icon
webpage.htm    → 🌐 Blue globe icon
```

### 2. Folder File Count Display
**Location**: `lib/models/collection.dart:11, lib/services/collection_service.dart:547-555, 600-608, lib/main.dart:1555-1567`

Folders now show the number of files they contain in addition to size:

**Before**:
```
📁 photos/
   Size: 45.2 MB
```

**After**:
```
📁 photos/
   12 files • 45.2 MB
```

#### Implementation Details

**FileNode Model**:
- Added `fileCount` property to track files inside directories
- Calculated recursively during tree building
- Counts all files in subdirectories

**Display Format**:
- Single file: `"1 file • 5.2 MB"`
- Multiple files: `"12 files • 45.2 MB"`
- Empty folder: `"0 files • 0 B"`

**Calculation**:
```dart
int fileCount = 0;
for (var child in children) {
  if (child.isDirectory) {
    fileCount += child.fileCount;  // Recursive count
  } else {
    fileCount += 1;  // Direct file
  }
}
```

### 3. Open Files with System Default App
**Location**: `lib/main.dart:1569-1606`

Clicking on a file now opens it with the system's default application:

**Supported Actions**:
- **Images**: Opens in default image viewer
- **PDFs**: Opens in default PDF reader
- **Documents**: Opens in Word/LibreOffice/etc.
- **Videos**: Opens in default video player
- **Audio**: Opens in default music player
- **Code**: Opens in default text editor
- **HTML**: Opens in default web browser
- **Any file**: Attempts to open with associated app

**How It Works**:
1. User clicks on a file (not a folder)
2. System resolves file path
3. Checks if file exists
4. Converts to URI: `file:///path/to/file.pdf`
5. Launches with `url_launcher` package
6. System opens with default app
7. Shows error message if it fails

**Error Handling**:
- File not found: Shows "File not found" snackbar
- No associated app: Shows "Cannot open this file type"
- System error: Shows error message with details
- All errors logged to log.txt

### Dependencies Added

**pubspec.yaml**:
```yaml
dependencies:
  url_launcher: ^6.3.1  # Open files/URLs with system default apps
```

The `url_launcher` package:
- Cross-platform (Linux, Windows, macOS, iOS, Android, Web)
- Handles file:// URIs for local files
- Uses system default handlers
- Supports all major platforms

## User Experience

### Viewing Folders
```
Collection: My Documents
├── 📁 documents/        15 files • 25.3 MB
├── 📁 photos/           127 files • 450.8 MB
├── 📁 projects/         8 files • 12.1 MB
├── 📄 report.pdf        2.5 MB
└── 🌐 index.html        15.3 KB
```

**What You See**:
- Folder shows how many files inside
- Total size includes all nested content
- Instant understanding of folder contents

### Opening Files

**Example 1: Opening a PDF**
```
User clicks: report.pdf
→ System opens: Default PDF viewer (Evince, Adobe Reader, etc.)
→ Log: "Opening file: /path/to/collection/report.pdf"
```

**Example 2: Opening an Image**
```
User clicks: photo.jpg
→ System opens: Default image viewer (Eye of GNOME, Preview, etc.)
→ Shows image in full size
```

**Example 3: Opening HTML**
```
User clicks: index.html
→ System opens: Default web browser (Firefox, Chrome, etc.)
→ Displays webpage
```

**Example 4: Opening Code**
```
User clicks: script.py
→ System opens: Default text editor (gedit, VSCode, etc.)
→ Shows code for editing
```

**Example 5: File Not Found**
```
User clicks: missing.pdf
→ Shows: ❌ "File not found" (snackbar)
→ Log: "File not found" error
```

## Implementation Details

### File Count Calculation

**Recursive Algorithm**:
```dart
// For each directory:
1. Count direct files: +1 for each file
2. Count nested files: +child.fileCount for each subdirectory
3. Total = direct + nested

// Example:
photos/
├── img1.jpg         → +1 file
├── img2.jpg         → +1 file
└── vacation/        → +3 files (from subfolder)
    ├── beach.jpg    → (counted in vacation)
    ├── sunset.jpg   → (counted in vacation)
    └── video.mp4    → (counted in vacation)

Total: 5 files (2 direct + 3 nested)
```

### System File Opening

**URL Launcher Process**:
```dart
1. Get file path: '/home/user/Documents/geogram/collections/books/file.pdf'
2. Create URI: Uri.file(filePath)
3. Check if launchable: canLaunchUrl(uri)
4. Launch: launchUrl(uri)
5. System handles with default app
```

**Platform-Specific Behavior**:

**Linux**:
- Uses `xdg-open` command
- Respects system file associations
- Opens in user's preferred apps

**Windows** (untested):
- Uses `ShellExecute` API
- Opens with file association
- Respects Windows defaults

**macOS** (untested):
- Uses `open` command
- Opens with default app
- Respects macOS associations

### Error Scenarios

**1. File Deleted After Load**
```
Folder shows: report.pdf
User deletes file externally
User clicks: report.pdf
Result: ❌ "File not found"
```

**2. No Associated App**
```
User clicks: file.xyz (unknown extension)
System: No app registered for .xyz
Result: ❌ "Cannot open this file type"
```

**3. Permission Denied**
```
User clicks: protected.pdf (no read permission)
System: Access denied
Result: ❌ "Error opening file: Permission denied"
```

**4. Corrupted File**
```
User clicks: broken.pdf
System tries to open
App may show error or crash
Note: This is handled by the opening app, not our code
```

## Code Examples

### Opening a File (User Perspective)
```
1. Navigate to collection
2. See list of files
3. Click on "document.pdf"
4. PDF opens in system viewer
5. Edit/view as normal
6. Close when done
```

### Folder Info Display
```dart
// Code snippet from _formatSubtitle()
if (widget.fileNode.isDirectory) {
  final fileCount = widget.fileNode.fileCount;
  final size = _formatSize(widget.fileNode.size);
  if (fileCount == 1) {
    return '1 file • $size';
  } else {
    return '$fileCount files • $size';
  }
}
```

### Open File Handler
```dart
Future<void> _openFile() async {
  final filePath = '${widget.collectionPath}/${widget.fileNode.path}';
  final file = File(filePath);

  if (!await file.exists()) {
    // Show error
    return;
  }

  final uri = Uri.file(filePath);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri);
  } else {
    // Show "cannot open" error
  }
}
```

## Visual Examples

### Before (File Count)
```
📁 documents/
   45.2 MB              ← Only size, unclear how many files
```

### After (File Count)
```
📁 documents/
   15 files • 45.2 MB  ← Clear: 15 files totaling 45.2 MB
```

### HTML Files
```
Before: 📄 Generic file icon
After:  🌐 Web/globe icon (blue)
```

### Clickable Files
```
Before: Clicking file did nothing
After:  Click → Opens in system default app
```

## Testing

### Test File Count

**Test Case 1: Simple Folder**
```
Create folder with 3 files
Expected: "3 files • [size]"
```

**Test Case 2: Nested Folders**
```
folder/
├── file1.pdf        → 1 file
├── file2.txt        → 1 file
└── subfolder/       → 2 files
    ├── file3.jpg
    └── file4.doc

Expected: "5 files • [size]"
```

**Test Case 3: Empty Folder**
```
Create empty folder
Expected: "0 files • 0 B"
```

### Test File Opening

**Test Case 1: PDF File**
```
1. Add report.pdf to collection
2. Click on report.pdf
3. Expected: PDF opens in default viewer
4. Verify: File opens successfully
```

**Test Case 2: Image File**
```
1. Add photo.jpg to collection
2. Click on photo.jpg
3. Expected: Image opens in default viewer
4. Verify: Image displays correctly
```

**Test Case 3: HTML File**
```
1. Add index.html to collection
2. Click on index.html
3. Expected: Opens in default browser
4. Verify: Webpage loads
```

**Test Case 4: Unknown File Type**
```
1. Add file with unusual extension (.xyz)
2. Click on it
3. Expected: Error message "Cannot open this file type"
4. Verify: No crash, shows error gracefully
```

**Test Case 5: Deleted File**
```
1. Add file to collection
2. Delete file externally (via file manager)
3. Click on file in collection browser
4. Expected: Error "File not found"
5. Verify: Handles gracefully
```

### Test HTML Icons
```
1. Add .html and .htm files
2. Verify both show globe icon
3. Verify both show blue color
4. Click to open in browser
```

## Logging

All file operations are logged:

```
Opening file: /home/user/Documents/geogram/collections/books/report.pdf
```

Errors are also logged:
```
Cannot launch file: /path/to/file.xyz
Error opening file: Permission denied
```

Check logs:
```bash
cat ~/Documents/geogram/log.txt | grep -i "opening"
```

## Files Changed

### Created
None (all changes to existing files)

### Modified

1. **lib/util/file_icon_helper.dart**
   - Added HTML file icon mapping
   - Added HTML file color

2. **lib/models/collection.dart**
   - Added `fileCount` property to FileNode
   - Updated constructor with default value

3. **lib/services/collection_service.dart**
   - Added file count calculation in `_buildFileTree()`
   - Added file count calculation in `_buildFileTreeRecursive()`

4. **lib/main.dart**
   - Added `url_launcher` import
   - Added `_formatSubtitle()` method for folder info
   - Added `_openFile()` method for system open
   - Updated ListTile subtitle to show file count
   - Updated ListTile onTap to open files

5. **pubspec.yaml**
   - Added `url_launcher: ^6.3.1` dependency

## Known Limitations

1. **File open behavior**: Depends on system settings
   - User must have default apps configured
   - Unknown file types may not open

2. **File count accuracy**:
   - Calculated during tree build
   - Not updated if files added externally
   - Refresh collection to update count

3. **Large folders**:
   - Counting files in very large folders may take time
   - Count is done once during tree building
   - No performance impact after initial load

4. **System open limitations**:
   - May not work in sandboxed environments
   - Web platform has restrictions
   - Mobile may behave differently

## Future Enhancements

### Double-Click to Open
Add double-click support instead of single-click:
```dart
onDoubleTap: _openFile,
```

### Context Menu
Right-click menu with options:
```
- Open
- Open With...
- Show in File Manager
- Copy Path
- Properties
```

### Real-Time File Count
Update count when files added via app:
```dart
onFileAdded: () {
  updateFileCount(folder);
}
```

### Open With Dialog
Let user choose which app to open with:
```dart
showDialog: SelectApp(
  apps: getRegisteredApps(fileType),
  onSelect: (app) => openWith(file, app),
)
```

### System Reveal
Add "Show in File Manager" option:
```dart
Future<void> revealInFileManager(String path) async {
  // Linux: xdg-open folder + select file
  // Windows: explorer /select,path
  // macOS: open -R path
}
```

## Compatibility

- ✅ **Linux**: Full support, tested
- ✅ **Windows**: Should work (untested)
- ✅ **macOS**: Should work (untested)
- ⚠️ **Web**: Limited file system access
- ⚠️ **Mobile**: Different behavior expected

## Best Practices

### For Users
1. Configure default apps in system settings
2. Keep file associations up to date
3. Use standard file formats for best compatibility
4. Don't delete files externally while browsing

### For Developers
1. Always check file existence before opening
2. Handle all errors gracefully
3. Log all operations for debugging
4. Provide clear error messages to users
5. Test with various file types
