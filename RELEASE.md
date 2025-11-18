# Release Process Instructions

This document describes how to create a new release of Geogram Desktop with binaries for all platforms.

## Prerequisites

- Push access to the GitHub repository
- `gh` CLI tool installed and authenticated
- All changes committed and pushed to `main` branch

## Automated Release Process (Recommended)

### Step 1: Create and Push Git Tag

```bash
# Navigate to project directory
cd /home/brito/code/geogram/geogram-desktop

# Create annotated tag with version and release notes
git tag v1.x.x -m "Release v1.x.x

Multi-platform Flutter application with:
- [List major changes]
- [New features]
- [Bug fixes]
"

# Push tag to trigger GitHub Actions
git push origin v1.x.x
```

**This triggers two workflows:**
- `build-windows.yml` - Builds Windows binaries
- `build-all-platforms.yml` - Builds Linux, Windows, macOS, and Web

### Step 2: Wait for GitHub Actions to Complete

Monitor build progress:

```bash
# Check workflow status
GIT_CONFIG_NOSYSTEM=1 gh run list --repo geograms/geogram-desktop --limit 5

# Watch specific run (use run ID from above)
GIT_CONFIG_NOSYSTEM=1 gh run watch <run-id> --repo geograms/geogram-desktop
```

Build typically takes **7-8 minutes** for all platforms.

### Step 3: Download Artifacts

Once builds complete successfully:

```bash
# Create directory for artifacts
mkdir -p release-artifacts
cd release-artifacts

# Find the run ID for the tag build
GIT_CONFIG_NOSYSTEM=1 gh run list --repo geograms/geogram-desktop --limit 5

# Download all artifacts (replace <run-id> with actual ID)
GIT_CONFIG_NOSYSTEM=1 gh run download <run-id> --repo geograms/geogram-desktop
```

This downloads:
- `geogram-desktop-windows-x64/geogram-desktop-windows-x64.zip` (~12 MB)
- `geogram-desktop-linux-x64/geogram-desktop-linux-x64.tar.gz` (~16 MB)
- `geogram-desktop-macos-x64/geogram-desktop-macos-x64.zip` (~52 MB)
- `geogram-desktop-web/geogram-desktop-web.tar.gz` (~11 MB)

### Step 4: Create GitHub Release

```bash
# Create release with binaries
GIT_CONFIG_NOSYSTEM=1 gh release create v1.x.x \
  --title "Geogram Desktop v1.x.x" \
  --notes "# Geogram Desktop v1.x.x

**Release summary here**

## What's New

- Feature 1
- Feature 2
- Bug fix 1

## Features

### Settings & Configuration
- ✅ **Profile Management** - NOSTR identity generation (npub/nsec keys, callsign)
- ✅ **Location Settings** - Interactive world map with IP-based geolocation
- ✅ **Relay Management** - Configure preferred and backup internet relays
- ✅ **Notifications** - Granular notification controls
- ✅ **About Page** - Project information and links

### Collections
- ✅ File browser with search and filtering
- ✅ Collection management
- ✅ File operations (download, view, organize)

### Technical Features
- 🔐 NOSTR protocol integration
- 🗺️ Interactive OpenStreetMap integration
- 💾 JSON-based configuration storage
- 📝 Comprehensive logging system
- 🎨 Material Design 3 theming

## Supported Platforms

- **Linux** (x64) - Full desktop support
- **Windows** (x64) - Full desktop support
- **macOS** (x64) - Full desktop support
- **Web** - Browser-based version
- **Android** - Mobile support
- **iOS** - Mobile support

## Installation

### Linux
See [INSTALL.md](https://github.com/geograms/geogram-desktop/blob/main/INSTALL.md)

### Windows
See [INSTALL_WINDOWS.md](https://github.com/geograms/geogram-desktop/blob/main/INSTALL_WINDOWS.md)

## Building from Source

See platform-specific build documentation:
- [BUILD_WINDOWS.md](https://github.com/geograms/geogram-desktop/blob/main/BUILD_WINDOWS.md)
- [README.md](https://github.com/geograms/geogram-desktop/blob/main/README.md)

## Links

- [GitHub Repository](https://github.com/geograms/geogram-desktop)
- [Documentation](https://github.com/geograms/geogram-desktop/tree/main/docs)
- [Report Issues](https://github.com/geograms/geogram-desktop/issues)
" \
  --repo geograms/geogram-desktop
```

### Step 5: Upload Binaries to Release

```bash
# Upload all platform binaries
GIT_CONFIG_NOSYSTEM=1 gh release upload v1.x.x \
  geogram-desktop-windows-x64/geogram-desktop-windows-x64.zip \
  geogram-desktop-linux-x64/geogram-desktop-linux-x64.tar.gz \
  geogram-desktop-macos-x64/geogram-desktop-macos-x64.zip \
  geogram-desktop-web/geogram-desktop-web.tar.gz \
  --repo geograms/geogram-desktop
```

