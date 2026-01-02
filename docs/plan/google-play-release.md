# Google Play Store Release Plan for Geogram

## Current Status

### Already Set Up
- Android build configuration with signing (`android/app/build.gradle.kts`)
- Release keystore (`android/app/keystore/release.jks`)
- GitHub Actions builds AAB on every tag (`.github/workflows/build-android.yml`)
- Fastlane metadata: title, descriptions, icon, feature graphic, 5 screenshots
- Apache 2.0 license

### Missing for Google Play
- Google Play Console account ($25 registration) and app listing
- Service account JSON key for API access
- Fastlane Appfile and Fastfile
- Privacy policy (need to create and host)
- CI/CD step to upload to Play Store (automated)

---

## Steps to Release on Google Play

### Step 1: Google Play Console Setup (Manual)

1. **Create Developer Account** (if not exists)
   - Go to https://play.google.com/console
   - Pay $25 one-time registration fee
   - Complete identity verification

2. **Create App Listing**
   - Click "Create app"
   - App name: Geogram
   - Default language: English (US)
   - App type: App (not game)
   - Free or paid: Free

3. **Complete Store Listing**
   - Short description: Already in `fastlane/metadata/android/en-US/short_description.txt`
   - Full description: Already in `fastlane/metadata/android/en-US/full_description.txt`
   - App icon: Already in `fastlane/metadata/android/en-US/images/icon.png`
   - Feature graphic: Already in `fastlane/metadata/android/en-US/images/featureGraphic.png`
   - Screenshots: Already in `fastlane/metadata/android/en-US/images/phoneScreenshots/`

4. **Content Rating**
   - Complete IARC questionnaire
   - Expected rating: Everyone (no violent/adult content)

5. **Privacy Policy**
   - Create and host at: `https://geogram.radio/privacy`
   - Required content: Data collection, usage, third parties, contact
   - See Step 6 below for privacy policy template

### Step 2: Create Service Account for API Access

