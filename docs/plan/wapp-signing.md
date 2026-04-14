# Wapp signing — NOSTR-backed per-developer authenticity chain

## Context

Today every wapp in `/home/brito/code/geograms/geogram` is trusted by fiat. The iwi launcher (`iwi/lib/main.dart` `_scanArchiveBody`) reads `manifest.json`, hands `app.wasm` to `wasm_run_flutter` via `_WappPageState._loadWapp`, and never checks who produced the files. There is no notion of an "author", no signature field, no verification at install or launch. A tampered `app.wasm` — either swapped on disk or arriving from a stranger through a future third-party install flow — would run indistinguishably from a legitimate one. App Creator can edit and reinstall any wapp (including built-ins) without leaving any fingerprint of who made the change.

The goal:

1. Every wapp carries a cryptographic signature proving which developer produced its current on-disk content.
2. Signatures are **NOSTR** — identity is an `npub`, signature is BIP-340 Schnorr made by the developer's `nsec`.
3. **When anyone modifies a wapp (metadata, UI, source, recompile), the previous signature is replaced by one made with the editing developer's key.** Automatic, not a separate step.
4. Built-in wapps under `wapps/archive/*` keep working during the transition even though they were never signed before.

### Prerequisite: profiles must exist first

**This plan depends on the profile concept landing in iwi first.** The iwi launcher today has no user profiles — `PreferencesService` is a single global shared_preferences store, there is one `installedAppsStorage()` folder shared by all users of the machine, and there is nothing resembling an identity. Wapp signatures have to be tied to **a developer**, not to the machine; that developer is a profile.

The profile work is out of scope for this document but is **a hard blocker** on everything below. When the profile feature ships it must deliver:

- A `Profile` object with (at minimum) a display name, a stable id, and a `ProfileStorage` rooted under `~/.local/share/geogram/profiles/<profile-id>/`.
- A current-profile selector somewhere in the launcher chrome.
- Per-profile `PreferencesService` so settings (including the new `wapp.signing.nsec` key described below) are scoped, not global.
- Per-profile `installedAppsStorage()` so each profile's `apps/` directory is its own space.
- A lifecycle event on profile switch that both the launcher grid and the signing service subscribe to, so UI and cached identity flip atomically.

Wapp signing plugs directly into that scaffold: the signing `nsec` is **stored on the profile**, so one machine can host several developer identities (a "personal" profile and a "work" profile each sign their own wapps with their own keys). When the user switches profiles, the identity shown in App Creator's Settings tab and the key used by the installer both switch with them.

Everything below this line assumes the profile plan has already landed. Dates in this plan treat profiles as a phase-0 blocker; until phase 0 ships, none of the signing code should be written.

### Infrastructure we can reuse

The parent geogram project already ships a complete, battle-tested NOSTR stack at `lib/util/`:

- `nostr_crypto.dart` — BIP-340 x-only Schnorr, bech32 `npub`/`nsec` encode/decode, keypair generation.
- `nostr_event.dart` — NIP-01 canonical `[0, pubkey, created_at, kind, tags, content]` serialisation, `calculateId` (SHA256), `NostrEvent.sign` / `NostrEvent.verify`.
- `nostr_nip19.dart` — NIP-19 bech32 decoding for `note`/`npub`/`nevent`/`nprofile`/`naddr`.
- `nostr_key_generator.dart` — wraps the above into an ergonomic `NostrKeys(npub, nsec, callsign)` tuple.

All pure Dart. Depends on `crypto`, `pointycastle`, `bech32`, `hex` — none of which are currently in `iwi/pubspec.yaml`. The security model doc at `docs/apps/security-model.md` already specifies Layer 3 "NOSTR-based code signing" in draft form, so the direction is pre-approved at design level; this plan makes it real.

### Outcome after Phase 1

Every install produces a `signature.json` sidecar signed with the current profile's auto-generated identity. Load time catches any tamper with a friendly banner. App Creator's Settings tab shows the developer their own `npub`. The `WappManifest` in `iwi/lib/main.dart` carries a verification verdict ready for the Phase 2 launcher-grid badges.

## Approach

### What gets signed

A **hash manifest**: a JSON map of `relative-path → sha256-hex` covering every regular file in the wapp folder **except** `signature.json` itself. Keys are sorted lexicographically; the JSON is written with no whitespace and no trailing newline — a deterministic canonical form.

The schnorr signature is a NIP-78 `kind:30078` `NostrEvent` whose `content` is the hex of the SHA256 of those canonical bytes. Reusing a real `NostrEvent` (not a bare signature) means the signature blob is **publishable to any NOSTR relay later** (Phase 3) with zero format change. Every verifier on the planet that knows how to check a NIP-01 event can check our wapp signature.

### Signature file — `signature.json` at the wapp root

