# Reusable Widgets and Components

This document catalogs reusable UI components available in the Geogram codebase. These widgets are designed to be used across multiple features and pages.

---

## Picker Widgets

### UserPickerWidget

**File:** `lib/widgets/user_picker_widget.dart`

Select a user from known devices organized by folders with search functionality.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `excludeNpub` | String? | No | Npub to exclude from selection (e.g., current user) |

**Returns:** `UserPickerResult` with `callsign`, `npub`, and `displayName`

**Usage:**
```dart
final result = await showModalBottomSheet<UserPickerResult>(
  context: context,
  isScrollControlled: true,
  builder: (_) => UserPickerWidget(
    i18n: widget.i18n,
    excludeNpub: currentUserNpub,
  ),
);

if (result != null) {
  print('Selected: ${result.callsign} (${result.npub})');
}
```

**Features:**
- Users organized by device folders
- Search by callsign, display name, or npub
- Auto-expands single folder
- Filters out users without npub
- DraggableScrollableSheet UI

---

### CurrencyPickerWidget

**File:** `lib/widgets/wallet/currency_picker_widget.dart`

Select from available currencies including crypto, fiat, time-based, and custom currencies.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `selectedCurrency` | String? | No | Currently selected currency code |
| `showTime` | bool | No | Show time-based currencies (default: true) |
| `showCrypto` | bool | No | Show cryptocurrencies (default: true) |
| `showFiat` | bool | No | Show fiat currencies (default: true) |
| `showCustom` | bool | No | Show custom currencies (default: true) |

**Returns:** Currency code as `String`

**Usage:**
```dart
final currency = await showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => CurrencyPickerWidget(
    i18n: widget.i18n,
    selectedCurrency: 'EUR',
    showCrypto: true,
    showFiat: true,
  ),
);
```

**Features:**
- Categorized list (Time, Crypto, Fiat, Custom)
- Color-coded category badges
- Currency symbols display
- Checkmark for selected currency

---

### TypeSelectorWidget

**File:** `lib/widgets/inventory/type_selector_widget.dart`

Select an item type from the inventory catalog with category filtering.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `selectedType` | String | Yes | Currently selected type ID |
| `scrollController` | ScrollController? | No | External scroll controller |

**Returns:** Type ID as `String`

**Usage:**
```dart
final typeId = await showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => TypeSelectorWidget(
    i18n: widget.i18n,
    selectedType: currentTypeId,
  ),
);
```

**Features:**
- 16 item categories (food, electronics, tools, etc.)
- Category tabs for quick navigation
- Search with category filtering
- Icons for each category

---

## Viewer Pages

### PhotoViewerPage

**File:** `lib/pages/photo_viewer_page.dart`

Full-screen media viewer for photos and videos with zoom, pan, and navigation.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `imagePaths` | List\<String\> | Yes | List of local or network media paths (images and videos) |
| `initialIndex` | int | No | Starting media index (default: 0) |

**Usage:**
```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => PhotoViewerPage(
      imagePaths: ['/path/to/image.jpg', '/path/to/video.mp4'],
      initialIndex: 0,
    ),
  ),
);
```

**Features:**
- **Images:** Zoom (0.5x to 4.0x) with pinch gesture, pan support
- **Videos:** Tap to play/pause, progress bar with scrubbing, duration display
- Swipe navigation between media items
- Keyboard navigation (arrows, escape)
- Media counter display
- Page indicator dots
- Save/download button (images and videos)
- Network and local file support
- Black background (cinema mode)

**Supported Video Formats:**
`.mp4`, `.avi`, `.mkv`, `.mov`, `.wmv`, `.flv`, `.webm`

---

### LocationPickerPage

**File:** `lib/pages/location_picker_page.dart`

Interactive map-based location picker or viewer.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `initialPosition` | LatLng? | No | Starting coordinates |
| `viewOnly` | bool | No | Read-only mode (default: false) |

