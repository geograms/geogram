# Nostr Data Format (NDF) Specification

**Version:** 1.0.0  
**Status:** Draft  
**Extension:** `.ndf`

## Overview

NDF is a ZIP-based container format designed for offline-first, mesh-network-friendly document exchange. It supports spreadsheets, rich text documents, presentations, forms, voice memos, web snapshots, and meetings with embedded binary assets, NOSTR-signed collaboration metadata, and social feedback.

## Design Principles

1. **Offline-first** - All content self-contained, no external dependencies
2. **Mesh-friendly** - Small chunks, CRDT-compatible, partial sync support
3. **Human-readable** - JSON for all structured data
4. **Cryptographically signed** - NOSTR signatures for authorship verification
5. **Extensible** - Custom content types and metadata
6. **Social** - Built-in feedback, comments, reactions

---

## Archive Structure

```
document.ndf (ZIP archive)
│
├── ndf.json                    # Root metadata (REQUIRED - identifies as NDF)
├── permissions.json            # Ownership, permissions & signatures (REQUIRED)
├── index.html                  # Self-rendering HTML viewer (RECOMMENDED)
├── content/
│   ├── main.json               # Primary content (type-specific)
│   ├── sheets/                 # For spreadsheets: one file per sheet
│   │   ├── sheet-001.json
│   │   └── sheet-002.json
│   ├── slides/                 # For presentations: one file per slide
│   │   ├── slide-001.json
│   │   └── slide-002.json
│   ├── sections/               # For documents: optional chunking
│   │   └── section-001.json
│   └── forms/                  # For forms: form definitions and responses
│       ├── form-001.json
│       └── responses/
│           ├── resp-001.json
│           └── resp-002.json
│
├── assets/
│   ├── logo.png                # Document branding logo (OPTIONAL)
│   ├── images/
│   │   ├── img-001.png
│   │   └── img-002.jpg
│   ├── audio/
│   │   └── clip-001.opus
│   ├── video/
│   │   └── vid-001.mp4
│   ├── fonts/
│   │   └── custom-font.woff2
│   └── thumbnails/
│       └── preview.png         # Document preview thumbnail (OPTIONAL)
│
├── social/
│   ├── reactions.json          # Likes, emoticons per element (signed)
│   ├── comments.json           # Threaded comments (signed)
│   └── annotations.json        # Highlights, marks, drawings (signed)
│
├── history/
│   ├── changes.json            # Edit history with signatures
│   └── snapshots/              # Optional point-in-time snapshots
│       └── snapshot-001.json
│
├── metrics/
│   ├── analytics.json          # View counts, read time, etc.
│   └── sync.json               # Sync state for mesh distribution
│
└── extensions/                 # Optional custom extensions
    └── geogram-mesh/
        └── distribution.json
```

---

## Root Metadata (ndf.json)

This file **must exist at the root** of the archive. Its presence identifies the file as NDF format. It contains document metadata only - ownership and permissions are in `permissions.json`.

```json
{
  "ndf": "1.0.0",
  "type": "spreadsheet",
  "id": "ndf-uuid-here",
  "title": "Q4 Sales Report",
  "description": "Quarterly sales analysis",
  "logo": "asset://logo.png",
  "thumbnail": "asset://thumbnails/preview.png",
  "language": "en",
  "created": "2025-01-27T10:30:00Z",
  "modified": "2025-01-27T14:22:00Z",
  "revision": 12,
  "tags": ["sales", "quarterly"],
  "content_hash": "sha256:abc123...",
  "required_features": ["formulas", "forms"],
  "extensions": ["geogram-mesh"]
}
```

### Optional Metadata Fields

| Field | Type | Description |
|-------|------|-------------|
| `description` | string | Brief description of the document content |
| `logo` | string | Asset reference to embedded logo (e.g., "asset://logo.png") |
| `thumbnail` | string | Asset reference to document preview image (e.g., "asset://thumbnails/preview.png") |
| `language` | string | ISO 639-1 language code |
| `tags` | array | List of keywords for categorization |
| `content_hash` | string | SHA256 hash of document content |
| `required_features` | array | Features required to render this document |
| `extensions` | array | Custom extensions used in this document |

### Branding Assets

NDF documents support embedded branding assets for workspace/organization identity and document previews.

#### Logo

The logo is stored at `assets/logo.{ext}` (e.g., `assets/logo.png`) and referenced in metadata as:
```json
{
  "logo": "asset://logo.png"
}
```

**Usage:**
- Displayed in document cards within workspace grids
- Inherited from workspace when creating new documents
- Can be applied to all documents in a workspace at once
- Recommended size: 512x512 pixels or smaller

#### Thumbnail

The thumbnail is stored at `assets/thumbnails/preview.png` and referenced in metadata as:
```json
{
  "thumbnail": "asset://thumbnails/preview.png"
}
```

**Usage:**
- Displayed as the background of document cards in workspace grids
- Provides visual preview of document content
- Recommended size: 800x600 pixels or smaller (16:9 or 4:3 aspect ratio)

---

## Permissions & Ownership (permissions.json)

