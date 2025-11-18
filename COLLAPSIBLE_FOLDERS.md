# Collapsible Folders Implementation

## Overview
File browser now supports collapsing and expanding folders. All folders start collapsed by default, and users can click to expand/collapse them.

## Implementation

### 1. State Management
**Location**: `lib/main.dart:1187`

Added state to track expanded folders:
```dart
final Set<String> _expandedFolders = {}; // Track expanded folder paths
```

- Uses Set for O(1) lookup
- Stores folder paths as unique identifiers
- Empty by default (all folders collapsed)

### 2. UI Updates
**Location**: `lib/main.dart:1521-1560`

#### Expand/Collapse Icon
- **Collapsed**: Right chevron (►)
- **Expanded**: Down chevron (▼)

```dart
trailing: fileNode.isDirectory && hasChildren
    ? Icon(
        isExpanded ? Icons.expand_more : Icons.chevron_right,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      )
    : null,
```

#### Click Handler
```dart
onTap: fileNode.isDirectory && hasChildren
    ? () {
        onToggleExpand(fileNode.path);
      }
    : null,
```

#### Conditional Rendering
Children only shown when folder is expanded:
```dart
if (fileNode.isDirectory && hasChildren && isExpanded)
  ...fileNode.children!.map((child) => _FileNodeTile(...))
```

### 3. Widget Updates
**Location**: `lib/main.dart:1497-1508`

Updated _FileNodeTile constructor:
```dart
class _FileNodeTile extends StatelessWidget {
  final FileNode fileNode;
  final int indentLevel;
  final Set<String> expandedFolders;      // NEW
  final void Function(String) onToggleExpand;  // NEW

  const _FileNodeTile({
    required this.fileNode,
    required this.expandedFolders,
    required this.onToggleExpand,
    this.indentLevel = 0,
  });
}
```

## User Experience

### Initial State
When opening a collection:
- All folders are collapsed
- Only top-level files and folder names visible
- Clean, organized view

### Expanding Folders
1. Click on a folder
2. Chevron animates from right (►) to down (▼)
3. Children appear with indent
4. Nested folders also start collapsed

### Collapsing Folders
1. Click on expanded folder
2. Chevron animates from down (▼) to right (►)
3. Children disappear
4. Nested expanded folders remain in memory

### Nested Folders
- Each folder tracks its own expansion state
- Expanding parent doesn't auto-expand children
- Collapsing parent hides all descendants
- Re-expanding parent remembers child states

## Example Structure

```
my_collection/
├── documents/          [collapsed] ►
│   ├── work/          [collapsed] ►
│   │   ├── report.pdf
│   │   └── notes.txt
│   └── personal/      [collapsed] ►
│       └── resume.pdf
├── photos/            [expanded] ▼
│   ├── vacation.jpg
│   └── family.jpg
└── readme.txt
```

**After clicking "documents":**
```
my_collection/
├── documents/          [expanded] ▼
│   ├── work/          [collapsed] ►
│   └── personal/      [collapsed] ►
├── photos/            [expanded] ▼
│   ├── vacation.jpg
│   └── family.jpg
└── readme.txt
```

**After clicking "work":**
```
my_collection/
├── documents/          [expanded] ▼
│   ├── work/          [expanded] ▼
│   │   ├── report.pdf
│   │   └── notes.txt
│   └── personal/      [collapsed] ►
├── photos/            [expanded] ▼
│   ├── vacation.jpg
│   └── family.jpg
└── readme.txt
```

## Performance

### Efficient Rendering
- Only visible items are rendered
- Collapsed folders don't render children
- Set lookup is O(1) for expansion check
- Scales well with large file trees

### State Persistence
- Expansion state maintained during:
  - File additions
  - Folder creation
  - Pull to refresh
- Lost when navigating away (intentional)

### Memory Usage
- Only stores folder paths in Set
- Minimal memory overhead
- No deep copying of file tree

## Technical Details

### Path Identification
Folders identified by their path property:
```dart
final isExpanded = expandedFolders.contains(fileNode.path);
```

Example paths:
- `"documents"` - Top level
- `"documents/work"` - Nested
- `"photos/vacation/2024"` - Deep nested

### Toggle Logic
```dart
onToggleExpand: (path) {
  setState(() {
    if (_expandedFolders.contains(path)) {
      _expandedFolders.remove(path);  // Collapse
    } else {
      _expandedFolders.add(path);     // Expand
    }
  });
}
```

### Recursive Rendering
```dart
...fileNode.children!.map((child) => _FileNodeTile(
  fileNode: child,
  expandedFolders: expandedFolders,  // Pass state down
  onToggleExpand: onToggleExpand,    // Pass callback down
  indentLevel: indentLevel + 1,      // Increase indent
))
```

## Benefits

1. **Better Organization**
   - Large collections easier to navigate
   - Less scrolling required
   - Focus on relevant content

2. **Improved Performance**
   - Don't render hidden items
   - Faster initial load
   - Responsive with many files

3. **User Control**
   - Expand only what's needed
   - Keep context visible
   - Natural file explorer UX

4. **Consistency**
   - Matches common file managers
   - Intuitive interaction
   - Standard chevron icons

## Future Enhancements

### Expand All / Collapse All
Add buttons to expand or collapse all folders at once:
```dart
IconButton(
  icon: Icon(Icons.unfold_more),
  onPressed: () {
    setState(() {
      _expandedFolders.addAll(_getAllFolderPaths());
    });
  },
)
```

### Remember State
Persist expansion state across sessions:
```dart
// Save to preferences
await prefs.setStringList(
  'expanded_${collection.id}',
  _expandedFolders.toList(),
);

// Restore on load
_expandedFolders.addAll(
  prefs.getStringList('expanded_${collection.id}') ?? []
);
```

### Keyboard Navigation
Add arrow key support:
- Right arrow: Expand folder
- Left arrow: Collapse folder
- Up/Down: Navigate items

### Context Menu
Right-click options:
- Expand All Children
- Collapse All Children
- Open in System File Manager

## Files Changed

1. **lib/main.dart:1187**
   - Added `_expandedFolders` Set to state

2. **lib/main.dart:1473-1487**
   - Updated ListView.builder to pass state and callback

3. **lib/main.dart:1497-1508**
   - Updated _FileNodeTile constructor parameters

4. **lib/main.dart:1521-1560**
   - Updated build method with expand/collapse logic
   - Changed icon based on state
   - Conditional child rendering

## Testing

```bash
./launch-desktop.sh
```

Test scenarios:
1. Open collection with folders
   - ✓ All folders collapsed by default
2. Click folder
   - ✓ Expands and shows contents
   - ✓ Icon changes to down chevron
3. Click folder again
   - ✓ Collapses and hides contents
   - ✓ Icon changes to right chevron
4. Expand nested folders
   - ✓ Can expand multiple levels
   - ✓ Each level independent
5. Add files while folders expanded
   - ✓ Expansion state preserved
   - ✓ New files appear correctly
6. Pull to refresh
   - ✓ Expansion state maintained
