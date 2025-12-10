# Publishing a New Version

This tutorial covers the complete process of committing changes, pushing to the repository, and publishing a new release version of Geogram Desktop.

## Quick Method: Using the Release Script

The easiest way to publish a new version:

```bash
./release.sh [version]
```

**Examples:**
```bash
./release.sh          # Auto-increment patch: 1.6.2 -> 1.6.3
./release.sh 1.7.0    # Specify version for minor/major bumps
./release.sh 2.0.0    # Major version bump
```

**The script automatically:**
- Reads the last version from `.version` file (or git tags as fallback)
- Auto-increments patch version if no version specified
- Collects all commit messages since the last release
- Updates `pubspec.yaml` with the new version
- Updates `CHANGELOG.md` with the collected changes
- Saves the new version to `.version` file
- Commits, pushes, and creates the release tag

**Version tracking:**
- The current version is stored in `.version` file in the project root
- This file is committed with each release
- Allows accurate version tracking independent of git tags

---

## Manual Method

If you prefer to run the steps manually, follow the sections below.

## Prerequisites

- Git installed and configured
- Push access to the repository
- All changes tested locally

## Step 1: Update the Version Number

Edit `pubspec.yaml` and update the version on line 19:

```yaml
version: X.Y.Z+1
```

**Version format:**
- `X.Y.Z` follows [Semantic Versioning](https://semver.org/):
  - `X` (major): Breaking changes or major new features
  - `Y` (minor): New features, backwards compatible
  - `Z` (patch): Bug fixes, small improvements
- `+1` is a placeholder build number (automatically replaced by CI/CD)

**Example:** To release version 1.7.0, change:
```yaml
version: 1.7.0+1
```

## Step 2: Update the Changelog

Edit `CHANGELOG.md` and add an entry at the top (after the title):

```markdown
## YYYY-MM-DD

### Added
- New feature description

### Changed
- Modified behavior description

### Fixed
- Bug fix description
```

Use the appropriate sections based on your changes.

## Step 3: Commit Your Changes

Stage and commit all changes with a descriptive message:

```bash
git add -A
git commit -m "Bump version to X.Y.Z, brief description of changes"
```

**Commit message conventions:**
- Start with "Bump version to X.Y.Z" for release commits
- Add a brief description of the main changes after the comma
- Examples:
  - `Bump version to 1.7.0, add offline map caching`
  - `Bump version to 1.6.3, fix BLE connection stability`

## Step 4: Push to Main Branch

Push your commits to the main branch:

```bash
git push origin main
```

This triggers CI/CD builds for all platforms but does **not** create a release yet.

## Step 5: Create and Push a Release Tag

Create a git tag with the `v` prefix and push it:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

**Example:**
```bash
git tag v1.7.0
git push origin v1.7.0
```

## Step 6: Automated Release Process

Once the tag is pushed, GitHub Actions automatically:

1. Detects the tag starting with `v`
2. Runs build workflows for all platforms in parallel:
   - Linux desktop (`geogram-linux-x64.tar.gz`)
   - macOS desktop (`geogram-macos-x64.zip`)
   - Windows desktop (`geogram-windows-x64.zip`)
   - Web (`geogram-web.tar.gz`)
   - Android (`geogram.apk`, `app-release.aab`)
   - iOS (`geogram-ios-unsigned.ipa`)
   - CLI (`geogram-cli-linux-x64.tar.gz`)
3. Calculates the build number from git commit count
4. Creates a GitHub Release with all artifacts attached

## Step 7: Add Release Notes (Optional but Recommended)

After the release is created:

1. Go to the repository's **Releases** page on GitHub
2. Find the newly created release (tagged `vX.Y.Z`)
3. Click **Edit**
4. Add release notes summarizing the changes
5. Click **Update release**

## Quick Reference

Complete release in one sequence:

```bash
# After updating pubspec.yaml and CHANGELOG.md
git add -A
git commit -m "Bump version to X.Y.Z, description"
git push origin main
git tag vX.Y.Z
git push origin vX.Y.Z
```

## Monitoring the Build

To check the build status:

1. Go to the repository on GitHub
2. Click the **Actions** tab
3. Find the workflows triggered by your tag push
4. All 7 workflows should show green checkmarks when complete

## Troubleshooting

### Build Fails
- Check the Actions tab for error logs
- Common issues: dependency conflicts, test failures
- Fix the issue, then create a new patch version

### Tag Already Exists
If you need to re-release the same version:
```bash
git tag -d vX.Y.Z              # Delete local tag
git push origin :refs/tags/vX.Y.Z  # Delete remote tag
git tag vX.Y.Z                 # Recreate tag
git push origin vX.Y.Z         # Push new tag
```

### Android Signing Issues
Android release builds require signing secrets configured in GitHub:
- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`
- `ANDROID_STORE_PASSWORD`

Contact the repository administrator if these are missing.

## Version History Example

From recent releases:
```
v1.6.2 - DM delivery via signed NOSTR events
v1.6.1 - App format specifications
v1.6.0 - BLE parcel compression and messaging improvements
```