This file **must exist at the root** of the archive. It defines document ownership, access control, and is cryptographically signed by owners to prevent tampering.

### Structure

```json
{
  "schema": "ndf-permissions-1.0",
  "document_id": "ndf-uuid-here",
  
  "owners": [
    {
      "npub": "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6",
      "name": "João Brito",
      "callsign": "CT1ABC",
      "role": "creator",
      "added_at": 1706340000,
      "added_by": null
    },
    {
      "npub": "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m",
      "name": "Maria Santos",
      "callsign": "CT2XYZ",
      "role": "co-owner",
      "added_at": 1706350000,
      "added_by": "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    }
  ],
  
  "access": {
    "view": {
      "type": "public"
    },
    "comment": {
      "type": "public"
    },
    "react": {
      "type": "public"
    },
    "edit": {
      "type": "allowlist",
      "npubs": [
        "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6",
        "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m",
        "npub1298d4x02gmremhvj5xxyrjvt35wa9u6q5ncj9llvrmk5p6qcwvyqcadmmc"
      ]
    },
    "form_submit": {
      "type": "public"
    },
    "admin": {
      "type": "owners_only"
    }
  },
  
  "restrictions": {
    "allow_anonymous_view": true,
    "allow_anonymous_comment": false,
    "require_signature_for_changes": true,
    "require_signature_for_comments": true,
    "require_signature_for_reactions": true,
    "require_signature_for_form_submit": true,
    "max_file_size_mb": 50,
    "allowed_asset_types": ["image/*", "audio/*", "video/*", "application/pdf"],
    "expiry": null,
    "revoked": false
  },
  
  "delegation": {
    "allow_edit_delegation": true,
    "delegation_depth": 1,
    "delegations": [
      {
        "from": "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6",
        "to": "npub1c06nhuslxufzpcgd8ss8g4r07yjfpg8ysv8ezq7avm72swx8j4ksfy49hr",
        "permissions": ["edit", "comment"],
        "expires_at": 1707000000,
        "created_at": 1706360000,
        "sig": "delegation_signature_hex..."
      }
    ]
  },
  
  "audit": {
    "created_at": 1706340000,
    "last_modified_at": 1706360000,
    "modification_count": 3
  },
  
  "integrity": {
    "content_hash": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "hash_algorithm": "sha256",
    "hash_scope": "permissions_content"
  },
  
  "signatures": [
    {
      "npub": "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6",
      "created_at": 1706360000,
      "kind": 1115,
      "content_hash": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "sig": "owner1_schnorr_signature_hex..."
    },
    {
      "npub": "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m",
      "created_at": 1706360100,
      "kind": 1115,
      "content_hash": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "sig": "owner2_schnorr_signature_hex..."
    }
  ]
}
```

### Access Control Types

| Type | Description |
|------|-------------|
| `public` | Anyone can perform this action |
| `owners_only` | Only npubs listed in `owners` array |
| `allowlist` | Only npubs listed in `npubs` array |
| `denylist` | Everyone except npubs in `npubs` array |
| `delegated` | Check delegation chain |
| `none` | Action is disabled |

### Permission Actions

| Action | Description |
|--------|-------------|
| `view` | Read document content |
| `comment` | Add comments to elements |
| `react` | Add reactions (likes, emoji) |
| `edit` | Modify document content |
| `form_submit` | Submit form responses |
| `admin` | Modify permissions, add/remove owners |

### Owner Roles

| Role | Can Edit | Can Admin | Can Add Owners | Can Remove Self |
|------|----------|-----------|----------------|-----------------|
| `creator` | ✅ | ✅ | ✅ | ❌ (must transfer first) |
| `co-owner` | ✅ | ✅ | ✅ | ✅ |
| `admin` | ✅ | ✅ | ❌ | ✅ |

### Integrity Verification

The `integrity.content_hash` is computed over the entire `permissions.json` **excluding** the `integrity` and `signatures` fields:

```
1. Parse permissions.json
2. Remove "integrity" and "signatures" fields
3. Serialize to canonical JSON (sorted keys, no whitespace)
4. Compute SHA256 hash
5. Compare with integrity.content_hash
```

### Signature Verification

Each signature in `signatures` array must be verified:

```
1. Verify the signer's npub is in the "owners" array
2. Verify content_hash matches integrity.content_hash
3. Construct NOSTR event: [0, npub, created_at, 1115, [], content_hash]
4. Verify Schnorr signature against SHA256 of serialized event
```

**Minimum Signature Requirements:**
- New document: At least 1 owner signature (creator)
- Permission changes: Majority of owners must sign (>50%)
- Adding new owner: All existing owners must sign
- Removing owner: All remaining owners must sign

### Delegation (NIP-26 Compatible)

Owners can delegate permissions to other npubs temporarily:

```json
{
  "from": "npub1owner...",
  "to": "npub1delegate...",
  "permissions": ["edit", "comment"],
  "expires_at": 1707000000,
  "conditions": {
    "sheets_only": ["sheet-001"],
    "max_changes": 10
  },
  "created_at": 1706360000,
  "sig": "delegation_signature_hex..."
}
```

