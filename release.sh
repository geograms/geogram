#!/bin/bash
#
# Release script for Geogram
# Usage: ./release.sh [version]
#
# Accepts both stable (X.Y.Z, e.g. 1.7.0) and pre-release versions
# (X.Y.Z-LABEL.N where LABEL is alpha|beta|rc, e.g. 1.38.0-beta.2).
#
# Without arguments: smart auto-increment.
#   - 1.7.1            -> 1.7.2            (patch bump)
#   - 1.38.0-beta.1    -> 1.38.0-beta.2    (pre-release counter bump)
#
# This script:
#   - Updates pubspec.yaml with new version
#   - Generates changelog from commit messages
#   - Updates CHANGELOG.md and .version
#   - For stable releases only: updates F-Droid metadata + fastlane changelog
#   - Commits, tags, and pushes to trigger builds
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

VERSION_FILE=".version"

# Parse flags: -y / --yes runs unattended (skips confirmation prompt).
ASSUME_YES=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

# Get the last released version from version file or git tags
get_last_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        # Fallback: get from latest git tag
        git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0"
    fi
}

# Parse a version string into BASE / LABEL / LABEL_NUM globals.
# Accepts X.Y.Z (stable) or X.Y.Z-LABEL.N (pre-release, LABEL ∈ alpha|beta|rc).
# Returns 0 on success, 1 on bad format.
parse_version() {
    local v="$1"
    if [[ "$v" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-(alpha|beta|rc)\.([0-9]+))?$ ]]; then
        BASE="${BASH_REMATCH[1]}"
        LABEL="${BASH_REMATCH[3]:-}"
        LABEL_NUM="${BASH_REMATCH[4]:-}"
        return 0
    fi
    return 1
}

# Smart auto-increment: bump the pre-release counter when present, otherwise
# bump the patch number. So 1.38.0-beta.1 -> 1.38.0-beta.2 and 1.7.1 -> 1.7.2.
increment_version() {
    local version="$1"
    if ! parse_version "$version"; then
        echo "0.0.1"
        return
    fi
    if [ -n "$LABEL" ]; then
        echo "$BASE-$LABEL.$((LABEL_NUM + 1))"
    else
        local major minor patch
        IFS='.' read -r major minor patch <<< "$BASE"
        echo "$major.$minor.$((patch + 1))"
    fi
}

# Get commit messages since last tag
get_changelog() {
    local last_tag="v$1"

    # Check if tag exists
    if git rev-parse "$last_tag" >/dev/null 2>&1; then
        git log "$last_tag"..HEAD --pretty=format:"- %s" --no-merges 2>/dev/null | grep -v "^- Bump version" || true
    else
        # No previous tag, get recent commits
        git log --pretty=format:"- %s" --no-merges -20 2>/dev/null | grep -v "^- Bump version" || true
    fi
}

# Main script
LAST_VERSION=$(get_last_version)

if [ -n "$1" ]; then
    # Manual version specified
    VERSION="$1"
    if ! parse_version "$VERSION"; then
        echo -e "${RED}Error: Invalid version format. Use X.Y.Z (e.g., 1.7.0) or X.Y.Z-LABEL.N (e.g., 1.38.0-beta.2; LABEL ∈ alpha|beta|rc)${NC}"
        exit 1
    fi
else
    # Smart auto-increment (pre-release counter bump if applicable)
    VERSION=$(increment_version "$LAST_VERSION")
    parse_version "$VERSION" || true  # populate BASE/LABEL globals for the new version
fi

# Pre-release detection (drives F-Droid / fastlane skip below).
IS_PRERELEASE=0
if [ -n "$LABEL" ]; then
    IS_PRERELEASE=1
