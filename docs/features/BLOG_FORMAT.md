# Geogram Blog Format Specification

## Overview

Geogram blogs use a text-based markdown file format for storing blog posts with comments. Each blog is organized by year, with posts stored as individual markdown files.

## Blog Structure

```
collection_name/
├── blog/
│   ├── 2024/
│   │   ├── 2024-03-15_my-first-post.md
│   │   ├── 2024-12-20_year-end-review.md
│   │   └── files/
│   │       ├── {sha1}_{image.jpg}
│   │       └── {sha1}_{document.pdf}
│   └── 2025/
│       ├── 2025-01-10_new-year-goals.md
│       ├── 2025-01-15_tech-tutorial.md
│       └── files/
│           └── {sha1}_{attachment.pdf}
└── extra/
    ├── security.json          # Admin/moderator settings
    └── blog_config.json       # Blog-specific configuration
```

## Blog Post File Format

### Header (7+ lines)

```
# BLOG: Post Title

AUTHOR: CALLSIGN
CREATED: YYYY-MM-DD HH:MM_ss
DESCRIPTION: Short description of the post
STATUS: draft|published
--> tags: tag1,tag2,tag3
--> npub: npub1...

```

The header consists of:
1. Post title line starting with `# BLOG: `
2. Blank line
3. Author line starting with `AUTHOR: `
4. Creation timestamp starting with `CREATED: `
5. Description line (optional) starting with `DESCRIPTION: `
6. Status line starting with `STATUS: ` (draft or published)
7. Tags metadata (optional) starting with `--> tags: `
8. NOSTR npub (optional) starting with `--> npub: `
9. Blank line before content

### Post Content

The post content follows the header and can contain:
- Plain text (multiple paragraphs)
- Metadata links for files, images, and URLs

```
This is the blog post content.

It can span multiple lines and paragraphs.
Just plain text, formatted naturally.

You can reference files, images, and URLs using metadata below.

--> file: {sha1}_{attachment.pdf}
--> image: {sha1}_{photo.jpg}
--> url: https://example.com/resource
--> signature: hex_signature
```

### Comments

Comments follow the same format as forum replies:

```
> YYYY-MM-DD HH:MM_ss -- COMMENTER_CALLSIGN
This is a comment on the blog post.
Can span multiple lines.
--> npub: npub1...
--> signature: hex_signature

> YYYY-MM-DD HH:MM_ss -- ANOTHER_USER
Another comment here.
```

## Post Metadata

Metadata is specified using the `--> key: value` format. Supported metadata keys:

**Blog-specific:**
- `tags`: Comma-separated list of tags (e.g., `tech,tutorial,news`)
- `description`: Short description (also in header)

**Standard metadata:**
- `file`: Attached file (SHA1-based naming)
- `image`: Attached image (SHA1-based naming)
- `url`: External URL reference
- `npub`: NOSTR public key
- `signature`: NOSTR signature (must be last if present)

## File Attachments

### SHA1-Based File Naming

All uploaded files are automatically renamed using their SHA1 hash:

**Storage Format**: `{sha1_hash}_{original_filename}`

**Example**:
- Original file: `tutorial-diagram.png`
- SHA1 hash: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- Stored as: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855_tutorial-diagram.png`
- Displayed as: `tutorial-diagram.png` (UI shows only original filename)

### File Location

All attachments for a year are stored in the `files/` subdirectory:

```
blog/2025/
├── 2025-01-15_tech-tutorial.md
└── files/
    ├── {sha1}_diagram.png
    ├── {sha1}_code-example.txt
    └── {sha1}_reference.pdf