The delegation signature signs: `ndf:delegate:<to_npub>:<permissions>:<expires_at>:<conditions_hash>`

---

## NOSTR Signing Standard

All signed content in NDF follows this structure:

```json
{
  "npub": "npub1...",
  "created_at": 1706356200,
  "content": { ... },
  "sig": "hex_signature_64_bytes"
}
```

### Signing Process (NIP-01 Compatible)

```
1. Serialize content to canonical JSON (sorted keys, no whitespace)
2. Create event array: [0, npub, created_at, kind, [], content_hash]
3. SHA256 hash the serialized array
4. Sign hash with Schnorr (secp256k1)
5. Encode signature as hex
```

### Event Kinds for NDF

| Kind | Description |
|------|-------------|
| 1 | Document metadata signature (ndf.json) |
| 7 | Reaction |
| 1111 | Comment |
| 1112 | Annotation |
| 1113 | Change/Edit |
| 1114 | Form response |
| 1115 | Permissions signature |
| 1116 | Delegation |

---

## Content Types

### Spreadsheet (type: "spreadsheet")

#### content/main.json

```json
{
  "type": "spreadsheet",
  "active_sheet": "sheet-001",
  "sheets": ["sheet-001", "sheet-002"],
  "named_ranges": {
    "SalesData": { "sheet": "sheet-001", "range": "A1:D100" }
  },
  "global_styles": {
    "default": {
      "font": { "family": "Inter", "size": 11 },
      "alignment": { "h": "left", "v": "middle" }
    }
  }
}
```

#### content/sheets/sheet-001.json

```json
{
  "id": "sheet-001",
  "name": "Sales Data",
  "index": 0,
  "dimensions": {
    "rows": 1000,
    "cols": 26,
    "frozen_rows": 1,
    "frozen_cols": 1
  },
  "columns": {
    "0": { "width": 120, "hidden": false },
    "1": { "width": 80 },
    "2": { "width": 100 }
  },
  "rows": {
    "0": { "height": 28, "style": "header" }
  },
  "cells": {
    "0:0": { "v": "Product", "s": "header" },
    "0:1": { "v": "Price", "s": "header" },
    "0:2": { "v": "Quantity", "s": "header" },
    "0:3": { "v": "Total", "s": "header" },
    "1:0": { "v": "Widget A" },
    "1:1": { "v": 29.99, "t": "number", "f": "#,##0.00" },
    "1:2": { "v": 150, "t": "number" },
    "1:3": { "formula": "=B2*C2", "v": 4498.5, "t": "number", "f": "#,##0.00" }
  },
  "merges": [
    { "start": "0:0", "end": "0:1" }
  ],
  "styles": {
    "header": {
      "font": { "bold": true, "size": 12 },
      "fill": { "color": "#4A90D9" },
      "color": "#FFFFFF"
    }
  },
  "validation": [
    {
      "range": "B2:B100",
      "rule": { "type": "number", "min": 0 },
      "message": "Price must be positive"
    }
  ]
}
```

### Cell Value Types

| Type | Code | Example |
|------|------|---------|
| String | `"t": "string"` | `{ "v": "Hello" }` |
| Number | `"t": "number"` | `{ "v": 42.5, "f": "#,##0.00" }` |
| Boolean | `"t": "boolean"` | `{ "v": true }` |
| Date | `"t": "date"` | `{ "v": "2025-01-27", "f": "YYYY-MM-DD" }` |
| DateTime | `"t": "datetime"` | `{ "v": "2025-01-27T14:30:00Z" }` |
| Error | `"t": "error"` | `{ "v": "#DIV/0!" }` |
| Formula | (has `formula` key) | `{ "formula": "=SUM(A1:A10)", "v": 100 }` |
| Rich Text | `"t": "rich"` | `{ "v": [{"t": "Hello "}, {"t": "World", "b": true}] }` |
| Asset | `"t": "asset"` | `{ "v": "asset://images/img-001.png" }` |

---

### Rich Text Document (type: "document")

#### content/main.json

```json
{
  "type": "document",
  "schema": "ndf-richtext-1.0",
  "content": [
    {
      "type": "heading",
      "level": 1,
      "id": "h-001",
      "content": [{ "type": "text", "value": "Project Proposal" }]
    },
    {
      "type": "paragraph",
      "id": "p-001",
      "content": [
        { "type": "text", "value": "This document outlines the " },
        { "type": "text", "value": "Geogram", "marks": ["bold"] },
        { "type": "text", "value": " mesh communication project." }
      ]
    },
    {
      "type": "image",
      "id": "img-001",
      "src": "asset://images/architecture.png",
      "alt": "System Architecture",
      "width": 600,
      "caption": "Figure 1: Geogram Architecture"
    },
    {
      "type": "table",
      "id": "tbl-001",
      "rows": [
        { "cells": [{ "content": "Feature" }, { "content": "Status" }], "header": true },
        { "cells": [{ "content": "BLE Mesh" }, { "content": "Complete" }] },
        { "cells": [{ "content": "APRS" }, { "content": "In Progress" }] }
      ]
    },
    {
      "type": "list",
      "id": "list-001",
      "ordered": true,
      "items": [
        { "content": [{ "type": "text", "value": "First item" }] },
        { 
          "content": [{ "type": "text", "value": "Second item with sublist" }],
          "children": {
            "ordered": false,
            "items": [
              { "content": [{ "type": "text", "value": "Sub-item A" }] }
            ]
          }
        }
      ]
    },
    {
      "type": "code",
      "id": "code-001",
      "language": "dart",
      "content": "void main() {\n  print('Hello Geogram!');\n}"
    },
    {
      "type": "form_embed",
      "id": "form-embed-001",
      "form_ref": "form-001",
      "display": "inline"
    }
  ],
  "styles": {
    "page": {
      "size": "A4",
      "margins": { "top": 72, "bottom": 72, "left": 72, "right": 72 }
    }
  }
}
```

