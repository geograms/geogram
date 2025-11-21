# Geogram Forum Format Specification

## Overview

Geogram forums use a text-based file format for storing threaded discussions. Each forum is stored as a collection folder containing thread files and their attachments.

## Forum Structure

```
collection_name/
├── [category_name]/
│   ├── thread_title.txt
│   ├── another_thread.txt
│   └── files/
│       ├── {sha1}_{filename1}
│       └── {sha1}_{filename2}
└── [another_category]/
    └── ...
```

## Thread File Format

### Header Format (6 lines)

```
# THREAD: Thread Title

AUTHOR: CALLSIGN
CREATED: YYYY-MM-DD HH:MM_ss
CATEGORY: category_name

```

The header consists of exactly 6 lines:
1. Thread title line starting with `# THREAD: `
2. Blank line
3. Author line starting with `AUTHOR: `
4. Creation timestamp starting with `CREATED: `
5. Category name starting with `CATEGORY: `
6. Blank line

### Original Post

The original post content follows the header directly, without a post marker:

```
This is the original post content.
It can span multiple lines.
--> file: {sha1}_{filename}
--> lat: 37.7749
--> lon: -122.4194
--> npub: npub1...
--> signature: hex_signature
```

### Reply Posts

Reply posts use the following format:

```
> YYYY-MM-DD HH:MM_ss -- CALLSIGN
Reply content goes here.
Can be multiple lines.
--> metadata_key: metadata_value
--> signature: hex_signature
```

## Post Metadata

Metadata is specified using the `--> key: value` format. Common metadata keys:

- `file`: Attached file (SHA1-based naming, see File Attachments section)
- `lat`: Latitude coordinate
- `lon`: Longitude coordinate
- `quote`: Timestamp of quoted message
- `Poll`: Poll question
- `npub`: NOSTR public key (npub format)
- `signature`: NOSTR signature (must be last if present)

## File Attachments

### SHA1-Based File Naming

To prevent file overwrites and ensure uniqueness, all uploaded files are automatically renamed using their SHA1 hash:

**Storage Format**: `{sha1_hash}_{original_filename}`

**Example**:
- Original file: `document.pdf`
- SHA1 hash: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- Stored as: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855_document.pdf`
- Displayed as: `document.pdf` (UI shows only original filename)

### Benefits

1. **Prevents Overwrites**: Even if multiple users upload files with the same name, each file's unique content produces a different SHA1 hash
2. **Deduplication**: Identical files (same content) automatically share the same storage location
3. **Content Verification**: SHA1 hash serves as an integrity check for downloaded files
4. **User-Friendly**: UI displays only the original filename, keeping the SHA1 hash transparent to users

### File Location

All thread attachments are stored in the `files/` subdirectory within each category:

```
[category_name]/
├── thread1.txt
├── thread2.txt
└── files/
    ├── {sha1}_photo.jpg
    ├── {sha1}_document.pdf
    └── {sha1}_data.csv
```

### File Metadata in Posts

In post metadata, the file is referenced by its full SHA1-prefixed name:

```
--> file: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855_document.pdf
```

The UI automatically extracts and displays only the original filename portion.

## Timestamp Format

Timestamps use the format: `YYYY-MM-DD HH:MM_ss`

Example: `2025-11-20 14:30_45`

Note the underscore before seconds.

## Admin Operations

### Forum Creator (Admin)

The admin is identified by their npub (NOSTR public key). Only the forum creator can:

- Create new categories
- Rename existing categories
- Delete categories
- Manage forum structure

### Category Management

Categories are subdirectories within the collection folder. Category names must be valid directory names.

## NOSTR Integration

### Signatures

Posts can be signed using NOSTR keys:

1. The `npub` metadata contains the author's NOSTR public key
2. The `signature` metadata contains the cryptographic signature
3. Signature must always be the last metadata line
4. Signed posts display a verification badge in the UI

### Verification

Future implementations will verify signatures against the message content to ensure authenticity.

## Character Encoding

All forum files use UTF-8 encoding.

## Line Endings

Files use Unix-style line endings (`\n`).

## Maximum Lengths

- Thread title: 255 characters
- Category name: 255 characters (filesystem limit)
- Original filename: 100 characters (truncated if longer, extension preserved)
- Post content: No strict limit
- Metadata values: No strict limit

## Parsing Rules

1. Thread files must start with `# THREAD: ` on the first line
2. Header must be exactly 6 lines (including blank lines)
3. Original post content starts at line 7
4. Reply posts start with `> ` followed by timestamp and author
5. Metadata lines start with `--> `
6. Signature, if present, must be the last metadata line
7. Empty lines between posts are ignored
8. Content preserves original formatting including whitespace

## Example Thread File

```
# THREAD: Welcome to the Forum

AUTHOR: CR7BBQ
CREATED: 2025-11-20 14:30_45
CATEGORY: general

This is the original post welcoming everyone!
Check out this attached file.
--> file: a1b2c3d4e5f6789012345678901234567890abcd_welcome.pdf
--> npub: npub1abc123...
--> signature: 0123456789abcdef...

> 2025-11-20 15:45_12 -- X135AS
Thanks for the welcome!
--> npub: npub1xyz789...
--> signature: fedcba9876543210...

> 2025-11-20 16:20_30 -- CR7BBQ
Glad to have you here!
```

## Implementation Notes

- Thread files are written with immediate flush (`flush: true`) to ensure disk persistence
- File reads handle various error conditions gracefully
- SHA1 calculation is performed on file contents before copying to storage
- Filename length limits prevent filesystem issues
- Invalid timestamps fall back to current time
