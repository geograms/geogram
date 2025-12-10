#!/bin/bash
#
# Release script for Geogram Desktop
# Usage: ./release.sh [version]
#
# Without arguments: automatically increments patch version (1.6.2 -> 1.6.3)
# With version: uses the specified version (e.g., ./release.sh 1.7.0)
#
# Changelog is automatically generated from commit messages since last release.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

VERSION_FILE=".version"

# Get the last released version from version file or git tags
get_last_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        # Fallback: get from latest git tag
        git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0"
    fi
}

# Increment patch version (X.Y.Z -> X.Y.Z+1)
increment_patch() {
    local version="$1"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"
    echo "$major.$minor.$((patch + 1))"
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
    # Validate version format (X.Y.Z)
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}Error: Invalid version format. Use X.Y.Z (e.g., 1.7.0)${NC}"
        exit 1
    fi
else
    # Auto-increment patch version
    VERSION=$(increment_patch "$LAST_VERSION")
fi

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Geogram Desktop Release Script${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "Last released version: ${YELLOW}$LAST_VERSION${NC}"
echo -e "New version:           ${GREEN}$VERSION${NC}"
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

# Confirmation
read -p "Proceed with release v$VERSION? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Step 1: Update pubspec.yaml
echo -e "${GREEN}Updating pubspec.yaml...${NC}"
sed -i "s/^version: .*/version: $VERSION+1/" pubspec.yaml

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