### Text Marks (Inline Formatting)

```json
{
  "type": "text",
  "value": "formatted text",
  "marks": ["bold", "italic"],
  "attrs": {
    "color": "#FF0000",
    "background": "#FFFF00",
    "link": "https://geogram.app",
    "font_size": 14
  }
}
```

Available marks: `bold`, `italic`, `underline`, `strikethrough`, `code`, `superscript`, `subscript`

---

### Presentation (type: "presentation")

#### content/main.json

```json
{
  "type": "presentation",
  "schema": "ndf-slides-1.0",
  "aspect_ratio": "16:9",
  "dimensions": { "width": 1920, "height": 1080 },
  "slides": ["slide-001", "slide-002", "slide-003"],
  "theme": {
    "colors": {
      "primary": "#1E3A5F",
      "secondary": "#4A90D9",
      "accent": "#F5A623",
      "background": "#FFFFFF",
      "text": "#333333"
    },
    "fonts": {
      "heading": { "family": "Montserrat", "weight": 700 },
      "body": { "family": "Inter", "weight": 400 }
    }
  },
  "transitions": {
    "default": { "type": "fade", "duration": 300 }
  }
}
```

#### content/slides/slide-001.json

```json
{
  "id": "slide-001",
  "index": 0,
  "layout": "title",
  "background": {
    "type": "solid",
    "color": "#1E3A5F"
  },
  "elements": [
    {
      "id": "el-001",
      "type": "text",
      "position": { "x": "10%", "y": "40%", "w": "80%", "h": "15%" },
      "content": [{ "type": "text", "value": "Geogram" }],
      "style": { "color": "#FFFFFF", "font_size": 72, "align": "center" }
    },
    {
      "id": "el-002",
      "type": "text",
      "position": { "x": "10%", "y": "58%", "w": "80%", "h": "10%" },
      "content": [{ "type": "text", "value": "Internet Without Internet" }],
      "style": { "color": "#AACCEE", "font_size": 32, "align": "center" }
    }
  ],
  "notes": "Welcome slide - introduce the concept",
  "transition": { "type": "fade", "duration": 400 }
}
```

---

### Forms (type: "form")

Forms can be standalone documents or embedded within other document types.

#### content/forms/form-001.json

```json
{
  "id": "form-001",
  "schema": "ndf-form-1.0",
  "title": "Emergency Situation Report",
  "description": "Report field conditions to coordination center",
  "version": 2,
  "created": "2025-01-27T10:00:00Z",
  "modified": "2025-01-27T12:00:00Z",
  
  "settings": {
    "allow_anonymous": false,
    "require_signature": true,
    "multiple_submissions": true,
    "editable_after_submit": false,
    "notify_on_submit": ["npub1coordinator..."],
    "close_after": null,
    "max_responses": null
  },
  
  "fields": [
    {
      "id": "field-001",
      "type": "text",
      "label": "Reporter Name",
      "required": true,
      "placeholder": "Your name or callsign",
      "validation": {
        "min_length": 2,
        "max_length": 100
      }
    },
    {
      "id": "field-002",
      "type": "select",
      "label": "Situation Type",
      "required": true,
      "options": [
        { "value": "medical", "label": "Medical Emergency" },
        { "value": "fire", "label": "Fire" },
        { "value": "flood", "label": "Flooding" },
        { "value": "infrastructure", "label": "Infrastructure Damage" },
        { "value": "supplies", "label": "Supply Shortage" },
        { "value": "other", "label": "Other" }
      ],
      "default": null
    },
    {
      "id": "field-003",
      "type": "select_multiple",
      "label": "Resources Needed",
      "required": false,
      "options": [
        { "value": "water", "label": "Water" },
        { "value": "food", "label": "Food" },
        { "value": "medical", "label": "Medical Supplies" },
        { "value": "shelter", "label": "Shelter" },
        { "value": "transport", "label": "Transportation" },
        { "value": "comms", "label": "Communications" }
      ]
    },
    {
      "id": "field-004",
      "type": "number",
      "label": "Number of People Affected",
      "required": true,
      "validation": {
        "min": 0,
        "max": 100000,
        "integer": true
      },
      "default": 0
    },
    {
      "id": "field-005",
      "type": "textarea",
      "label": "Situation Description",
      "required": true,
      "placeholder": "Describe the current situation...",
      "validation": {
        "min_length": 20,
        "max_length": 2000
      },
      "rows": 5
    },
    {
      "id": "field-006",
      "type": "location",
      "label": "Location",
      "required": true,
      "format": "coordinates",
      "allow_manual": true
    },
    {
      "id": "field-007",
      "type": "datetime",
      "label": "When did this occur?",
      "required": true,
      "default": "now",
      "validation": {
        "max": "now"
      }
    },
    {
      "id": "field-008",
      "type": "rating",
      "label": "Severity (1-5)",
      "required": true,
      "min": 1,
      "max": 5,
      "labels": {
        "1": "Minor",
        "3": "Moderate", 
        "5": "Critical"
      }
    },
    {
      "id": "field-009",
      "type": "file",
      "label": "Photos/Evidence",
      "required": false,
      "accept": ["image/*"],
      "max_files": 5,
      "max_size_mb": 10
    },
    {
      "id": "field-010",
      "type": "checkbox",
      "label": "Immediate assistance required",
      "default": false
    },
    {
      "id": "field-011",
      "type": "signature",
      "label": "Digital Signature",
      "required": true,
      "description": "Sign with your NOSTR key to verify this report"
    }
  ],
  
  "layout": {
    "type": "sections",
    "sections": [
      {
        "title": "Reporter Information",
        "fields": ["field-001"]
      },
      {
        "title": "Situation Details",
        "fields": ["field-002", "field-003", "field-004", "field-005"]
      },
      {
        "title": "Location & Time",
        "fields": ["field-006", "field-007"]
      },
      {
        "title": "Assessment",
        "fields": ["field-008", "field-009", "field-010"]
      },
      {
        "title": "Verification",
        "fields": ["field-011"]
      }
    ]
  },
  
  "logic": [
    {
      "condition": { "field": "field-002", "equals": "other" },
      "action": { "show": "field-005", "required": true }
    },
    {
      "condition": { "field": "field-010", "equals": true },
      "action": { "set": { "field": "field-008", "min": 4 } }
    }
  ]
}
```