**Returns:** `LatLng` (selected position)

**Usage:**
```dart
final position = await Navigator.push<LatLng>(
  context,
  MaterialPageRoute(
    builder: (_) => LocationPickerPage(
      initialPosition: LatLng(38.7223, -9.1393),
      viewOnly: false,
    ),
  ),
);

if (position != null) {
  print('Selected: ${position.latitude}, ${position.longitude}');
}
```

**Features:**
- Map tap to select location
- Manual latitude/longitude input
- Auto-detect current location
- Zoom in/out controls
- Layer toggle (Standard/Satellite)
- Reset north compass
- Tile caching for offline use
- 6 decimal precision coordinates

---

### DocumentViewerEditorPage

**File:** `lib/pages/document_viewer_editor_page.dart`

Universal document viewer with auto-detection for text, markdown, and PDF files. Uses continuous vertical scrolling.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `filePath` | String | Yes | Path to the document file |
| `viewerType` | DocumentViewerType | No | Force viewer type (default: auto) |
| `title` | String? | No | Custom app bar title (default: filename) |
| `readOnly` | bool | No | Read-only mode (default: true) |

**Viewer Types:**
- `DocumentViewerType.auto` - Detect from file extension (default)
- `DocumentViewerType.text` - Plain text (.txt, .log, .json, .xml, etc.)
- `DocumentViewerType.markdown` - Markdown (.md, .markdown)
- `DocumentViewerType.pdf` - PDF documents
- `DocumentViewerType.cbz` - Comic book archives (future)

**Usage:**
```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => DocumentViewerEditorPage(
      filePath: '/path/to/document.pdf',
      // viewerType: DocumentViewerType.auto, // optional
      // title: 'My Document', // optional
    ),
  ),
);
```

**Features:**
- Auto-detection from file extension
- Continuous vertical scroll (webtoon-style)
- PDF pages rendered as images for smooth scrolling
- Markdown with styled headings, code blocks, blockquotes
- Plain text with monospace font
- Selectable text
- Page count display for PDFs
- Error handling with retry button

---

### ContractDocumentPage

**File:** `lib/pages/contract_document_page.dart`

Display raw contract/debt document with markdown rendering.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `collectionPath` | String | Yes | Path to the wallet collection |
| `debtId` | String | Yes | ID of the debt to display |
| `i18n` | I18nService | Yes | Localization service |

**Usage:**
```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => ContractDocumentPage(
      collectionPath: '/path/to/collection',
      debtId: 'debt-123',
      i18n: widget.i18n,
    ),
  ),
);
```

**Features:**
- Full markdown rendering
- Signature status indicators in app bar
- Selectable text
- Styled headings, blockquotes, code blocks
- Shadow box document container

---

## Player Widgets

### VoicePlayerWidget

**File:** `lib/widgets/voice_player_widget.dart`

Play voice messages with download support.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `filePath` | String | Yes | Local file path or remote URL |
| `durationSeconds` | int? | No | Metadata duration for display |
| `isLocal` | bool | No | Whether file is local (default: true) |
| `onDownloadRequested` | Future\<String?\> Function()? | No | Download callback for remote files |
| `backgroundColor` | Color? | No | Background color for widget |

**Usage:**
```dart
VoicePlayerWidget(
  filePath: '/path/to/voice.opus',
  durationSeconds: 15,
  isLocal: true,
  backgroundColor: Colors.blue.shade100,
)
```

**Features:**
- Play/pause/stop controls
- Elapsed/total time display
- Download progress indicator
- Loading state with spinner
- Automatic playback end detection

---

### MusicPlayerWidget

**File:** `lib/widgets/music_player_widget.dart`

Display and play generated music tracks.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `track` | MusicTrack | Yes | Music track object |
| `showGenre` | bool | No | Display genre label (default: true) |
| `showModel` | bool | No | Display model used label (default: true) |
| `backgroundColor` | Color? | No | Bubble background color |
| `onDelete` | VoidCallback? | No | Delete callback |