```

### File Metadata in Posts

In post metadata, files are referenced by their full SHA1-prefixed name:

```
--> file: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855_document.pdf
--> image: a1b2c3d4e5f6789012345678901234567890abcd1234567_photo.jpg
```

The UI automatically extracts and displays only the original filename portion.

## Filename Generation

Post filenames are automatically generated from the title and date:

**Format**: `YYYY-MM-DD_sanitized-title.md`

**Sanitization Rules**:
1. Convert title to lowercase
2. Replace spaces with hyphens
3. Remove non-alphanumeric characters (except hyphens)
4. Remove multiple consecutive hyphens
5. Truncate to 50 characters
6. Prepend date in YYYY-MM-DD format

**Examples**:
- Title: "My First Blog Post!"
  - Date: 2025-01-15
  - Filename: `2025-01-15_my-first-blog-post.md`

- Title: "Tech Tutorial: Getting Started"
  - Date: 2025-01-20
  - Filename: `2025-01-20_tech-tutorial-getting-started.md`

- Title: "Year-End Review (2024)"
  - Date: 2024-12-31
  - Filename: `2024-12-31_year-end-review-2024.md`

## Draft vs Published Status

Posts can be in one of two states:

**Draft**:
- STATUS: draft
- Only visible to the post author
- Can be edited and modified
- Not visible in public feeds

**Published**:
- STATUS: published
- Visible to all users
- Can accept comments
- Can still be edited by author

## Comments

### Comment Format

Comments use the same format as forum replies:

```
> YYYY-MM-DD HH:MM_ss -- AUTHOR
Comment content here.
--> npub: npub1...
--> signature: hex_signature
```

### Comment Restrictions

- Comments can only be added to published posts
- Drafts cannot receive comments
- Comments are flat (not threaded)
- Comments appear in chronological order

## Timestamp Format

Timestamps use the format: `YYYY-MM-DD HH:MM_ss`

Example: `2025-11-21 14:30_45`

Note the underscore before seconds (same as chat and forum).

## Admin Operations

### Blog Creator (Admin)

The admin is identified by their npub (NOSTR public key). The admin can:

- Edit any post
- Delete any post
- Publish any draft
- Delete any comment
- Moderate all content

### Post Author

Post authors (identified by npub match) can:

- Edit their own posts (any status)
- Delete their own posts
- Publish their own drafts
- Delete their own comments

### Regular Users

Regular users can:

- View published posts
- Add comments to published posts
- Cannot see drafts (unless they are the author)

## NOSTR Integration

### Signatures

Posts and comments can be signed using NOSTR keys:

1. The `npub` metadata contains the author's NOSTR public key
2. The `signature` metadata contains the cryptographic signature
3. Signature must always be the last metadata line
4. Signed posts/comments display a verification badge in the UI

### Verification

Future implementations will verify signatures against the content to ensure authenticity.

## Character Encoding

All blog files use UTF-8 encoding.

## Line Endings

Files use Unix-style line endings (`\n`).

## Maximum Lengths

- Post title: 255 characters (truncated in filename to 50)
- Description: 500 characters (recommended)
- Tags: No limit, but UI may display only first few
- Post content: No strict limit
- Comment content: No strict limit
- Original filename: 100 characters (truncated if longer, extension preserved)

## Parsing Rules

1. Post files must start with `# BLOG: ` on the first line
2. Header must have at least 6 lines (title, blank, author, created, status, blank)
3. DESCRIPTION line is optional
4. Tags are parsed from `--> tags:` metadata before blank line
5. Post content starts after header blank line
6. Comments start with `> ` followed by timestamp and author
7. Metadata lines start with `--> `
8. Signature, if present, must be the last metadata line
9. Empty lines between comments are ignored
10. Content preserves original formatting including whitespace

## Example Blog Post File

```
# BLOG: Getting Started with Geogram

AUTHOR: CR7BBQ
CREATED: 2025-01-15 10:30_00
DESCRIPTION: A beginner's guide to using Geogram for offline communication
STATUS: published
--> tags: tutorial,beginner,guide
--> npub: npub1abc123...

Welcome to Geogram! This post will guide you through the basics.

Geogram is an offline-first communication platform designed for
resilience and privacy. Here's what you need to know:

1. Collections organize your content
2. NOSTR keys prove your identity
3. Everything is stored locally

Check out the attached PDF for more details.

--> file: a1b2c3d4e5f6_getting-started-guide.pdf
--> image: e3b0c442_screenshot.png
--> url: https://geogram.example.com/docs
--> signature: 0123456789abcdef...

> 2025-01-15 11:45_23 -- X135AS
Great tutorial! Very helpful for getting started.
--> npub: npub1xyz789...
--> signature: fedcba9876543210...

> 2025-01-15 14:20_10 -- CR7BBQ
Glad it helped! Let me know if you have questions.
--> npub: npub1abc123...
--> signature: 1234567890abcdef...
```

## Implementation Notes

- Post files are written with immediate flush (`flush: true`) for disk persistence
- File reads handle various error conditions gracefully
- SHA1 calculation is performed on file contents before copying to storage
- Filename length limits prevent filesystem issues
- Invalid timestamps fall back to current time
- Year folders are created automatically as needed
- Drafts are filtered from public view unless user is the author

## UI Features

**2-Panel Layout:**
- Left panel: Year-grouped collapsible list of posts
- Right panel: Selected post detail with comments

**Post List Features:**
- Year folders (collapsible)
- Draft badges
- Search by title/tags/description
- Tag filtering
- Comment count display

**Post Detail Features:**
- Title and metadata display
- Tag chips (clickable for filtering)
- File/image/URL attachments (clickable)
- Edit/delete buttons (for author/admin)
- Publish draft button (for drafts)
- Comment section (for published posts)
- Comment input field

**Draft Workflow:**
1. Create new post → Save as draft or Publish
2. Draft visible only to author
3. Edit draft → Update or Publish
4. Published posts can accept comments

## Security

**Admin Control:**
- Admin npub stored in `/extra/security.json`
- Set automatically when blog collection created
- Admin has full moderation rights

**Author Permissions:**
- Posts linked to author npub
- Only author (or admin) can edit/delete
- Draft visibility restricted to author

**File Security:**
- SHA1 prevents overwrites
- Files scoped to year folders
- No executable permissions on uploaded files

## Platform Compatibility

- ✅ **Linux**: Full support, tested
- ✅ **Windows**: Should work (untested)
- ✅ **macOS**: Should work (untested)
- ✅ **Web**: Full support (Flutter Web compatible)
- ✅ **Mobile**: Full support (responsive design)

## Summary

The blog feature provides:

1. ✅ Year-based organization for long-term content
2. ✅ Draft/published workflow for content management
3. ✅ Tags for categorization and discovery
4. ✅ Flat comments for reader engagement
5. ✅ File/image attachments with SHA1 deduplication
6. ✅ NOSTR identity integration
7. ✅ Admin and author permission system
8. ✅ Clean, readable file format for portability

The blog format is designed to be simple, portable, and compatible with the existing Geogram collection system while providing rich features for content creation and community engagement.