1. **In Google Cloud Console** (https://console.cloud.google.com):
   - Create a new project or select existing one
   - Go to "APIs & Services" > "Library"
   - Search for "Google Play Android Developer API"
   - Click "Enable"
   - Go to "APIs & Services" > "Credentials"
   - Click "Create Credentials" > "Service Account"
   - Name it something like "geogram-play-deploy"
   - Click "Create and Continue"
   - Skip the optional steps, click "Done"
   - Click on the service account you just created
   - Go to "Keys" tab > "Add Key" > "Create new key"
   - Select JSON format
   - Download and save the JSON file securely

2. **In Play Console** (https://play.google.com/console):
   - Go to "Settings" (gear icon) > "API access"
   - Click "Link" next to Google Cloud project (or create new link)
   - Find your service account in the list
   - Click "Grant access"
   - Under "App permissions", add your app
   - Under "Account permissions", select:
     - "Release apps to testing tracks"
     - "Release apps to production" (if you want full automation)
   - Click "Invite user"
   - Accept the invitation

3. **Store securely as GitHub Secret**:
   - Go to your GitHub repo > Settings > Secrets and variables > Actions
   - Click "New repository secret"
   - Name: `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`
   - Value: Paste the entire contents of the JSON key file
   - Click "Add secret"

### Step 3: Create Fastlane Configuration

**File: `fastlane/Appfile`**
```ruby
package_name("dev.geogram")
json_key_file("fastlane/play-store-key.json")
```

**File: `fastlane/Fastfile`**
```ruby
default_platform(:android)

platform :android do
  desc "Upload to Google Play internal track"
  lane :internal do
    upload_to_play_store(
      track: 'internal',
      aab: '../build/app/outputs/bundle/release/app-release.aab',
      skip_upload_metadata: false,
      skip_upload_images: true,
      skip_upload_screenshots: true
    )
  end

  desc "Promote to production"
  lane :production do
    upload_to_play_store(
      track: 'production',
      aab: '../build/app/outputs/bundle/release/app-release.aab'
    )
  end
end
```

**File: `fastlane/Gemfile`**
```ruby
source "https://rubygems.org"

gem "fastlane"
```

### Step 4: Update GitHub Actions for Automated Uploads

The workflow will automatically upload to Google Play when you push a version tag.

**How it works:**

1. You push a tag like `v1.6.76`
2. GitHub Actions builds the AAB (already configured)
3. Fastlane uploads the AAB to Play Store internal track
4. You promote from internal to production in Play Console (or automate later)

**Changes to `.github/workflows/build-android.yml`:**

Add these steps after the existing "Upload AAB to Release" step:

```yaml
    # Install Ruby and Fastlane
    - name: Set up Ruby
      if: startsWith(github.ref, 'refs/tags/v')
      uses: ruby/setup-ruby@v1
      with:
        ruby-version: '3.2'
        bundler-cache: true
        working-directory: fastlane

    # Upload to Google Play Store
    - name: Upload to Google Play
      if: startsWith(github.ref, 'refs/tags/v')
      env:
        GOOGLE_PLAY_SERVICE_ACCOUNT_JSON: ${{ secrets.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON }}
      run: |
        # Write the service account JSON to a file
        echo "$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON" > fastlane/play-store-key.json

        # Run Fastlane to upload to internal track
        cd fastlane
        bundle exec fastlane internal

        # Clean up the key file
        rm -f play-store-key.json
```

**Tracks explanation:**
- `internal` - Only visible to internal testers you specify (immediate, no review)
- `alpha` - Closed testing with limited testers
- `beta` - Open testing, anyone can join
- `production` - Public release (may require review)

Starting with `internal` is safest - you can test before promoting to production.

### Step 5: First Manual Upload

For the first release, Google requires a manual upload:

1. Build AAB locally: `flutter build appbundle --release`
   - Or download from GitHub Actions artifact
2. Go to Play Console > Your app > Production > Create new release
3. Upload the AAB file (`build/app/outputs/bundle/release/app-release.aab`)
4. Add release notes
5. Complete all required store listing fields
6. Submit for review

After the first upload is approved, automated uploads will work.

### Step 6: Create Privacy Policy

Create and host the privacy policy at `https://geogram.radio/privacy`:

```markdown
# Geogram Privacy Policy

Last updated: [DATE]

## Overview
Geogram is a peer-to-peer mesh networking application. We prioritize your privacy
and designed the app to minimize data collection.

## Data Collection
Geogram does NOT collect, store, or transmit any personal data to external servers.
- No analytics or tracking
- No user accounts required
- No data sent to our servers

## Local Data Storage
The app stores the following data locally on your device:
- Your callsign/identity (chosen by you)
- Cryptographic keys (generated locally)
- Messages, places, events, and other content you create
- Cached map tiles for offline use
- Connection history with other devices

## Peer-to-Peer Communication
When communicating with other devices:
- Data is transmitted directly between devices via WiFi, Bluetooth, or WebRTC
- Messages are cryptographically signed to verify sender identity
- No central server processes or stores your communications

## Permissions
The app requests permissions for:
- Location: To show your position on maps and enable location-based features
- Bluetooth: For peer-to-peer device discovery and communication
- Network: For WiFi-based communication and optional internet connectivity
- Notifications: To alert you of incoming messages
- Camera: For capturing photos to attach to messages (optional)

## Third-Party Services
Geogram does not use any third-party analytics, advertising, or tracking services.
Map tiles may be fetched from OpenStreetMap servers when online.

## Data Sharing
We do not sell, trade, or share your data with third parties.

## Contact
For privacy questions: brito_pt@pm.me
Website: https://geogram.radio
Source code: https://github.com/geograms/geogram

## Changes
We may update this policy. Check this page for the latest version.
```

---

## Summary: Files to Create

| File | Purpose |
|------|---------|
| `fastlane/Appfile` | Package name and credentials |
| `fastlane/Fastfile` | Upload lanes |
| `fastlane/Gemfile` | Ruby dependencies |
| `docs/privacy-policy.md` | Privacy policy document |
| `.github/workflows/build-android.yml` | Add Play Store upload step |

## GitHub Secrets Required

| Secret | Description |
|--------|-------------|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Service account JSON key content |

## Manual Steps Checklist

- [ ] Register Google Play Developer account ($25) - https://play.google.com/console
- [ ] Create app in Play Console
- [ ] Create Google Cloud project and enable Play Developer API
- [ ] Create service account and download JSON key
- [ ] Link service account to Play Console with permissions
- [ ] Add `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` secret to GitHub
- [ ] Upload first AAB manually via Play Console
- [ ] Host privacy policy at public URL
- [ ] Complete IARC content rating questionnaire
- [ ] Submit for review

## Notes

- First upload must be manual via Play Console
- Subsequent releases can be automated via Fastlane
- Google review typically takes 1-3 days for new apps
- Use internal track for testing before promoting to production
- Keep the same signing key forever (already have `release.jks`)
- The signing key must match for all future updates