### Step 6: Verify Release

```bash
# View release details
GIT_CONFIG_NOSYSTEM=1 gh release view v1.x.x --repo geograms/geogram-desktop

# Check in browser
xdg-open https://github.com/geograms/geogram-desktop/releases/tag/v1.x.x
```

### Step 7: Clean Up

```bash
# Remove downloaded artifacts
cd ..
rm -rf release-artifacts
```

## Quick Command Reference

### Complete Release Process (Copy-Paste Template)

```bash
# Set version number
VERSION="v1.x.x"

# 1. Create and push tag
cd /home/brito/code/geogram/geogram-desktop
git tag $VERSION -m "Release $VERSION

[Add release notes here]
"
git push origin $VERSION

# 2. Wait for builds (check every 2 minutes)
sleep 120
GIT_CONFIG_NOSYSTEM=1 gh run list --repo geograms/geogram-desktop --limit 3

# 3. Get run ID (when builds complete)
RUN_ID=$(GIT_CONFIG_NOSYSTEM=1 gh run list --repo geograms/geogram-desktop --limit 1 --json databaseId --jq '.[0].databaseId')
echo "Run ID: $RUN_ID"

# 4. Download artifacts
mkdir -p release-artifacts
cd release-artifacts
GIT_CONFIG_NOSYSTEM=1 gh run download $RUN_ID --repo geograms/geogram-desktop

# 5. Create release (edit notes as needed)
GIT_CONFIG_NOSYSTEM=1 gh release create $VERSION \
  --title "Geogram Desktop $VERSION" \
  --notes "[Add release notes]" \
  --repo geograms/geogram-desktop

# 6. Upload binaries
GIT_CONFIG_NOSYSTEM=1 gh release upload $VERSION \
  geogram-desktop-windows-x64/geogram-desktop-windows-x64.zip \
  geogram-desktop-linux-x64/geogram-desktop-linux-x64.tar.gz \
  geogram-desktop-macos-x64/geogram-desktop-macos-x64.zip \
  geogram-desktop-web/geogram-desktop-web.tar.gz \
  --repo geograms/geogram-desktop

# 7. Verify
GIT_CONFIG_NOSYSTEM=1 gh release view $VERSION --repo geograms/geogram-desktop

# 8. Clean up
cd ..
rm -rf release-artifacts

echo "✅ Release $VERSION published successfully!"
echo "🔗 https://github.com/geograms/geogram-desktop/releases/tag/$VERSION"
```

## Manual Release Process (Without GitHub Actions)

If you need to build locally without GitHub Actions:

### 1. Build All Platforms

**Linux:**
```bash
./rebuild-desktop.sh
cd build/linux/x64/release
tar -czf ../../../../geogram-desktop-linux-x64.tar.gz bundle/
cd ../../../..
```

**Windows:** (requires Windows machine or VM)
```cmd
build-windows.bat
cd build\windows\x64\runner\Release
powershell Compress-Archive -Path * -DestinationPath ..\..\..\..\..\geogram-desktop-windows-x64.zip
```

**macOS:** (requires macOS machine)
```bash
flutter build macos --release
cd build/macos/Build/Products/Release
zip -r ../../../../../geogram-desktop-macos-x64.zip geogram_desktop.app
```

**Web:**
```bash
flutter build web --release
tar -czf geogram-desktop-web.tar.gz build/web/
```

### 2. Create Release

```bash
git tag v1.x.x
git push origin v1.x.x

GIT_CONFIG_NOSYSTEM=1 gh release create v1.x.x \
  geogram-desktop-windows-x64.zip \
  geogram-desktop-linux-x64.tar.gz \
  geogram-desktop-macos-x64.zip \
  geogram-desktop-web.tar.gz \
  --title "Geogram Desktop v1.x.x" \
  --notes "[Release notes]" \
  --repo geograms/geogram-desktop
```

## Troubleshooting

### Build Failures

**Check build logs:**
```bash
GIT_CONFIG_NOSYSTEM=1 gh run view <run-id> --log-failed --repo geograms/geogram-desktop
```

**View full logs in browser:**
```
https://github.com/geograms/geogram-desktop/actions
```

### Release Creation Fails with 403

This happens when GitHub Actions lacks permissions. Create release manually:

```bash
# Create empty release
GIT_CONFIG_NOSYSTEM=1 gh release create v1.x.x \
  --title "Geogram Desktop v1.x.x" \
  --notes "[Release notes]" \
  --repo geograms/geogram-desktop

# Download and upload artifacts manually (see Step 3-5 above)
```

### Artifact Download Fails

If `gh run download` fails with permission errors:

```bash
# Download to home directory instead
cd ~
mkdir release-temp
cd release-temp
GIT_CONFIG_NOSYSTEM=1 gh run download <run-id> --repo geograms/geogram-desktop
```