```json
{
  "schema": "geogram.wapp.signature/1",
  "wapp_id": "team.geogram.app-creator",
  "wapp_version": "1.2.0",
  "signed_at": 1744588800,
  "publisher_npub": "npub1…",
  "publisher_hex": "9c1a…f3",
  "hash_algo": "sha256",
  "manifest_digest_hex": "e3b0c4…",
  "hashes": {
    "app.wasm":                 "9f12…",
    "main.c":                   "77ab…",
    "manifest.json":            "3a7b…",
    "media/icons/icon.svg":     "11ee…",
    "screens/home.ui.json":     "c0ed…"
  },
  "event": {
    "id":          "4f2a…",
    "pubkey":      "9c1a…f3",
    "created_at":  1744588800,
    "kind":        30078,
    "tags": [
      ["d",                 "geogram.wapp:team.geogram.app-creator"],
      ["t",                 "geogram-wapp-signature"],
      ["wapp_id",           "team.geogram.app-creator"],
      ["wapp_version",      "1.2.0"],
      ["manifest_digest",   "e3b0c4…"]
    ],
    "content": "e3b0c4…",
    "sig":     "a1b2…64bytes"
  }
}
```

The **authoritative** proof is `event.sig` over `event.id`. Everything else is ergonomic — the verifier recomputes `manifest_digest` from disk, asserts it equals `event.content` and the `manifest_digest` tag, then Schnorr-verifies the event against `event.pubkey`. One check subsumes file integrity + publisher authenticity.

**Why sidecar and not folded into `manifest.json`:** no recursion (`manifest.json` is in the hash list, `signature.json` is not), survives anything that validates `manifest.json` shape, one discoverable filename per folder, matches the sidecar pattern the installer already uses for `media/icons/icon.svg`.

### Per-profile identity

Stored **on the active profile's `PreferencesService`** under the key `wapp.signing.nsec`. First read generates a fresh `NostrKeys` via `NostrKeyGenerator.generateKeyPair()`, writes the hex nsec to profile prefs, returns it. Subsequent reads just decode. Regenerate is a one-line `prefs.remove('wapp.signing.nsec')`.

No import/backup UI in Phase 1 — the field is there, the UI is Phase 2. The **profile switch event** (delivered by the profile system) invalidates the cached `NostrKeys` so the next signing call reads the new profile's key.

### Built-in exemption

`wapps/archive/*` wapps have no signatures and adding them now leaks a team key into every dev checkout. Instead: in `_scanArchiveBody`, wapps discovered via the archive-path branch are marked `isBuiltin = true` on `WappManifest`, and both the installer and the load-time verifier skip them. Phase 3 adds a `bin/sign_builtins.dart` release tool that wires a team key at tag/release time. Until then, built-ins are "system-trusted, unverified".

### Verification points

| Point | Behaviour |
|---|---|
| **Install** | Installer signs its own output. Write of `signature.json` is best-effort in Phase 1 — a crypto failure logs but does not fail the install. Phase 2 promotes to fatal. |
| **Scan** (`_scanArchiveBody`) | Each non-builtin wapp gets a `VerificationResult` computed and attached to its `WappManifest`. Stored but not rendered in Phase 1. |
| **Load** (`_WappPageState._loadWapp`) | Between `readBytes('app.wasm')` and `_engine.load(...)`: if state is `tampered`/`broken` → render a warning banner in the existing `_status` area with a "Load anyway" button; do NOT call `_engine.load` until the user confirms. `unsigned` → silent pass + debug log. `verified`/`selfSigned` → silent pass. Built-ins short-circuit the whole path. |

---

## Files to modify or create

Assumes profiles (phase 0) has already landed and `PreferencesService`, `installedAppsStorage()`, and any profile lifecycle events exist in their per-profile form.