### Form Field Types

| Type | Description | Attributes |
|------|-------------|------------|
| `text` | Single line text | `placeholder`, `validation.min_length`, `validation.max_length`, `validation.pattern` |
| `textarea` | Multi-line text | `rows`, `placeholder`, `validation.min_length`, `validation.max_length` |
| `number` | Numeric input | `validation.min`, `validation.max`, `validation.integer`, `step` |
| `select` | Single choice dropdown | `options[]`, `default` |
| `select_multiple` | Multiple choice | `options[]`, `validation.min_selected`, `validation.max_selected` |
| `radio` | Single choice buttons | `options[]`, `layout` (horizontal/vertical) |
| `checkbox` | Boolean toggle | `default` |
| `checkbox_group` | Multiple toggles | `options[]` |
| `date` | Date picker | `validation.min`, `validation.max`, `format` |
| `time` | Time picker | `format` (12h/24h) |
| `datetime` | Date and time | `validation.min`, `validation.max` |
| `location` | GPS coordinates | `format`, `allow_manual`, `map_picker` |
| `file` | File upload | `accept[]`, `max_files`, `max_size_mb` |
| `image` | Image upload | `accept[]`, `max_files`, `max_size_mb`, `capture` (camera) |
| `rating` | Star/numeric rating | `min`, `max`, `labels{}` |
| `scale` | Linear scale | `min`, `max`, `min_label`, `max_label` |
| `signature` | NOSTR signature | `description` |
| `section` | Visual separator | `title`, `description` |
| `hidden` | Hidden field | `value` |

---

### Form Response (Signed)

#### content/forms/responses/resp-001.json

```json
{
  "id": "resp-001",
  "form_id": "form-001",
  "form_version": 2,
  "submitted_at": "2025-01-27T14:30:00Z",
  
  "responses": {
    "field-001": "CT1ABC - João",
    "field-002": "flood",
    "field-003": ["water", "medical", "transport"],
    "field-004": 45,
    "field-005": "Main road flooded approximately 50cm deep. Several houses affected. Elderly residents need evacuation assistance. Access from north side only.",
    "field-006": {
      "lat": 38.7223,
      "lng": -9.1393,
      "accuracy": 10,
      "altitude": 45
    },
    "field-007": "2025-01-27T13:45:00Z",
    "field-008": 4,
    "field-009": [
      { "asset": "asset://images/flood-001.jpg", "size": 245000 },
      { "asset": "asset://images/flood-002.jpg", "size": 312000 }
    ],
    "field-010": true
  },
  
  "metadata": {
    "device": "Android/Geogram 2.1.0",
    "offline": true,
    "synced_at": "2025-01-27T15:00:00Z"
  },
  
  "signature": {
    "npub": "npub1reporter...",
    "created_at": 1706365800,
    "kind": 1114,
    "sig": "sig_hex_here..."
  }
}
```

---

## Social Features (All Signed)

### social/reactions.json

