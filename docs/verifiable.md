# Verifiable Builds

## What Are Verifiable Builds

A verifiable (or reproducible) build means that anyone can take the source code, follow the same build steps, and produce a binary identical — or provably equivalent — to the one distributed. This matters because it closes the trust gap between "here's the source" and "here's the download": users and auditors can confirm that the released binary was actually built from the published source, with nothing added or changed.

Key references:

- [Reproducible Builds](https://reproducible-builds.org/) — the cross-project initiative defining the concept and best practices
- [F-Droid Reproducible Builds](https://f-droid.org/docs/Reproducible_Builds/) — how F-Droid independently verifies Android app builds
- [Signal's Reproducible Android Builds](https://signal.org/blog/reproducible-android/) — Signal's approach to verifiable builds for a messaging app

## How Geogram Achieves Verifiable Builds

### Pinned Flutter SDK

The file `.flutter-version` locks the exact Flutter version (currently 3.38.5). All CI workflows use `flutter-version-file: .flutter-version` to read from this single source of truth, and the local install script (`install-flutter.sh`) reads the same file. Changing the Flutter version in one place updates every build environment.

### Locked Dependencies

`pubspec.lock` is committed to the repository. This pins every direct and transitive Dart dependency to an exact version. Two builds from the same commit will resolve identical dependency trees.

### Deterministic Build Numbers

Build numbers are derived from `git rev-list --count HEAD`, which produces the same count for the same commit on any machine. No timestamps, no CI-specific counters, no values that vary between environments.

### Open CI Pipelines

All 8 GitHub Actions workflows live in `.github/workflows/` and are fully inspectable in the repository:

- `build-android.yml`
- `build-linux.yml`
- `build-windows.yml`
- `build-macos.yml`
- `build-ios.yml`
- `build-web.yml`
- `build-esp32.yml`
- `build-cli.yml`

Every build step is visible. Tagged releases trigger these workflows automatically.

### Source-Available

The complete source code is in the repository, including vendored third-party forks in `third_party/`. No binary blobs or precompiled components are pulled in at build time without corresponding source.

### F-Droid Compatible

F-Droid metadata in `fdroid/dev.geogram.yml` enables independent build verification by the F-Droid infrastructure, which builds apps from source and compares the result against the developer's published APK.

### Deterministic Archives

Release archives on Linux and CLI builds use `tar --sort=name --owner=0 --group=0 --mtime='1970-01-01'` to eliminate non-determinism from file ordering, ownership metadata, and timestamps. The same source files produce byte-identical archives.

### No Proprietary Build Steps

The build pipeline uses only open-source tooling. No closed-source compilers, no secret transforms, no steps that require proprietary software or services to reproduce.

## How to Verify a Build

To independently verify that a released binary matches the source:

1. **Clone at the release tag:**
   ```
   git clone https://github.com/geograms/geogram.git
   cd geogram
   git checkout v<version>
   ```

2. **Install the pinned Flutter version** listed in `.flutter-version`:
   ```
   # Using fvm (recommended)
   fvm install $(cat .flutter-version)
   fvm use $(cat .flutter-version)

   # Or manually install the exact version from https://flutter.dev/docs/get-started/install
   ```

3. **Run the platform build command:**
   ```
   # Linux
   flutter build linux --release

   # Android
   flutter build apk --release

   # See the relevant .github/workflows/ file for exact flags and environment setup
   ```

4. **Compare output hashes** with the released artifact:
   ```
   sha256sum build/linux/x64/release/bundle/geogram
   ```

If the hashes match, the binary was built from the published source with no modifications.

For the most precise reproduction, refer to the corresponding workflow file in `.github/workflows/` — it documents the exact OS image, dependencies, and build flags used for each platform's release build.