| Purpose | Path | Change |
|---|---|---|
| Vendor NOSTR primitives | `iwi/lib/util/nostr_crypto.dart` | **New** — verbatim copy from `lib/util/nostr_crypto.dart`. Header comment: "Vendored from geogram/lib/util/; keep in sync manually until a shared package lands." |
| Vendor NOSTR primitives | `iwi/lib/util/nostr_event.dart` | **New** — copy, **stripped** of the `NostrEvent.alert` factory plus its `../models/report.dart` import (the only external dep). |
| Vendor NOSTR primitives | `iwi/lib/util/nostr_nip19.dart` | **New** — verbatim copy. |
| Vendor NOSTR primitives | `iwi/lib/util/nostr_key_generator.dart` | **New** — verbatim copy. |
| Signing service | `iwi/lib/services/wapp_signing_service.dart` | **New**. Key management + signing. Methods: `getOrCreateIdentity()`, `exportNpub()`, `exportNsec()`, `regenerateIdentity()`, `computeHashes(ProfileStorage pkg)` (recursive walk via `listDirectory(recursive: true)`, SHA256 each file, skip `signature.json`), `canonicalManifestBytes(Map<String, String>)`, `signWapp({required pkg, required wappId, required wappVersion})` — returns the full `signature.json` map ready to write. Subscribes to the profile-switch event and clears its cached keys. |
| Verification service | `iwi/lib/services/wapp_verification_service.dart` | **New**. Read-only: `verifyPackage(ProfileStorage pkg)` → `VerificationResult`, `isBuiltinPath(String basePath)`. `VerificationResult` is a small immutable sum type local to this file with states `verified`, `selfSigned`, `unsigned`, `tampered`, `broken`, plus optional `publisherNpub` and `error`. |
| Preferences accessor | `iwi/lib/services/preferences_service.dart` | Add `String? get wappSigningNsec` / `set wappSigningNsec(String?)` following the same shape as the existing `wappDataDir` getter/setter. Key: `wapp.signing.nsec`. Must be per-profile (phase 0 prerequisite). |
| Installer integration | `iwi/lib/services/wapp_installer_service.dart` | Add optional `bool sign = true` parameter to `installFromCompiled`. After all files are written and **before** `EventBus().fire(WappLoadedEvent(...))`, call `WappSigningService.instance.signWapp(...)` against the just-written folder and write `$folder/signature.json`. Best-effort try/catch in Phase 1. |
| Launcher manifest extension | `iwi/lib/main.dart` | Extend `WappManifest` with `final bool isBuiltin` and `final VerificationResult? verification`. `_scanArchiveBody` marks archive-scanned wapps `isBuiltin: true, verification: null`; installed wapps call `WappVerificationService.instance.verifyPackage(pkg)` and attach the result. No UI change yet. |
| Load-time check | `iwi/lib/wapp/wapp_page.dart` | In `_loadWapp`, between `wasmBytes = await _pkg.readBytes('app.wasm')` and `await _engine.load(wasmBytes)`: if built-in or verification clean → proceed; if tampered/broken → render the warning banner with "Load anyway" and gate `_engine.load` on the user's choice. |
| App Creator Settings UI | `iwi/lib/wapp/wapp_page.dart` | In the App Creator editor's Settings tab, add a "Signing identity" `ListTile` group with three rows: current `npub1…` (copyable), a Regenerate button, and a hidden-behind-long-press "Show nsec" row. Reads from `WappSigningService.instance.getOrCreateIdentity()`. |
| Docs | `docs/apps/security-model.md` | Update Layer 3 to describe the actual `signature.json` schema, the verification points, and the built-in exemption. Remove the draft language. |

### Pubspec additions — `iwi/pubspec.yaml`

```yaml
  # NOSTR signing for wapp packages (primitives vendored from parent lib/util)
  crypto: ^3.0.3
  pointycastle: ^3.9.1
  bech32: ^0.2.2
  hex: ^0.2.0
```

No dev_dependency additions. No `dependency_overrides`. No `path:` deps. All four are pure Dart with no native plugins.

---

## Reused components (do not re-implement)

- **`NostrCrypto.generateKeyPair / schnorrSign / schnorrVerify / encodeNpub / decodeNpub`** at `lib/util/nostr_crypto.dart` — BIP-340 x-only Schnorr plus bech32 identity encoding. Vendored into `iwi/lib/util/nostr_crypto.dart`.
- **`NostrEvent.calculateId / sign / verify`** at `lib/util/nostr_event.dart` — NIP-01 canonical serialisation and event-ID computation. Vendored into `iwi/lib/util/nostr_event.dart` (minus the `alert` factory and its `report.dart` import).
- **`NostrKeyGenerator.generateKeyPair`** at `lib/util/nostr_key_generator.dart` — wraps `NostrCrypto` into `(npub, nsec, callsign)` tuples. Vendored.
- **`ProfileStorage.listDirectory(relativePath, recursive: true)`** already implemented in `iwi/lib/services/profile_storage.dart` (abstract at line 66, filesystem impl at line 220, scoped impl at line 373). The hasher walks the folder with this and does not touch `dart:io` directly.
- **`ProfileStorage.readBytes / writeJson / readJson`** — file I/O for the installer and verifier.
- **`PreferencesService`** — shared_preferences wrapper. Follow the existing `wappDataDir` getter/setter pattern for `wappSigningNsec`. Must be per-profile once phase 0 lands.
- **`WappInstallerService.installFromCompiled`** — already the single choke-point for wapp writes. Sign at the end of the try-block, just before the event fire.
- **`_scanArchiveBody` archive vs installed branching** — already distinguishes source-tree wapps from installed ones; add a boolean flag rather than re-detecting later.
- **`_WappPageState._status` area** — already the place we surface load errors (`app.wasm not found`, etc.). The tamper banner slots in without adding a new UI surface.