**Usage:**
```dart
MusicPlayerWidget(
  track: musicTrack,
  showGenre: true,
  showModel: true,
  onDelete: () => deleteTrack(musicTrack.id),
)
```

**Features:**
- Play/pause/stop controls
- Progress bar with seek
- Track info (genre, model, duration)
- Delete button

---

### VoiceRecorderWidget

**File:** `lib/widgets/voice_recorder_widget.dart`

Record and preview voice messages before sending.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `onSend` | void Function(String filePath, int durationSeconds) | Yes | Send callback |
| `onCancel` | VoidCallback | Yes | Cancel callback |

**Usage:**
```dart
VoiceRecorderWidget(
  onSend: (filePath, duration) {
    sendVoiceMessage(filePath, duration);
  },
  onCancel: () {
    setState(() => _showRecorder = false);
  },
)
```

**Features:**
- Recording state with animated dot
- Duration timer (max 30 seconds)
- Preview playback with progress
- Seek during preview
- Cancel/Delete and Send buttons

---

## Dialog Widgets

### NewChannelDialog

**File:** `lib/widgets/new_channel_dialog.dart`

Create new chat channels (direct message or group).

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `existingChannelIds` | List\<String\> | Yes | Existing IDs for validation |
| `knownCallsigns` | List\<String\> | Yes | Available participants for groups |

**Returns:** `ChatChannel` object

**Usage:**
```dart
final channel = await showDialog<ChatChannel>(
  context: context,
  builder: (_) => NewChannelDialog(
    existingChannelIds: existingIds,
    knownCallsigns: callsigns,
  ),
);

if (channel != null) {
  createChannel(channel);
}
```

**Features:**
- Toggle between Direct Message and Group
- Form validation
- Participant selection with FilterChips
- Duplicate ID detection

---

### NewThreadDialog

**File:** `lib/widgets/new_thread_dialog.dart`

Create new forum threads with title and content.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `existingThreadTitles` | List\<String\> | Yes | For duplicate detection |
| `maxTitleLength` | int | No | Max title length (default: 100) |
| `maxContentLength` | int | No | Max content length (default: 5000) |

**Returns:** `Map<String, String>` with 'title' and 'content' keys

**Usage:**
```dart
final result = await showDialog<Map<String, String>>(
  context: context,
  builder: (_) => NewThreadDialog(
    existingThreadTitles: titles,
    maxTitleLength: 100,
  ),
);

if (result != null) {
  createThread(result['title']!, result['content']!);
}
```

**Features:**
- Title and content validation
- Duplicate title detection
- Character counters
- Helpful tip box

---

## Selector Widgets

### CallsignSelectorWidget

**File:** `lib/widgets/callsign_selector_widget.dart`

Switch between multiple callsigns/profiles.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `onProfileSwitch` | Function(Profile)? | No | Callback on profile switch |
| `onCreateNewProfile` | VoidCallback? | No | Custom create handler |
| `showCreateOption` | bool | No | Show "add new callsign" option |
| `compact` | bool | No | Compact chip vs full list mode |

**Usage:**
```dart
// Full mode
CallsignSelectorWidget(
  onProfileSwitch: (profile) => switchTo(profile),
  showCreateOption: true,
  compact: false,
)

// Compact mode (for tight spaces)
CallsignSelectorWidget(
  compact: true,
)
```

**Features:**
- Two display modes: compact (dropdown chip) and full (expandable list)
- Profile avatar display
- Active profile indicator
- Create new profile dialog
- Relay profile badge

---

### ProfileSwitcher

**File:** `lib/widgets/profile_switcher.dart`

App bar widget for profile switching with popup menu.

**Usage:**
```dart
AppBar(
  title: const Text('App Title'),
  actions: [
    ProfileSwitcher(),
  ],
)
```

