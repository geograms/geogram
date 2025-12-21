# Blog Format Specification

**Version**: 1.3
**Last Updated**: 2025-12-16
**Status**: Active

## Table of Contents

- [Overview](#overview)
- [File Organization](#file-organization)
- [Blog Post Format](#blog-post-format)
- [Metadata Field Types](#metadata-field-types)
- [Comments](#comments)
- [File Attachments](#file-attachments)
- [NOSTR Integration](#nostr-integration)
- [Complete Examples](#complete-examples)
- [Parsing Implementation](#parsing-implementation)
- [File Operations](#file-operations)
- [Validation Rules](#validation-rules)
- [Best Practices](#best-practices)
- [Security Considerations](#security-considerations)
- [Web Publishing](#web-publishing)
- [Related Documentation](#related-documentation)
- [Change Log](#change-log)

## Overview

This document specifies the text-based markdown format used for storing blog posts in the Geogram system. The blog collection type provides a publishing platform for creating, organizing, and sharing long-form content with support for drafts, tags, comments, and file attachments.

Blog posts use a human-readable plain text format with structured metadata support and can optionally be cryptographically signed using NOSTR-compatible signatures for authenticity verification.

### Key Features

- **Year-based Organization**: Posts organized in year subdirectories for long-term content management
- **Draft/Published Workflow**: Two-state publishing workflow for content control
- **Markdown Content**: Rich text formatting using standard markdown syntax
- **Tagging System**: Flexible categorization using comma-separated tags
- **Flat Comments**: Reader engagement through chronological comments
- **File Attachments**: SHA1-based file storage with deduplication
- **NOSTR Integration**: Cryptographic identity and signature support
- **Permission System**: Role-based access control (admin, author, reader)

## File Organization

### Directory Structure

Blog posts are stored in a folder-based structure where each post has its own directory containing the post content, comments, and attached files.

```
blog/                          # Blog collection root
├── 2024/
│   ├── 2024-03-15_my-first-post/
│   │   ├── post.md                    # Blog post content
│   │   ├── files/                     # Attached files
│   │   │   ├── {sha1}_{image.jpg}
│   │   │   └── {sha1}_{document.pdf}
│   │   └── comments/                  # Comment files
│   │       ├── 2024-03-15_10-30-45_X13K0G.txt
│   │       └── 2024-03-15_11-15-22_A7BN2P.txt
│   └── 2024-12-20_year-end-review/
│       ├── post.md
│       └── comments/
├── 2025/
│   ├── 2025-01-10_new-year-goals/
│   │   ├── post.md
│   │   └── comments/
│   └── 2025-01-15_tech-tutorial/
│       ├── post.md
│       ├── files/
│       │   └── {sha1}_{attachment.pdf}
│       └── comments/
├── collection.js              # Collection metadata
└── extra/
    ├── security.json          # Admin/moderator settings
    └── blog_config.json       # Blog-specific configuration (optional)
```

### File Naming Convention

**Pattern**: `YYYY-MM-DD_sanitized-title.md`

**Sanitization Rules**:
1. Convert title to lowercase
2. Replace spaces and underscores with single hyphens
3. Remove all non-alphanumeric characters (except hyphens)
4. Collapse multiple consecutive hyphens into single hyphen
5. Remove leading/trailing hyphens
6. Truncate to 50 characters maximum
7. Prepend date in YYYY-MM-DD format

**Examples**:
```
Title: "My First Blog Post!"
→ 2025-01-15_my-first-blog-post.md

Title: "Tech Tutorial: Getting Started with Geogram"
→ 2025-01-20_tech-tutorial-getting-started-with-geogram.md

Title: "Year-End Review (2024) - Part 1"
→ 2024-12-31_year-end-review-2024-part-1.md

Title: "100% FREE!!! AMAZING Tutorial..."
→ 2025-02-01_100-free-amazing-tutorial.md
```

### Year Subdirectories

- **Purpose**: Organize posts by publication year
- **Format**: `YYYY/` (e.g., `2024/`, `2025/`)
- **Creation**: Automatically created when first post for that year is added
- **Files Subdirectory**: Each year has its own `files/` subdirectory for attachments

### Admin Configuration

The collection admin is identified in `/extra/security.json`:

```json
{
  "admin_npub": "npub1abc123...",
  "created": "2025-01-15 10:00_00"
}
```

## Blog Post Format

### Complete Structure

```
# BLOG: Post Title

AUTHOR: CALLSIGN
CREATED: YYYY-MM-DD HH:MM_ss
EDITED: YYYY-MM-DD HH:MM (optional, only if edited)
DESCRIPTION: Short description (optional)
LOCATION: lat, lon (optional, e.g., 38.736946, -9.142685)
STATUS: draft|published
--> tags: tag1,tag2,tag3

Post content goes here.
Can span multiple paragraphs.
Supports markdown formatting.

More paragraphs...

--> file: {sha1}_{attachment.pdf}
--> image: {sha1}_{photo.jpg}
--> url: https://example.com/resource
--> npub: npub1...
--> signature: hex_signature

> YYYY-MM-DD HH:MM_ss -- COMMENTER
First comment text
--> npub: npub1...
--> signature: hex_sig

> YYYY-MM-DD HH:MM_ss -- ANOTHER_USER
Second comment text
```

### Header Section

The header consists of **at least 7 lines**:

1. **Title Line** (required)
   - **Format**: `# BLOG: <title>`
   - **Example**: `# BLOG: Getting Started with Geogram`
   - **Constraints**: Title can be any length but will be truncated in filename

2. **Blank Line** (required)
   - Separates title from metadata

3. **Author Line** (required)
   - **Format**: `AUTHOR: <callsign>`
   - **Example**: `AUTHOR: CR7BBQ`
   - **Constraints**: Alphanumeric callsign, uppercase recommended

4. **Created Timestamp** (required)
   - **Format**: `CREATED: YYYY-MM-DD HH:MM_ss`
   - **Example**: `CREATED: 2025-01-15 10:30_00`
   - **Note**: Underscore before seconds (consistent with chat/forum)

5. **Edited Timestamp** (optional)
   - **Format**: `EDITED: YYYY-MM-DD HH:MM`
   - **Example**: `EDITED: 2025-01-16 14:30`
   - **Purpose**: Records when the post was last edited
   - **Note**: Only added/updated when post content is modified after creation

6. **Description Line** (optional)
   - **Format**: `DESCRIPTION: <text>`
   - **Example**: `DESCRIPTION: A beginner's guide to using Geogram`
   - **Constraints**: Recommended 500 characters or less
   - **Purpose**: Summary shown in post lists

7. **Location Line** (optional)
   - **Format**: `LOCATION: <latitude>, <longitude>`
   - **Example**: `LOCATION: 38.736946, -9.142685`
   - **Constraints**: Decimal degrees format, 6 decimal places recommended
   - **Purpose**: Geo-location of the post, displayed as clickable link to map viewer
   - **Note**: Shown in post detail header, click to view location on map

8. **Status Line** (required)
   - **Format**: `STATUS: <draft|published>`
   - **Values**:
     - `draft` - Only visible to author and admin
     - `published` - Visible to all users, accepts comments
   - **Example**: `STATUS: published`

9. **Tags Metadata** (optional)
   - **Format**: `--> tags: <tag1>,<tag2>,<tag3>`
   - **Example**: `--> tags: tutorial,beginner,guide`
   - **Constraints**: Comma-separated, no limit on count
   - **Note**: Must appear before content blank line

10. **Blank Line** (required)
    - Separates header from content

### Content Section

The content section begins after the header blank line and continues until metadata or comments are encountered.

**Characteristics**:
- Plain text with markdown formatting
- Preserves original paragraph structure
- Whitespace preserved (line breaks, indentation)
- No length limit (reasonable content sizes recommended)
- Can reference files via metadata below content

**Markdown Support**:
- **Headings**: `# H1`, `## H2`, `### H3`
- **Bold**: `**text**` or `__text__`
- **Italic**: `*text*` or `_text_`
- **Links**: `[text](url)`
- **Lists**: Bulleted (`-` or `*`) and numbered (`1.`)
- **Code**: Inline `` `code` `` and blocks (` ``` `)
- **Images**: `![alt](url)` (or via `--> image:` metadata)

### Post Metadata Section

Metadata appears after content, using the `--> key: value` format.

**Ordering Rules**:
1. Content metadata first (file, image, url)
2. NOSTR signature MUST be last if present
3. Blank line recommended before comments

## Metadata Field Types

### Tags

- **Format**: `--> tags: <tag1>,<tag2>,<tag3>`
- **Location**: Header section (before content)
- **Purpose**: Categorization, search, filtering
- **Constraints**:
  - Comma-separated list
  - No spaces around commas
  - Case-sensitive (lowercase recommended)
  - No limit on tag count
- **Example**: `--> tags: tutorial,programming,python,beginner`

### File Attachment

- **Format**: `--> file: <sha1>_<filename>`
- **Location**: After content, before signature
- **Purpose**: Attach documents, PDFs, archives
- **Storage**: `blog/YYYY/files/` directory
- **Example**: `--> file: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855_document.pdf`

**SHA1 Naming**:
- Files stored as: `{sha1_hash}_{original_filename}`
- Prevents overwrites when same file uploaded multiple times
- UI displays only original filename portion
- Extension always preserved

### Image Attachment

- **Format**: `--> image: <sha1>_<filename>`
- **Location**: After content, before signature
- **Purpose**: Attach photos, screenshots, diagrams
- **Storage**: Same as files (`blog/YYYY/files/`)
- **Example**: `--> image: a1b2c3d4e5f6789012345678901234567890abcd1234567_screenshot.png`

**Supported Formats**: JPG, PNG, GIF, WebP, SVG

### URL Reference

- **Format**: `--> url: <url>`
- **Location**: After content, before signature
- **Purpose**: External resource links
- **Example**: `--> url: https://example.com/related-article`
- **Constraints**: Must be valid URL (http:// or https://)

### NOSTR Public Key

- **Format**: `--> npub: <npub1...>`
- **Location**: Header or post metadata
- **Purpose**: Identity verification
- **Example**: `--> npub: npub1qqqqqqqq...`
- **Encoding**: Bech32-encoded NOSTR public key

### NOSTR Signature

- **Format**: `--> signature: <hex_signature>`
- **Location**: MUST be last metadata line
- **Purpose**: Cryptographic proof of authorship
- **Example**: `--> signature: 0123456789abcdef...`
- **Encoding**: Hex-encoded Schnorr signature
- **Requirement**: If present, must be final metadata entry

## Comments

### Comment Storage

Comments are stored as separate files in the `comments/` subdirectory of each blog post folder. This allows for remote commenting via API where devices can post comments to blog posts hosted on other devices.

**File Location**: `blog/{year}/{postId}/comments/`

**Filename Pattern**: `YYYY-MM-DD_HH-MM-SS_AUTHOR.txt`

**Example**: `2025-01-15_14-30-45_X13K0G.txt`

### Comment File Format

```
AUTHOR: CALLSIGN
CREATED: YYYY-MM-DD HH:MM_ss

Comment content here.
Can span multiple lines.

--> npub: npub1...
--> signature: hex_signature
```

### Comment Structure

1. **Author Line** (required)
   - **Format**: `AUTHOR: CALLSIGN`
   - **Example**: `AUTHOR: X135AS`

2. **Created Timestamp** (required)
   - **Format**: `CREATED: YYYY-MM-DD HH:MM_ss`
   - **Example**: `CREATED: 2025-01-15 14:30_45`

3. **Blank Line** (required)
   - Separates header from content

4. **Content** (required)
   - Plain text, multiple lines allowed
   - No markdown rendering in comments
   - No file attachments in comments

5. **Metadata** (optional)
   - NOSTR npub and signature
   - Blank line before metadata recommended
   - Signature must be last if present

### Comment Characteristics

- **Threading**: Flat (not threaded/nested)
- **Ordering**: Chronological by filename (timestamp)
- **Visibility**: Only on published posts
- **Permissions**: Anyone can comment on published posts
- **Deletion**: Post author, comment author, or admin can delete comments

### Comment Restrictions

- Cannot add comments to draft posts
- No file attachments in comments
- No metadata except npub/signature
- No nested replies (flat structure only)

### Remote Commenting

Blog posts can receive comments from remote devices via the Blog API. Remote devices use the ConnectionManager to post comments through whatever transport is available (LAN, WebRTC, Station relay, or BLE).

See [API Documentation](#local-api-endpoints) for comment endpoints.

## File Attachments

### SHA1-Based File Naming

All uploaded files are renamed using their SHA1 hash to prevent overwrites and enable deduplication.

**Storage Format**: `{sha1_hash}_{original_filename}`

**Process**:
1. Calculate SHA1 hash of file contents
2. Preserve original filename and extension
3. Combine: `{hash}_{filename}`
4. Store in year-specific `files/` directory

**Example**:
```
Original: tutorial-diagram.png
SHA1: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
Stored: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855_tutorial-diagram.png
Displayed: tutorial-diagram.png (UI extracts filename)
```

### File Location

Files are organized by year:

```
blog/
├── 2024/
│   └── files/
│       ├── {sha1}_document.pdf
│       └── {sha1}_image.jpg
└── 2025/
    └── files/
        └── {sha1}_attachment.pdf
```

### File References in Posts

In post metadata:
```
--> file: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855_document.pdf
--> image: a1b2c3d4e5f6_photo.jpg
```

**UI Handling**:
- Display only original filename
- Extract from: `{hash}_{filename}` → `filename`
- Open file using full path: `blog/YYYY/files/{hash}_{filename}`

### Supported File Types

**Images**: JPG, JPEG, PNG, GIF, WebP, SVG
**Documents**: PDF, TXT, MD, DOC, DOCX
**Archives**: ZIP, TAR, GZ
**Other**: Any file type can be attached

### File Size Limits

Recommended limits (configurable):
- Individual file: 10 MB
- Total attachments per post: 50 MB
- Implementation may impose stricter limits

## NOSTR Integration

### NOSTR Keys

**npub (Public Key)**:
- Bech32-encoded public key
- Format: `npub1` followed by encoded data
- Purpose: Identifies author, enables verification
- Example: `npub1qqqqqqqqqqqqqqqqqqqqqqqqqq...`

**nsec (Private Key)**:
- Bech32-encoded private key
- Never stored in files
- Used for signing messages
- Kept secure in user's keystore

### Signature Generation

1. Construct signable message from post/comment content
2. Hash message using SHA-256
3. Sign hash using nsec (Schnorr signature on secp256k1)
4. Encode signature as hex string
5. Add as last metadata line: `--> signature: <hex>`

### Signature Verification

1. Extract npub and signature from metadata
2. Reconstruct original message content
3. Decode npub to public key
4. Verify Schnorr signature against content hash
5. Display verification badge in UI if valid

### Signed vs Unsigned Posts

**Signed Posts**:
- Include npub and signature metadata
- Display verification badge
- Cryptographically provable authorship
- Cannot be modified without detection

**Unsigned Posts**:
- No npub or signature
- Author identified only by callsign
- Still functional, less secure
- Can be modified by anyone with access

## Complete Examples

### Example 1: Simple Published Post

```
# BLOG: Welcome to My Blog

AUTHOR: CR7BBQ
CREATED: 2025-01-15 10:00_00
STATUS: published

This is my first blog post on Geogram!

I'm excited to share my thoughts here.

--> npub: npub1abc123def456...
--> signature: 0123456789abcdef...
```

### Example 2: Post with Description, Tags, and Edit History

```
# BLOG: Getting Started with Geogram

AUTHOR: CR7BBQ
CREATED: 2025-01-15 10:30_00
EDITED: 2025-01-16 14:45
DESCRIPTION: A beginner's guide to using Geogram for offline communication
STATUS: published
--> tags: tutorial,beginner,guide

Welcome to Geogram! This post will guide you through the basics.

Geogram is an offline-first communication platform designed for
resilience and privacy. Here's what you need to know:

1. Collections organize your content
2. NOSTR keys prove your identity
3. Everything is stored locally

--> npub: npub1abc123...
--> signature: fedcba9876543210...
```

### Example 3: Post with Attachments

```
# BLOG: Tech Tutorial

AUTHOR: X135AS
CREATED: 2025-01-20 14:00_00
DESCRIPTION: Step-by-step tutorial with examples
STATUS: published
--> tags: tutorial,technical

Here's a comprehensive tutorial on the topic.

Check out the attached diagram for visual explanation,
and download the PDF for complete documentation.

See also this external resource for more details.

--> file: e3b0c4429_tutorial-guide.pdf
--> image: a1b2c3d4e_diagram.png
--> url: https://example.com/docs
--> npub: npub1xyz789...
--> signature: abcd1234efgh5678...
```

**Note**: The npub and signature MUST appear after all content metadata (file, image, url) and the signature MUST be the last metadata line.

### Example 4: Post with Location

```
# BLOG: Trip Report from Lisbon

AUTHOR: CR7BBQ
CREATED: 2025-02-10 16:30_00
DESCRIPTION: My visit to the beautiful city of Lisbon
LOCATION: 38.736946, -9.142685
STATUS: published
--> tags: travel,portugal,lisbon

Just arrived in Lisbon! The city is amazing.

The weather is great and the food is incredible.
I'll be sharing more updates during my stay.

--> image: a1b2c3d4e_lisbon-view.jpg
--> npub: npub1abc123...
--> signature: 5555eeee6666ffff...
```

**Note**: The LOCATION field displays as a clickable link in the post detail view. Clicking it opens the internal map viewer centered on the specified coordinates.

### Example 5: Post with Comments

```
# BLOG: Monthly Update

AUTHOR: CR7BBQ
CREATED: 2025-01-25 09:00_00
STATUS: published
--> tags: update,news

Here's what happened this month...

Lots of progress on various fronts!

--> npub: npub1abc123...
--> signature: 0000aaaa1111bbbb...

> 2025-01-25 10:15_30 -- X135AS
Great update! Looking forward to next month.
--> npub: npub1xyz789...
--> signature: 2222cccc3333dddd...

> 2025-01-25 11:20_45 -- CR7BBQ
Thanks! Stay tuned for more updates.
--> npub: npub1abc123...
--> signature: 4444eeee5555ffff...

> 2025-01-26 08:00_00 -- BRAVO2
Excellent work on the project!
```

### Example 5: Draft Post

```
# BLOG: Work in Progress

AUTHOR: CR7BBQ
CREATED: 2025-01-28 16:00_00
DESCRIPTION: Still working on this article
STATUS: draft
--> tags: draft,wip

This is an unfinished post.

Need to add more content here...

TODO:
- Add examples
- Include references
- Proofread

--> npub: npub1abc123...
```

## Parsing Implementation

### File Reading

```
1. Read entire file as UTF-8 text
2. Split into lines by \n
3. Verify first line starts with "# BLOG: "
4. Extract title from first line
5. Parse header lines (AUTHOR, CREATED, EDITED, DESCRIPTION, STATUS)
6. Extract tags from "--> tags:" before content
7. Find content start (after header blank line)
8. Parse content until metadata or comments
9. Extract metadata lines (file, image, url, npub)
10. Parse comments (lines starting with "> ")
11. Associate metadata with comments
12. Validate signatures if present
```

### Header Parsing

```
Line 1: # BLOG: <title>
Line 2: (blank)
Line 3: AUTHOR: <callsign>
Line 4: CREATED: <timestamp>
Line 5: EDITED: <timestamp> (optional, only if edited)
Line 5/6: DESCRIPTION: <text> (optional)
Line 6/7: LOCATION: <lat>, <lon> (optional)
Line 7/8: STATUS: <draft|published>
Line 8+: --> tags: <tags> (optional)
Line N: (blank) - marks end of header
```

### Content Extraction

- Content starts after header's trailing blank line
- Continues until first metadata line (`--> `) or comment line (`> `)
- Preserve all whitespace and formatting
- Empty lines within content are preserved

### Comment Parsing

```
1. Comments start with "> "
2. Extract timestamp and author from first line
3. Read content lines until next comment or EOF
4. Parse metadata for each comment (npub, signature)
5. Validate signature placement (must be last)
6. Associate metadata with parent comment
```

## File Operations

### Creating a New Post

```
1. Generate sanitized filename from title and date
2. Determine year from timestamp
3. Create year directory if doesn't exist: blog/YYYY/
4. Format header with all required fields
5. Add content and metadata
6. Write file with UTF-8 encoding
7. Set file permissions (644 or equivalent)
8. Flush to disk immediately
```

### Updating a Post

```
1. Verify user has permission (author or admin)
2. Read existing post file
3. Preserve comments (do not modify)
4. Update header fields as needed
5. Update content if changed
6. Update/add metadata
7. Write file atomically (temp file + rename)
8. Preserve original created timestamp
```

### Publishing a Draft

```
1. Read draft post file
2. Change STATUS: draft → STATUS: published
3. Write updated file
4. No other changes to content
```

### Deleting a Post

```
1. Verify user has permission (author or admin)
2. Delete post file: blog/YYYY/YYYY-MM-DD_title.md
3. Optionally clean up orphaned files in files/ directory
4. Update indexes/caches if applicable
```

### Adding a Comment

```
1. Verify post is published (not draft)
2. Read existing post file
3. Append comment to end of file:
   - Comment header line
   - Comment content
   - Comment metadata (npub, signature)
   - Blank line separator
4. Write updated file
5. Preserve all existing content
```

### Deleting a Comment

```
1. Verify user has permission (comment author or admin)
2. Read post file
3. Locate comment by timestamp and author
4. Remove comment block (header + content + metadata)
5. Write updated file without that comment
6. Preserve post content and other comments
```

## Validation Rules

### Post Validation

- [x] First line must start with `# BLOG: `
- [x] Title must not be empty after `# BLOG: `
- [x] AUTHOR line must exist and have non-empty callsign
- [x] CREATED line must exist with valid timestamp
- [x] STATUS must be either `draft` or `published`
- [x] Header must end with blank line before content
- [x] If signature present, must be last metadata line
- [x] Filename must match pattern YYYY-MM-DD_*.md

### Timestamp Validation

**Format**: `YYYY-MM-DD HH:MM_ss`

- Year: 1900-2100 (reasonable range)
- Month: 01-12
- Day: 01-31 (validate against month)
- Hour: 00-23
- Minute: 00-59
- Second: 00-59
- Separator before seconds: underscore `_`

**Example Valid**: `2025-01-15 14:30_45`
**Example Invalid**: `2025-1-15 14:30:45` (missing zero-padding, wrong separator)

### Metadata Validation

- Tags: Comma-separated, no spaces around commas
- Files: Must exist in `blog/YYYY/files/` directory
- URLs: Must be valid http:// or https:// URLs
- npub: Must start with `npub1` and be valid bech32
- Signature: Must be hex string if present

### Comment Validation

- Must start with `> ` followed by timestamp and author
- Timestamp must be valid format
- Author callsign must not be empty
- Can only be added to published posts
- Metadata limited to npub and signature

### Security Validation

- Verify post author matches npub if signature present
- Verify comment author matches npub if signature present
- Check admin permissions for edit/delete operations
- Validate file paths to prevent directory traversal

## Best Practices

### For Authors

1. **Use descriptive titles**: Clear, concise titles improve discoverability
2. **Add descriptions**: Help readers decide if post is relevant
3. **Tag appropriately**: Use 3-5 relevant tags for categorization
4. **Save drafts early**: Use draft status while working on content
5. **Sign your posts**: Add npub and signature for verification
6. **Reference files**: Use file/image metadata rather than embedding

### For Developers

1. **Validate input**: Check all user input before writing files
2. **Handle encoding**: Always use UTF-8, never assume ASCII
3. **Atomic writes**: Use temp file + rename for updates
4. **Preserve data**: Never modify timestamps or existing comments
5. **Permission checks**: Verify user permissions before operations
6. **SHA1 files**: Always calculate SHA1 before storing files
7. **Sanitize filenames**: Apply sanitization rules strictly

### For System Administrators

1. **Backup regularly**: Blog posts are valuable content
2. **Monitor disk usage**: Files can accumulate over time
3. **Set size limits**: Prevent abuse with reasonable limits
4. **Archive old years**: Move old years to separate storage if needed
5. **Verify signatures**: Implement signature verification in UI

## Security Considerations

### Access Control

**Admin Permissions**:
- Edit any post (draft or published)
- Delete any post
- Delete any comment
- Publish any draft
- Full moderation rights

**Author Permissions**:
- Edit own posts (draft or published)
- Delete own posts
- Publish own drafts
- Delete own comments

**Reader Permissions**:
- View published posts
- Add comments to published posts
- Delete own comments
- Cannot view others' drafts

### File Security

**SHA1 Hashing**:
- Prevents file overwrites
- Enables deduplication
- Content-based naming

**File Permissions**:
- Read-only for readers
- Write for author/admin only
- No execute permissions

**Path Validation**:
- Prevent directory traversal (../)
- Validate file extensions
- Check file sizes before storage

### NOSTR Signatures

**Benefits**:
- Cryptographic proof of authorship
- Tamper detection
- Non-repudiation
- Identity verification

**Limitations**:
- Optional (not required)
- Requires NOSTR key management
- Signature verification needs implementation
- Clock skew can affect timestamps

### Privacy Considerations

**npub Exposure**:
- npub is public identifier
- Links posts to NOSTR identity
- Consider privacy before signing

**Metadata Leakage**:
- Timestamps reveal posting patterns
- File metadata may contain personal info
- Tags may reveal interests

### Threat Mitigation

**Content Validation**: Prevent injection attacks through strict parsing
**Size Limits**: Prevent DoS via large file uploads
**Permission Checks**: Enforce access control consistently
**Signature Verification**: Detect tampering and impersonation
**Backup Strategy**: Protect against data loss

## Web Publishing

Blog posts can be accessed externally via the relay's HTTP API. When a device is connected to a relay, external users can view the device's published blog posts through a public URL.

### External URL Format

```
https://{relay-host}/{nickname}/blog/{filename}.html
```

**Parameters:**
- `relay-host` - The relay server domain (e.g., `p2p.radio`)
- `nickname` - The device's nickname or callsign (case-insensitive)
- `filename` - The blog post filename without extension (e.g., `2025-12-04_hello-everyone`)

**Examples:**
```
https://p2p.radio/embaixada/blog/2025-12-04_hello-everyone.html
https://p2p.radio/X1ABC123/blog/2025-01-15_my-first-post.html
```

### How It Works

1. External user requests a blog post URL from the relay
2. Relay identifies the device by nickname/callsign
3. Relay sends the request to the connected device via WebSocket
4. Device reads the blog post from its collection
5. Device converts markdown to HTML with styling
6. Device returns rendered HTML to relay
7. Relay serves the HTML to the external user

### Requirements

- Device must be connected to the relay
- Blog post must exist in the device's collection
- Blog post must have `STATUS: published` (drafts are not accessible)

### HTML Output

The rendered blog post includes:
- Responsive HTML5 structure
- Dark theme styling
- Post title and date
- Author callsign
- Rendered markdown content
- Footer linking to geogram.radio

## Remote Device Access

Other Geogram devices can access blog posts from remote devices through the relay network using WebSocket messages. This enables device-to-device content sharing without requiring direct connections.

### Listing Remote Blog Posts

To list blog posts from another device:

**Request Message:**
```json
{
  "type": "REMOTE_REQUEST",
  "targetCallsign": "X1TARGET",
  "requestId": "unique-id",
  "request": {
    "type": "LIST_BLOG_POSTS",
    "collectionName": "default",
    "year": 2025,
    "limit": 20,
    "offset": 0
  }
}
```

**Response Message:**
```json
{
  "type": "REMOTE_RESPONSE",
  "sourceCallsign": "X1TARGET",
  "requestId": "unique-id",
  "response": {
    "type": "BLOG_POST_LIST",
    "posts": [
      {
        "filename": "2025-12-04_hello-everyone.md",
        "title": "Hello Everyone",
        "author": "CR7BBQ",
        "date": "2025-12-04",
        "status": "published",
        "tags": ["welcome", "introduction"]
      }
    ],
    "total": 1,
    "hasMore": false
  }
}
```

### Fetching Remote Blog Post

To fetch a specific blog post from another device:

**Request Message:**
```json
{
  "type": "REMOTE_REQUEST",
  "targetCallsign": "X1TARGET",
  "requestId": "unique-id",
  "request": {
    "type": "GET_BLOG_POST",
    "collectionName": "default",
    "filename": "2025-12-04_hello-everyone.md",
    "format": "markdown"
  }
}
```

**Format Options:**
- `markdown` - Raw markdown content
- `html` - Rendered HTML
- `metadata` - Only metadata (no content)

**Response Message:**
```json
{
  "type": "REMOTE_RESPONSE",
  "sourceCallsign": "X1TARGET",
  "requestId": "unique-id",
  "response": {
    "type": "BLOG_POST",
    "post": {
      "filename": "2025-12-04_hello-everyone.md",
      "title": "Hello Everyone",
      "author": "CR7BBQ",
      "date": "2025-12-04",
      "status": "published",
      "tags": ["welcome"],
      "content": "# Hello Everyone\n\nWelcome to my blog...",
      "npub": "npub1abc123...",
      "signature": "sig123...",
      "comments": []
    }
  }
}
```

### Access Control

- Only `published` posts are accessible to remote devices
- Draft posts are not returned in listings
- The target device must be connected to the same relay
- Requests timeout after 30 seconds if the target device doesn't respond

## Local API Endpoints

When a device runs its local HTTP server, these endpoints provide blog access and comment management:

### GET /api/blog

List all published blog posts.

**Query Parameters:**
| Parameter | Description |
|-----------|-------------|
| `year` | Filter by year (e.g., `2025`) |
| `tag` | Filter by tag |
| `limit` | Max posts to return |
| `offset` | Pagination offset |

**Response (200 OK):**
```json
{
  "success": true,
  "timestamp": 1734344400,
  "filters": { "year": 2025 },
  "total": 5,
  "count": 5,
  "posts": [
    {
      "id": "2025-12-04_hello-everyone",
      "title": "Hello Everyone",
      "author": "CR7BBQ",
      "timestamp": "2025-12-04 10:00_00",
      "status": "published",
      "tags": ["welcome"],
      "comment_count": 2
    }
  ]
}
```

### GET /api/blog/{postId}

Get a specific blog post with comments.

**Response (200 OK):**
```json
{
  "success": true,
  "id": "2025-12-04_hello-everyone",
  "title": "Hello Everyone",
  "author": "CR7BBQ",
  "timestamp": "2025-12-04 10:00_00",
  "edited": null,
  "description": "Welcome post",
  "location": null,
  "status": "published",
  "tags": ["welcome"],
  "content": "Welcome to my blog...",
  "files": [],
  "comments": [
    {
      "id": "2025-12-04_11-30-45_X13K0G",
      "author": "X13K0G",
      "timestamp": "2025-12-04 11:30_45",
      "content": "Great post!",
      "npub": "npub1abc...",
      "signature": "hex..."
    }
  ],
  "comment_count": 1,
  "npub": "npub1xyz...",
  "signature": "hex..."
}
```

### POST /api/blog/{postId}/comment

Add a comment to a published blog post.

**Request Body:**
```json
{
  "author": "X13K0G",
  "content": "Great post!",
  "npub": "npub1abc...",
  "signature": "hex_signature"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "comment_id": "2025-12-04_11-30-45_X13K0G",
  "timestamp": "2025-12-04T11:30:45Z"
}
```

**Error Responses:**
- `400` - Missing required field (author or content)
- `403` - Cannot comment on unpublished post
- `404` - Post not found

### DELETE /api/blog/{postId}/comment/{commentId}

Delete a comment from a blog post.

**Headers:**
| Header | Description |
|--------|-------------|
| `X-Npub` | Requester's NOSTR public key for authorization |

**Response (200 OK):**
```json
{
  "success": true,
  "deleted": true
}
```

**Error Responses:**
- `401` - Missing X-Npub header
- `403` - Unauthorized (not post author or comment author)
- `404` - Post or comment not found

### GET /api/blog/{postId}/files/{filename}

Get an attached file from a blog post.

**Response (200 OK):** File content with appropriate Content-Type header.

**Response (404 Not Found):** File not found.

### Remote Comment Service

To post comments to blog posts on other devices, use the `BlogCommentService`:

```dart
final service = BlogCommentService();

// Post a comment to remote device
final result = await service.postRemoteComment(
  targetCallsign: 'X1TARGET',
  postId: '2025-12-04_hello-everyone',
  author: 'MYCALL',
  content: 'Great post!',
  npub: myNpub,
  signature: mySignature,
);

if (result.success) {
  print('Comment posted via ${result.transportUsed}');
}
```

See [API Documentation](../../api/API.md#blog-api) for complete technical details.

## Related Documentation

- [Chat Format Specification](../chat/chat-format-specification.md)
- [Forum Format Specification](../forum/forum-format-specification.md)
- [Events Format Specification](../events/events-format-specification.md)
- [Collection File Formats](../others/file-formats.md)
- [NOSTR Protocol](https://github.com/nostr-protocol/nostr)

## Change Log

### Version 1.3 (2025-12-16)

- Migrated to folder-based storage structure: each post in its own directory
- Comments now stored as separate files in `comments/` subdirectory
- Added Blog API endpoints for remote commenting
- Added `BlogCommentService` for transport-agnostic remote comment operations
- Updated API documentation with new endpoints

### Version 1.2 (2025-12-15)

- Added EDITED field for tracking when posts are modified
- Clarified npub placement: must be at end before signature, not in header
- Updated examples to reflect correct npub placement
- Renumbered header fields section

### Version 1.1 (2025-12-05)

- Added Web Publishing section
- Document external URL access via relay proxy
- Added API documentation reference

### Version 1.0 (2025-11-21)

- Initial specification
- Year-based organization
- Draft/published workflow
- Markdown content support
- Tags and categorization
- Flat comments
- File attachments with SHA1 naming
- NOSTR signature integration
- Permission system (admin, author, reader)