---

## Verification (manual test plan)

Run from the iwi folder via `./launch-desktop.sh`, per `CLAUDE.md`:

1. **Fresh install produces a signature.** Open App Creator → Create new wapp → Title "hello" → Compile → Install. Check `~/.local/share/geogram/profiles/<profile>/apps/hello/signature.json` exists and contains a `publisher_npub` starting with `npub1`.
2. **Re-open is silent.** Close and re-open "hello" from the launcher grid. Wapp loads without any warning banner.
3. **Tampered UI triggers banner.** With iwi closed, add a stray character to `apps/hello/screens/home.ui.json`. Relaunch, click "hello" → banner "Signature mismatch — file modified since install" with Load anyway / Cancel. Cancel aborts; Load anyway proceeds.
4. **Tampered wasm triggers banner.** Repeat step 3 but flip one byte in `app.wasm`. Same banner.
5. **Tampered signature triggers banner.** Edit one hex character in `signature.json`. Same banner.
6. **Re-install restores verification.** With tampered "hello" still on disk, open App Creator → Edit → change nothing → Install. The new signature from the editor's key overwrites the bad one. Next launch is silent.
7. **Editor identity rotation re-signs.** In App Creator Settings → Signing identity → Regenerate → confirm the `npub` string changes. Install "hello" again. `signature.json:publisher_npub` matches the new identity.
8. **Profile switch changes the signer.** Switch to a second profile. Open App Creator, install a new wapp. Its `signature.json:publisher_npub` must be different from the first profile's. Switch back — the first profile's wapps still verify with the original npub.
9. **Cross-identity editing.** Copy a signed wapp into `apps/` under a different folder name by hand (simulates a second developer's install). Load it → `verifyPackage` returns `selfSigned` (signature valid, publisher not-yet-trusted). No banner in Phase 1. Edit + install → re-signed with the current profile's identity.
10. **Built-in exemption stays quiet.** Delete `apps/tasks/`, relaunch. `_scanArchiveBody` finds the built-in at `wapps/archive/tasks/`, marks `isBuiltin: true`, skips verification, no `signature.json` is written or expected, load is silent.
11. **Legacy unsigned install is permissive.** On disk, delete only `signature.json` from "hello". Relaunch → load proceeds silently with a debug log line (Phase 1 policy: unsigned ≠ blocked).
12. **Static checks stay clean.** `dart analyze` across the touched files reports zero new issues; `flutter build linux --debug` succeeds; runtime launch has no new stderr.

---

## Out of scope / follow-ups

**Phase 0 (blocks everything in this plan) — profiles.** Implement the profile concept: `Profile` object, per-profile `PreferencesService`, per-profile `installedAppsStorage()`, profile picker in launcher chrome, profile lifecycle event. Tracked in a separate plan.

**Phase 1 — MVP signing (this plan).** Vendored crypto, signing on install, `signature.json` sidecar, load-time tamper warning, App Creator Settings identity row, built-in exemption, docs update.

**Phase 2 — polish.**
- Launcher grid badges: small coloured glyph in the corner of each `_AppIcon` tile — green check (`verified` or `selfSigned`), yellow triangle (`unsigned`), red cross (`tampered`/`broken`). Tooltip shows the publisher `npub` when present.
- Trusted-publisher list in `PreferencesService` (`wapp.signing.trusted`). Add/remove from a Settings wapp. When a loaded wapp's publisher is in the list, verification state becomes `verifiedTrusted` and the badge flips to a blue shield.
- `nsec` import UI: paste field with validation via `NostrCrypto.decodeNsec`, plus a "scan QR" affordance for future mobile.
- Strict-load toggle: when on, `tampered`/`unsigned` wapps refuse to load instead of showing the override banner.
- Promote installer signing failures from best-effort to fatal (`InstallResult.failure`).
- "Sign all legacy installs" migration prompt on first launch after upgrade.

**Phase 3 — ecosystem.**
- `bin/sign_builtins.dart` release tool: reads a team `nsec` from env, signs every `wapps/archive/*/` folder with it, writes the resulting `signature.json` into the source tree. CI hook fires on tag push.
- Hardcoded geogram-team `npub` in `iwi/lib/main.dart` as the trust anchor for built-ins, flipping the built-in exemption into a real verification pass.
- Relay republish: a background task that fetches kind-30078 signature events for installed wapps and updates the local cache, enabling publisher revocation / key rotation attestations.
- Wapp store UI filtered by publisher npub or NIP-05 callsign.

**Explicitly deferred forever unless revisited:** any attempt to sign the wasm binary at compile time via a per-module custom section. The sidecar approach is simpler, more inspectable, and survives re-packaging.