**Features:**
- Popup menu on tap
- Profile avatar with custom images
- Nickname and callsign display
- Navigate to profile management

---

## Tree Widgets

### FolderTreeWidget

**File:** `lib/widgets/inventory/folder_tree_widget.dart`

Display hierarchical folder structure for navigation.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `selectedPath` | List\<String\> | Yes | Current selected path |
| `onFolderSelected` | ValueChanged\<List\<String\>\> | Yes | Selection callback |
| `onCreateFolder` | VoidCallback? | No | Create folder action |
| `onItemDropped` | OnItemDropped? | No | Drag & drop callback |
| `onFolderAction` | OnFolderAction? | No | Context menu actions |

**Usage:**
```dart
FolderTreeWidget(
  i18n: widget.i18n,
  selectedPath: ['folder1', 'subfolder'],
  onFolderSelected: (path) {
    setState(() => _currentPath = path);
  },
  onCreateFolder: () => showCreateFolderDialog(),
)
```

**Features:**
- Recursive folder expansion
- Lazy loading of subfolders
- Drag & drop support
- Context menu for folder actions
- Auto-expand selected path

---

## Message Widgets

### MessageBubbleWidget

**File:** `lib/widgets/message_bubble_widget.dart`

Display individual chat messages with rich content support.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `message` | ChatMessage | Yes | Message object |
| `isGroupChat` | bool | No | Group vs DM display |
| `onFileOpen` | VoidCallback? | No | File open callback |
| `onLocationView` | VoidCallback? | No | Location view callback |
| `onDelete` | VoidCallback? | No | Delete callback |
| `onQuote` | VoidCallback? | No | Quote/reply callback |
| `onReact` | Function(String)? | No | Reaction callback |
| `voiceFilePath` | String? | No | Voice file path |
| `canDelete` | bool | No | Permission to delete |

**Features:**
- Text message display
- File attachments
- Voice message playback
- Image display
- Location map preview
- Reaction emoji system (7 reactions)
- Quote/reply preview
- Hide/unhide messages

---

### MessageInputWidget

**File:** `lib/widgets/message_input_widget.dart`

Text input for composing chat messages.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `onSend` | Function(String, String?) | Yes | Send callback (content, filePath) |
| `maxLength` | int | No | Max message length (default: 500) |
| `allowFiles` | bool | No | Enable file attachments |
| `onMicPressed` | VoidCallback? | No | Microphone button callback |
| `quotedMessage` | ChatMessage? | No | Quote/reply context |
| `onClearQuote` | VoidCallback? | No | Clear quote callback |

**Usage:**
```dart
MessageInputWidget(
  onSend: (content, filePath) {
    sendMessage(content, filePath);
  },
  maxLength: 500,
  allowFiles: true,
  onMicPressed: () => showVoiceRecorder(),
  quotedMessage: _replyingTo,
  onClearQuote: () => setState(() => _replyingTo = null),
)
```

**Features:**
- Text input with max length
- File/image attachment
- Quote preview
- Mic button for voice
- Character counter

---

## Services

### LocationService

**File:** `lib/services/location_service.dart`

Find nearest cities and country information from GPS coordinates using the worldcities database (~44,000 cities).

**Initialization:**
```dart
final locationService = LocationService();
await locationService.init();
```

**Methods:**

| Method | Returns | Description |
|--------|---------|-------------|
| `findNearestCity(lat, lng)` | `NearestCityResult?` | Find the single nearest city |
| `findNearestCities(lat, lng, {count})` | `List<NearestCityResult>` | Find N nearest cities (default: 5) |
| `findCityByName(name)` | `CityEntry?` | Search city by name (case-insensitive) |
| `getNearestCityEntry(lat, lng)` | `CityEntry?` | Get full city data for nearest city |
| `detectJurisdiction(lat, lng)` | `JurisdictionInfo?` | Get jurisdiction info for legal docs |
| `calculateDistance(lat1, lng1, lat2, lng2)` | `double` | Distance in km (Haversine formula) |
| `getAllCountries()` | `List<String>` | All unique countries sorted |