```json
{
  "schema": "ndf-reactions-1.0",
  "reactions": [
    {
      "id": "react-001",
      "target": {
        "type": "document"
      },
      "reaction": "+",
      "npub": "npub1abc...",
      "created_at": 1706356200,
      "kind": 7,
      "sig": "sig_hex..."
    },
    {
      "id": "react-002",
      "target": {
        "type": "element",
        "ref": "p-001"
      },
      "reaction": "🔥",
      "npub": "npub1xyz...",
      "created_at": 1706356500,
      "kind": 7,
      "sig": "sig_hex..."
    },
    {
      "id": "react-003",
      "target": {
        "type": "cell",
        "sheet": "sheet-001",
        "cell": "5:3"
      },
      "reaction": "⚠️",
      "note": "This needs verification",
      "npub": "npub1def...",
      "created_at": 1706357000,
      "kind": 7,
      "sig": "sig_hex..."
    },
    {
      "id": "react-004",
      "target": {
        "type": "form_response",
        "ref": "resp-001"
      },
      "reaction": "✅",
      "note": "Verified - dispatching team",
      "npub": "npub1coordinator...",
      "created_at": 1706366000,
      "kind": 7,
      "sig": "sig_hex..."
    }
  ]
}
```

### Reaction Types

| Reaction | Meaning |
|----------|---------|
| `+` | Like/Upvote |
| `-` | Dislike/Downvote |
| `⭐` | Favorite/Important |
| `✅` | Approved/Verified |
| `❌` | Rejected/Invalid |
| `⚠️` | Warning/Needs attention |
| `❓` | Question/Unclear |
| `👀` | Reviewing |
| Any emoji | Custom reaction |

### social/comments.json

```json
{
  "schema": "ndf-comments-1.0",
  "comments": [
    {
      "id": "comment-001",
      "target": {
        "type": "element",
        "ref": "p-002"
      },
      "parent": null,
      "content": "Should we add more detail here about the mesh protocol?",
      "npub": "npub1abc...",
      "created_at": 1706356200,
      "kind": 1111,
      "sig": "sig_hex..."
    },
    {
      "id": "comment-002",
      "target": {
        "type": "element",
        "ref": "p-002"
      },
      "parent": "comment-001",
      "content": "Agreed, I'll expand this section with a diagram.",
      "npub": "npub1xyz...",
      "created_at": 1706358000,
      "kind": 1111,
      "sig": "sig_hex..."
    },
    {
      "id": "comment-003",
      "target": {
        "type": "cell",
        "sheet": "sheet-001",
        "cell": "3:1"
      },
      "parent": null,
      "content": "First aid kits running low - need resupply by tomorrow",
      "npub": "npub1field...",
      "created_at": 1706360000,
      "kind": 1111,
      "sig": "sig_hex..."
    },
    {
      "id": "comment-004",
      "target": {
        "type": "form_response",
        "ref": "resp-001"
      },
      "parent": null,
      "content": "Team Alpha dispatched. ETA 30 minutes.",
      "npub": "npub1coordinator...",
      "created_at": 1706366500,
      "kind": 1111,
      "sig": "sig_hex..."
    }
  ]
}
```

### social/annotations.json

```json
{
  "schema": "ndf-annotations-1.0",
  "annotations": [
    {
      "id": "ann-001",
      "type": "highlight",
      "target": {
        "type": "text_range",
        "element": "p-001",
        "start": 10,
        "end": 25
      },
      "color": "#FFFF00",
      "note": "Key concept - emphasize in presentation",
      "npub": "npub1abc...",
      "created_at": 1706356200,
      "kind": 1112,
      "sig": "sig_hex..."
    },
    {
      "id": "ann-002",
      "type": "drawing",
      "target": {
        "type": "slide",
        "ref": "slide-002"
      },
      "data": {
        "tool": "arrow",
        "color": "#FF0000",
        "width": 3,
        "points": [[100, 200], [300, 150]]
      },
      "npub": "npub1xyz...",
      "created_at": 1706358000,
      "kind": 1112,
      "sig": "sig_hex..."
    }
  ]
}
```

---

## Edit History (Signed)

### history/changes.json

```json
{
  "schema": "ndf-history-1.0",
  "changes": [
    {
      "id": "change-001",
      "revision": 1,
      "type": "create",
      "description": "Initial document creation",
      "npub": "npub1abc...",
      "created_at": 1706340000,
      "kind": 1113,
      "sig": "sig_hex..."
    },
    {
      "id": "change-002",
      "revision": 2,
      "type": "cell_update",
      "target": {
        "sheet": "sheet-001",
        "cell": "1:1"
      },
      "previous": { "v": 25.99 },
      "current": { "v": 29.99 },
      "npub": "npub1abc...",
      "created_at": 1706345000,
      "kind": 1113,
      "sig": "sig_hex..."
    },
    {
      "id": "change-003",
      "revision": 3,
      "type": "element_insert",
      "target": {
        "element": "p-003",
        "after": "p-002"
      },
      "content": { "type": "paragraph", "content": [...] },
      "npub": "npub1xyz...",
      "created_at": 1706350000,
      "kind": 1113,
      "sig": "sig_hex..."
    },
    {
      "id": "change-004",
      "revision": 4,
      "type": "form_response_add",
      "target": {
        "form": "form-001",
        "response": "resp-001"
      },
      "npub": "npub1reporter...",
      "created_at": 1706365800,
      "kind": 1113,
      "sig": "sig_hex..."
    }
  ]
}
```