### Updating an Existing Release

```bash
# Update release notes
GIT_CONFIG_NOSYSTEM=1 gh release edit v1.x.x \
  --notes "[New notes]" \
  --repo geograms/geogram-desktop

# Upload additional files
GIT_CONFIG_NOSYSTEM=1 gh release upload v1.x.x \
  new-file.zip \
  --repo geograms/geogram-desktop

# Delete and recreate release
GIT_CONFIG_NOSYSTEM=1 gh release delete v1.x.x --yes --repo geograms/geogram-desktop
# Then create new release
```

## Version Numbering

Follow semantic versioning (semver):

- **Major** (v2.0.0) - Breaking changes, major rewrites
- **Minor** (v1.1.0) - New features, backwards compatible
- **Patch** (v1.0.1) - Bug fixes, no new features

Examples:
- `v1.0.0` - Initial release
- `v1.1.0` - Added Meshtastic integration
- `v1.1.1` - Fixed Bluetooth connection bug
- `v2.0.0` - Complete UI redesign

## Pre-releases

For beta/alpha releases:

```bash
# Create pre-release
git tag v1.1.0-beta.1
git push origin v1.1.0-beta.1

GIT_CONFIG_NOSYSTEM=1 gh release create v1.1.0-beta.1 \
  --title "Geogram Desktop v1.1.0 Beta 1" \
  --notes "[Beta release notes]" \
  --prerelease \
  --repo geograms/geogram-desktop
```

## Checklist

Before creating a release:

- [ ] All tests passing
- [ ] Version number updated in relevant files
- [ ] CHANGELOG.md updated
- [ ] Documentation updated
- [ ] All changes committed and pushed
- [ ] Tag created and pushed
- [ ] GitHub Actions builds completed successfully
- [ ] Artifacts downloaded
- [ ] Release created
- [ ] Binaries uploaded and verified
- [ ] Release announcement posted (if applicable)

## Example: v1.0.0 Release

The v1.0.0 release was created using these exact steps:

```bash
# Tag created
git tag v1.0.0 -m "Initial release: Geogram Desktop v1.0.0
Multi-platform Flutter application..."
git push origin v1.0.0

# Builds triggered automatically
# Run ID: 19483527248

# Downloaded artifacts
mkdir release-artifacts
cd release-artifacts
GIT_CONFIG_NOSYSTEM=1 gh run download 19483527248 --repo geograms/geogram-desktop

# Created release
GIT_CONFIG_NOSYSTEM=1 gh release create v1.0.0 \
  --title "Geogram Desktop v1.0.0" \
  --notes "..." \
  --repo geograms/geogram-desktop

# Uploaded binaries
GIT_CONFIG_NOSYSTEM=1 gh release upload v1.0.0 \
  geogram-desktop-windows-x64/geogram-desktop-windows-x64.zip \
  geogram-desktop-linux-x64/geogram-desktop-linux-x64.tar.gz \
  geogram-desktop-macos-x64/geogram-desktop-macos-x64.zip \
  geogram-desktop-web/geogram-desktop-web.tar.gz \
  --repo geograms/geogram-desktop

# Verified
GIT_CONFIG_NOSYSTEM=1 gh release view v1.0.0 --repo geograms/geogram-desktop

# Result: https://github.com/geograms/geogram-desktop/releases/tag/v1.0.0
```

## Automation Scripts

You can create helper scripts for common tasks:

**`create-release.sh`:**
```bash
#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: ./create-release.sh v1.x.x"
  exit 1
fi

VERSION=$1
echo "Creating release $VERSION..."

# Create and push tag
git tag $VERSION -m "Release $VERSION"
git push origin $VERSION

echo "✅ Tag created and pushed"
echo "⏳ Waiting for builds to complete..."
echo "   Monitor at: https://github.com/geograms/geogram-desktop/actions"
```

**`upload-release-binaries.sh`:**
```bash
#!/bin/bash
set -e

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: ./upload-release-binaries.sh v1.x.x <run-id>"
  exit 1
fi

VERSION=$1
RUN_ID=$2

mkdir -p release-artifacts
cd release-artifacts
GIT_CONFIG_NOSYSTEM=1 gh run download $RUN_ID --repo geograms/geogram-desktop

GIT_CONFIG_NOSYSTEM=1 gh release upload $VERSION \
  geogram-desktop-windows-x64/geogram-desktop-windows-x64.zip \
  geogram-desktop-linux-x64/geogram-desktop-linux-x64.tar.gz \
  geogram-desktop-macos-x64/geogram-desktop-macos-x64.zip \
  geogram-desktop-web/geogram-desktop-web.tar.gz \
  --repo geograms/geogram-desktop

cd ..
rm -rf release-artifacts

echo "✅ Binaries uploaded to $VERSION"
```