**NearestCityResult Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `country` | String | Country name |
| `iso2` | String | ISO 3166-1 alpha-2 code (e.g., "US", "PT") |
| `iso3` | String | ISO 3166-1 alpha-3 code (e.g., "USA", "PRT") |
| `adminName` | String | Region/state/province name |
| `city` | String | City name (ASCII) |
| `capital` | String | "primary", "admin", or empty |
| `distance` | double | Distance in kilometers |
| `folderPath` | String | Sanitized path: Country/Region/City |

**CityEntry Fields:**
All of the above plus: `lat`, `lng`, `population`, `id`

**JurisdictionInfo Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `country` | String | Country name |
| `region` | String? | Region/state/province name |
| `city` | String? | City name |
| `countryCode` | String? | ISO2 country code |
| `fullJurisdiction` | String | Formatted: "Region, Country" or "Country" |

**Usage Examples:**

```dart
// Find nearest city to coordinates
final result = await LocationService().findNearestCity(38.7223, -9.1393);
if (result != null) {
  print('${result.city}, ${result.country} (${result.iso2})');
  print('Distance: ${result.distance.toStringAsFixed(1)} km');
  print('Folder path: ${result.folderPath}');
}

// Find 10 nearest cities
final cities = await LocationService().findNearestCities(
  38.7223, -9.1393,
  count: 10,
);
for (final city in cities) {
  print('${city.city}: ${city.distance.toStringAsFixed(1)} km');
}

// Search city by name
final tokyo = await LocationService().findCityByName('Tokyo');
if (tokyo != null) {
  print('${tokyo.city}, ${tokyo.country}');
  print('Population: ${tokyo.population}');
  print('Coordinates: ${tokyo.lat}, ${tokyo.lng}');
}

// Calculate distance between two points
final distance = LocationService().calculateDistance(
  38.7223, -9.1393,  // Lisbon
  40.4168, -3.7038,  // Madrid
);
print('Distance: ${distance.toStringAsFixed(0)} km');

// Detect jurisdiction for legal documents
final jurisdiction = await LocationService().detectJurisdiction(38.7223, -9.1393);
if (jurisdiction != null) {
  print('Jurisdiction: ${jurisdiction.fullJurisdiction}');
  print('Country code: ${jurisdiction.countryCode}');
}
```

**Database:** `assets/worldcities.csv` (SimpleMaps World Cities Database)

---

## Summary Table

| Component | Location | Type | Main Use |
|-----------|----------|------|----------|
| UserPickerWidget | widgets/ | Picker | Select users from devices |
| CurrencyPickerWidget | widgets/wallet/ | Picker | Select currencies |
| TypeSelectorWidget | widgets/inventory/ | Picker | Select inventory types |
| PhotoViewerPage | pages/ | Viewer | Image & video gallery |
| DocumentViewerEditorPage | pages/ | Viewer | PDF, text, markdown |
| LocationPickerPage | pages/ | Picker | Map location selection |
| ContractDocumentPage | pages/ | Viewer | Markdown document |
| VoicePlayerWidget | widgets/ | Player | Voice messages |
| MusicPlayerWidget | widgets/ | Player | Music tracks |
| VoiceRecorderWidget | widgets/ | Recorder | Record voice |
| NewChannelDialog | widgets/ | Dialog | Create chat channels |
| NewThreadDialog | widgets/ | Dialog | Create forum threads |
| CallsignSelectorWidget | widgets/ | Selector | Profile switching |
| ProfileSwitcher | widgets/ | Selector | App bar profile |
| FolderTreeWidget | widgets/inventory/ | Tree | Folder navigation |
| MessageBubbleWidget | widgets/ | Message | Chat bubbles |
| MessageInputWidget | widgets/ | Input | Message composer |
| LocationService | services/ | Service | City lookup from coordinates |