### Change Types

| Type | Description |
|------|-------------|
| `create` | Document created |
| `cell_update` | Spreadsheet cell modified |
| `cell_delete` | Spreadsheet cell cleared |
| `row_insert` | Row added |
| `row_delete` | Row removed |
| `column_insert` | Column added |
| `column_delete` | Column removed |
| `element_insert` | Document element added |
| `element_update` | Document element modified |
| `element_delete` | Document element removed |
| `slide_insert` | Slide added |
| `slide_update` | Slide modified |
| `slide_delete` | Slide removed |
| `slide_reorder` | Slides reordered |
| `form_response_add` | Form submission |
| `form_response_update` | Form response edited |
| `style_update` | Styling changed |
| `metadata_update` | Document metadata changed |

---

## Metrics

### metrics/sync.json

```json
{
  "schema": "ndf-sync-1.0",
  "vector_clock": {
    "npub1abc...": 15,
    "npub1xyz...": 8,
    "npub1def...": 3
  },
  "last_sync": {
    "npub1abc...": "2025-01-27T14:00:00Z",
    "npub1xyz...": "2025-01-27T12:30:00Z"
  },
  "pending_signatures": [
    {
      "id": "change-005",
      "type": "cell_update",
      "awaiting_sig_from": "npub1abc..."
    }
  ],
  "conflicts": [],
  "distribution": {
    "seed_nodes": ["BLE:AA:BB:CC:DD:EE:FF", "APRS:CT1ABC-9"],
    "replicas": 5,
    "last_broadcast": "2025-01-27T14:00:00Z"
  }
}
```

---

## Extensions

### extensions/geogram-mesh/distribution.json

```json
{
  "schema": "geogram-mesh-1.0",
  "distribution": {
    "priority": "high",
    "ttl_hops": 5,
    "ttl_time": 86400,
    "target_replicas": 10,
    "compression": "zstd"
  },
  "chunks": [
    {
      "id": "chunk-001",
      "files": ["ndf.json", "content/main.json"],
      "size": 2048,
      "hash": "sha256:...",
      "priority": 1
    },
    {
      "id": "chunk-002",
      "files": ["content/forms/form-001.json"],
      "size": 1536,
      "priority": 1
    },
    {
      "id": "chunk-003",
      "files": ["content/forms/responses/"],
      "size": 4096,
      "hash": "sha256:...",
      "priority": 2
    }
  ],
  "transport_hints": {
    "ble_friendly": true,
    "max_chunk_size": 512,
    "aprs_summary": "NDF:form:Emergency Report:8 responses"
  }
}
```

---

## Asset References

Assets are referenced using the `asset://` URI scheme:

```
asset://images/photo.png      → assets/images/photo.png
asset://audio/clip.opus       → assets/audio/clip.opus
```

---

