# Work App - Format Specification

**Version:** 1.0.0
**Status:** Draft
**Document Format:** NDF (Nostr Data Format)

## Overview

The Work app enables users to organize folders as **workspaces** containing NDF documents (spreadsheets, rich text documents, presentations, forms) with sync-based collaboration.

## Key Concepts

### Workspaces

A workspace is a folder containing related NDF documents. Each workspace has:
- Metadata (name, description, owner, collaborators)
- A list of NDF document files
- Sync state for collaboration

### NDF Documents

NDF (Nostr Data Format) is a ZIP-based container format. See `docs/docs/NDF-SPECIFICATION.md` for the full specification.

Supported document types:
- **Spreadsheet** - Cells, formulas, multiple sheets
- **Document** - Rich text with headings, lists, tables, images
- **Presentation** - Slides with elements, themes, transitions
- **Form** - Field definitions and signed responses
- **Voice Memo** - Audio clips with transcriptions
- **Web Snapshot** - Archived web pages with assets
- **Meeting** - Conference recordings with transcriptions

## Data Structure

```
{collection_path}/
├── config.json                    # Collection config (standard Geogram)
├── workspaces/
│   ├── project-alpha/
│   │   ├── workspace.json         # Workspace metadata
│   │   ├── budget.ndf             # Spreadsheet document
│   │   ├── proposal.ndf           # Rich text document
│   │   ├── survey.ndf             # Form document
│   │   └── roof_2026-03-14.meeting.ndf   # Meeting document
│   └── project-beta/
│       └── ...
└── sync/
    └── sync_state.json            # MirrorSync state
```

## workspace.json

```json
{
  "id": "project-alpha",
  "name": "Project Alpha",
  "description": "Q1 2025 planning",
  "created": "2025-01-27T10:00:00Z",
  "modified": "2025-01-28T14:30:00Z",
  "owner_npub": "npub1...",
  "collaborators": [
    {
      "npub": "npub1...",
      "role": "editor",
      "added": "2025-01-27T12:00:00Z",
      "name": "João",
      "callsign": "CT1ABC"
    }
  ],
  "documents": ["budget.ndf", "proposal.ndf", "survey.ndf"]
}
```

### Workspace Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique workspace identifier (URL-safe slug + timestamp) |
| `name` | string | Yes | Display name |
| `description` | string | No | Optional description |
| `created` | ISO 8601 | Yes | Creation timestamp |
| `modified` | ISO 8601 | Yes | Last modification timestamp |
| `owner_npub` | string | Yes | NOSTR public key of owner |
| `collaborators` | array | No | List of collaborators |
| `documents` | array | No | List of NDF filenames |

### Collaborator Roles

| Role | Can Edit | Can View | Can Delete |
|------|----------|----------|------------|
| `editor` | Yes | Yes | No |
| `viewer` | No | Yes | No |

## NDF Document Reference

Each `.ndf` file is a ZIP archive containing:
- `ndf.json` - Document metadata
- `permissions.json` - Access control with NOSTR signatures
- `content/main.json` - Primary content (type-specific)
- `assets/` - Embedded images, audio, video
- `social/` - Comments, reactions, annotations
- `history/` - Edit history with signatures

See `docs/docs/NDF-SPECIFICATION.md` for complete details.

## File Locations

### Source Code

```
lib/work/
├── work.dart                    # Public exports
├── models/
│   ├── workspace.dart           # Workspace model
│   ├── ndf_document.dart        # NDF document model
│   └── ndf_permission.dart      # Permission model
├── pages/
│   ├── work_page.dart           # Main entry (workspace browser)
│   └── workspace_detail_page.dart
└── services/
    ├── ndf_service.dart         # NDF parsing/creation
    └── work_storage_service.dart
```

### Translation Files

```
languages/en_US/work.json
languages/pt_PT/work.json
```

## Implementation Status

### Phase 1: Core Structure (MVP) - DONE
- [x] Create `lib/work/` folder structure
- [x] Add app registration (constants, theme, routing)
- [x] Create WorkPage with workspace list
- [x] Create workspace detail page with document list
- [x] Add translation files (en_US, pt_PT)
- [x] Create this documentation

### Phase 2: NDF Service - Partial
- [x] Basic NDF ZIP archive reading/writing
- [x] Parse ndf.json and permissions.json
- [x] Basic document type detection
- [ ] Asset extraction and referencing

### Phase 3: Spreadsheet Editor - TODO
- [ ] Sheet grid widget with cells
- [ ] Cell value types (string, number, date, formula)
- [ ] Basic cell editing
- [ ] Formula evaluation (basic: SUM, AVERAGE, COUNT)
- [ ] Sheet tabs for multi-sheet documents

### Phase 4: Document Editor - TODO
- [ ] Rich text rendering (headings, paragraphs, lists)
- [ ] Basic text editing with marks (bold, italic)
- [ ] Image embedding from assets
- [ ] Table rendering

### Phase 5: Form Builder - TODO
- [ ] Form field types rendering
- [ ] Form response submission
- [ ] Response viewer with signatures

### Phase 6: Collaboration - TODO
- [ ] Integrate MirrorSyncService for workspace sync
- [ ] NOSTR signature for changes
- [ ] Conflict detection (show warnings)

## Dependencies

Existing packages used:
- `archive` - ZIP handling for NDF files
- NOSTR utilities from `lib/util/nostr_crypto.dart`
- `MirrorSyncService` for sync-based collaboration

Future packages to consider:
- `flutter_quill` - Rich text editing
- Custom spreadsheet grid implementation

## Verification Checklist

1. Add Work app from Apps UI panel
2. Create a workspace named "Test Project"
3. Create a new spreadsheet document
4. Verify NDF file is created with correct structure
5. Switch language to pt_PT and verify translations