fi

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Geogram Desktop Release Script${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "Last released version: ${YELLOW}$LAST_VERSION${NC}"
echo -e "New version:           ${GREEN}$VERSION${NC}"
if [ "$IS_PRERELEASE" -eq 1 ]; then
    echo -e "Channel:               ${YELLOW}pre-release ($LABEL.$LABEL_NUM)${NC}"
fi
echo ""

# Check if tag already exists
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo -e "${RED}Error: Tag v$VERSION already exists${NC}"
    echo "Use a different version number or delete the existing tag first:"
    echo "  git tag -d v$VERSION"
    echo "  git push origin :refs/tags/v$VERSION"
    exit 1
fi

# Check for uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${YELLOW}Uncommitted changes detected:${NC}"
    git status --short
    echo ""
fi

# Generate changelog from commits
echo -e "${CYAN}Changes since v$LAST_VERSION:${NC}"
CHANGELOG=$(get_changelog "$LAST_VERSION")
if [ -z "$CHANGELOG" ]; then
    echo -e "${YELLOW}No new commits found (excluding version bumps)${NC}"
    CHANGELOG="- Minor updates and improvements"
fi
echo "$CHANGELOG"
echo ""

# Confirmation (skipped with -y / --yes)
if [ "$ASSUME_YES" -eq 1 ]; then
    echo -e "${YELLOW}Auto-confirmed (--yes)${NC}"
else
    read -p "Proceed with release v$VERSION? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Step 1: Update pubspec.yaml
echo -e "${GREEN}Updating pubspec.yaml...${NC}"
sed -i "s/^version: .*/version: $VERSION+1/" pubspec.yaml

# Step 1b: Calculate versionCode (commit count after this release)
# We add 1 because the release commit will increase the count
COMMIT_COUNT=$(($(git rev-list --count HEAD) + 1))
echo -e "${GREEN}Version code will be: $COMMIT_COUNT${NC}"

# Step 2: Save version to file
echo -e "${GREEN}Saving version to $VERSION_FILE...${NC}"
echo "$VERSION" > "$VERSION_FILE"

# Step 3: Update CHANGELOG.md
echo -e "${GREEN}Updating CHANGELOG.md...${NC}"
TODAY=$(date +%Y-%m-%d)
CHANGELOG_ENTRY="## $TODAY - v$VERSION

### Changes
$CHANGELOG
"

# Prepend to CHANGELOG.md after the title
if [ -f "CHANGELOG.md" ]; then
    # Create temp file with new entry after first line (title)
    head -n 1 CHANGELOG.md > CHANGELOG.tmp
    echo "" >> CHANGELOG.tmp
    echo "$CHANGELOG_ENTRY" >> CHANGELOG.tmp
    tail -n +2 CHANGELOG.md >> CHANGELOG.tmp
    mv CHANGELOG.tmp CHANGELOG.md
else
    echo "# Geogram Desktop Changelog

$CHANGELOG_ENTRY" > CHANGELOG.md
fi

# Step 3b: Update F-Droid metadata + fastlane changelog (stable releases only).
# F-Droid and the Play Store track only the stable channel; bumping their
# version pointers on a beta would publish unfinished work to those stores.
if [ "$IS_PRERELEASE" -eq 0 ]; then
    echo -e "${GREEN}Updating F-Droid metadata...${NC}"
    if [ -f "fdroid/dev.geogram.yml" ]; then
        sed -i "s/versionName: .*/versionName: $VERSION/" fdroid/dev.geogram.yml
        sed -i "s/versionCode: .*/versionCode: $COMMIT_COUNT/" fdroid/dev.geogram.yml
        sed -i "s/commit: v.*/commit: v$VERSION/" fdroid/dev.geogram.yml
        sed -i "s/CurrentVersion: .*/CurrentVersion: $VERSION/" fdroid/dev.geogram.yml
        sed -i "s/CurrentVersionCode: .*/CurrentVersionCode: $COMMIT_COUNT/" fdroid/dev.geogram.yml
        echo "  - Updated fdroid/dev.geogram.yml"
    fi

    FASTLANE_CHANGELOG_DIR="fastlane/metadata/android/en-US/changelogs"
    if [ -d "$FASTLANE_CHANGELOG_DIR" ]; then
        echo "$CHANGELOG" > "$FASTLANE_CHANGELOG_DIR/$COMMIT_COUNT.txt"
        echo "  - Created $FASTLANE_CHANGELOG_DIR/$COMMIT_COUNT.txt"
    fi
else
    echo -e "${YELLOW}Pre-release ($LABEL.$LABEL_NUM): skipping F-Droid + fastlane updates${NC}"
fi

# Step 4: Stage all changes
echo -e "${GREEN}Staging changes...${NC}"
git add -A

# Step 5: Commit
echo -e "${GREEN}Committing...${NC}"
# Create commit message with changelog
COMMIT_MSG="Release v$VERSION

Changes:
$CHANGELOG"

git commit -m "$COMMIT_MSG"

# Step 6: Push to main
echo -e "${GREEN}Pushing to main...${NC}"
git push origin main

# Step 7: Create and push tag
echo -e "${GREEN}Creating tag v$VERSION...${NC}"
git tag "v$VERSION"

echo -e "${GREEN}Pushing tag...${NC}"
git push origin "v$VERSION"

# Step 8: Pre-create the GitHub release so the prerelease flag is set
# correctly before CI fires. softprops/action-gh-release in the build-*
# workflows uploads artifacts to the existing release without overriding
# the flag. For stable releases the same pre-create gives us control over
# the title + auto-generated notes.
if command -v gh >/dev/null 2>&1; then
    GH_FLAGS=(--title "v$VERSION" --generate-notes)
    if [ "$IS_PRERELEASE" -eq 1 ]; then
        GH_FLAGS+=(--prerelease)
    fi
    echo -e "${GREEN}Creating GitHub release v$VERSION (${GH_FLAGS[*]})...${NC}"
    if ! gh release create "v$VERSION" "${GH_FLAGS[@]}"; then
        echo -e "${YELLOW}gh release create failed (release may already exist; CI will still upload artifacts)${NC}"
    fi
else
    echo -e "${YELLOW}gh CLI not found — CI will auto-create the release without prerelease flag${NC}"
fi

# Get repository URL for links
REPO_URL=$(git remote get-url origin 2>/dev/null | sed 's/.*github.com[:/]\(.*\)\.git/\1/' | sed 's/.*github.com[:/]\(.*\)/\1/')

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Release v$VERSION completed!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "GitHub Actions is now building all platforms."
echo "Monitor progress at: https://github.com/$REPO_URL/actions"
echo ""
echo "Release page: https://github.com/$REPO_URL/releases/tag/v$VERSION"
echo ""
echo -e "${CYAN}F-Droid:${NC}"
echo "  - Metadata updated in fdroid/dev.geogram.yml"
echo "  - Changelog created in fastlane/metadata/android/en-US/changelogs/"
echo "  - F-Droid will pick up the new version automatically from the tag"