## Signature Verification Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    NDF Document                              │
├─────────────────────────────────────────────────────────────┤
│  permissions.json                                            │
│  └── signatures[] ──────────────► Verify: ownership & perms │
│      (multiple owner signatures required)                    │
├─────────────────────────────────────────────────────────────┤
│  ndf.json                                                    │
│  └── (no signature - metadata only, integrity via hash)     │
├─────────────────────────────────────────────────────────────┤
│  social/comments.json                                        │
│  └── comment.sig ───────────────► Verify: comment author    │
├─────────────────────────────────────────────────────────────┤
│  social/reactions.json                                       │
│  └── reaction.sig ──────────────► Verify: reaction author   │
├─────────────────────────────────────────────────────────────┤
│  history/changes.json                                        │
│  └── change.sig ────────────────► Verify: edit author       │
│      + check author in permissions.json edit allowlist       │
├─────────────────────────────────────────────────────────────┤
│  content/forms/responses/*.json                              │
│  └── response.sig ──────────────► Verify: respondent        │
└─────────────────────────────────────────────────────────────┘
```

### Validation Order

1. **permissions.json first** - Verify owner signatures, establish trust anchors
2. **Check document_id match** - `permissions.json.document_id` must match `ndf.json.id`
3. **Verify content** - Check `ndf.json.content_hash` against actual content
4. **Validate actions** - For each signed action, verify signer has permission

---

## Version Compatibility

The `ndf` field in `ndf.json` indicates format version:

| Version | Compatibility |
|---------|--------------|
| `1.0.x` | Fully compatible within minor versions |
| `1.x.0` | Backward compatible, new features optional |
| `x.0.0` | Breaking changes, may require migration |

---

## Security Considerations

1. **Verify signatures** - Always verify signatures before trusting content
2. **Sanitize paths** - Prevent zip slip attacks (../ in paths)
3. **Validate asset references** - Only allow asset:// URIs pointing within archive
4. **Size limits** - Enforce reasonable limits on file sizes
5. **Npub verification** - Cross-reference npubs with known identities
6. **Replay protection** - Check `created_at` timestamps against expected ranges

---

### Meeting (type: "meeting")

Meeting documents archive single-day conference events with recordings and transcriptions.

**Naming convention:** Meeting NDF files use double extensions with a date stamp:
`{title}_{YYYY-MM-DD}.meeting.ndf` — e.g., `roof_2026-03-14.meeting.ndf`

**Archive layout:**
```
ndf.json                                  (NdfDocument, type: meeting)
permissions.json                          (NdfPermission)
content/
  main.json                               (MeetingContent)
  recordings/{recordingId}.json           (MeetingRecording per recording)
assets/
  video/{recordingId}.mp4                 (video files)
  audio/{recordingId}.wav                 (extracted audio, if kept)
  thumbnails/preview.png                  (optional)
```

**content/main.json** (schema: `ndf-meeting-1.0`):
```json
{
  "type": "meeting",
  "id": "meeting-abc123",
  "schema": "ndf-meeting-1.0",
  "title": "Team Standup",
  "version": 1,
  "created": "2026-03-14T10:00:00Z",
  "modified": "2026-03-14T10:45:00Z",
  "room_id": "room-xyz",
  "host_callsign": "alice",
  "local_callsign": "bob",
  "signaling_mode": "station",
  "participants": ["alice", "bob", "carol"],
  "speakers": ["alice", "bob"],
  "recordings": ["rec-001"],
  "tags": ["standup", "2026"],
  "settings": {
    "show_transcriptions": true
  }
}
```

**content/recordings/{recordingId}.json**:
```json
{
  "id": "rec-001",
  "title": "recording_001.mp4",
  "recorded_at": "2026-03-14T10:02:00Z",
  "duration_ms": 2580000,
  "video_file": "video/rec-001.mp4",
  "file_size": 52428800,
  "transcript": {
    "text": "[00:00:12 --> 00:00:18] Hello everyone...",
    "model": "whisper-base",
    "transcribed_at": "2026-03-14T11:00:00Z",
    "segments": [
      {
        "from_ms": 12000,
        "to_ms": 18000,
        "text": "Hello everyone"
      }
    ]
  }
}
```

---

## Reference Implementation Checklist

- [ ] ZIP creation with ndf.json and permissions.json at root
- [ ] permissions.json integrity hash computation
- [ ] Multi-owner signature creation and verification
- [ ] Permission checking for all actions
- [ ] Delegation chain verification
- [ ] NOSTR signature creation and verification
- [ ] Spreadsheet parser/renderer
- [ ] Document parser/renderer
- [ ] Presentation parser/renderer
- [ ] Form builder and renderer
- [ ] Form response collection and signing
- [ ] Meeting archive with recordings and transcription
- [ ] Social features (reactions, comments)
- [ ] Edit history with signatures and permission checks
- [ ] Sync metadata
- [ ] Import from XLSX/DOCX/PPTX
- [ ] Export to XLSX/DOCX/PPTX/PDF

---

## Browser Viewing (index.html)

NDF files can include a self-rendering `index.html` that displays the document in any web browser. This provides a universal viewing experience without requiring specialized software.

### Usage

```bash
# 1. Extract NDF archive
unzip document.ndf -d my-document/

# 2. Start a local HTTP server (required due to browser security)
cd my-document/
python3 -m http.server 8000

# 3. Open in browser
# http://localhost:8000/index.html
```

### Alternative Local Servers

| Runtime | Command |
|---------|---------|
| Python 3 | `python3 -m http.server 8000` |
| Python 2 | `python -m SimpleHTTPServer 8000` |
| Node.js | `npx serve` |
| PHP | `php -S localhost:8000` |
| Busybox | `busybox httpd -p 8000` |
| Deno | `deno run --allow-net --allow-read https://deno.land/std/http/file_server.ts` |

### Why a Local Server is Required

Browsers enforce security restrictions on `file://` URLs that prevent JavaScript from fetching local JSON files. Serving via HTTP (`http://localhost`) bypasses these restrictions safely.

### Viewer Features

The included `index.html` provides:

| Document Type | Rendering |
|---------------|-----------|
| Spreadsheet | Interactive table with sheet tabs, cell formatting, formulas displayed |
| Document | Formatted rich text with headings, lists, code blocks, images, tables |
| Presentation | Slide viewer with navigation, thumbnails, speaker notes, keyboard controls |
| Form | Interactive form preview with all field types, plus response viewer |

Additional features:
- **Header** - Document title, type badge, modification date, revision, tags
- **Permissions bar** - Owner list with verification status
- **Social section** - Comments and reactions from `social/*.json`
- **Dark theme** - Eye-friendly dark color scheme
- **Responsive** - Works on desktop and mobile browsers

### Keyboard Shortcuts (Presentations)

| Key | Action |
|-----|--------|
| `→` or `Space` | Next slide |
| `←` | Previous slide |

### Customization

The `index.html` is self-contained with embedded CSS and JavaScript. To customize:

1. Extract the NDF archive
2. Edit `index.html` (colors in `:root`, layout in CSS, behavior in JS)
3. Re-archive the NDF

The viewer automatically detects document type from `ndf.json` and renders appropriately.
