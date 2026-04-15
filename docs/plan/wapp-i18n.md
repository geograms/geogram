# Wapp multi-lingual support — per-wapp translation sidecars

## Context

Every string visible in a wapp today is hard-coded. Labels, tips, button text, help strings, `hal_log` output — all English, all baked into either `screens/*.ui.json` or `main.c`. There is no runtime hook for localization. End users cannot switch a wapp into Portuguese or German; even if geogram itself grows a language picker, the wapps it hosts will still only speak English.

The parent geogram project already ships an `I18nService` at `lib/services/i18n_service.dart` that reads flat JSON maps from `languages/<locale>/<feature>.json` (e.g. `languages/pt_PT/work.json`) and looks strings up by key. It was designed for the monolithic app — all features hardcoded, no wapps — so it's not a fit for wapps that ship their own translations inside their `.wapp` archive.

**Goal:** every wapp can ship its own translation files inside its package, the user picks a language in iwi's Settings, and the GeoUI renderer + the HAL both translate on the fly. Wapps fall back gracefully when a key is missing.

## Approach

### File layout inside a wapp package

```
wapps/archive/<name>/
  manifest.json
  app.wasm
  main.c
  signature.json
  screens/
    home.ui.json
  media/
    icons/icon.svg
  lang/                  ← NEW
    en.json
    pt.json
    de.json
    fr.json
```

`lang/<locale>.json` is a flat `{"key": "localized string"}` map. Locale codes are short ISO 639-1 tags (`en`, `pt`, `de`) with optional region suffix (`pt_BR`, `en_US`). The wapp chooses which region suffixes it ships; the resolver falls back gracefully when the exact tag is missing.

`lang/` travels with the `.wapp` archive exactly like `media/` or `screens/`, so the installer's existing `unzip -d apps/<folder>` does the right thing with zero changes.

### Translation keys — `@key` sentinels in GeoUI

The UI files stay English-authored, but any string attribute can be prefixed with `@` to flag it as a translation key:

```json
{
  "$": "field",
  "name": "wapp_title",
  "$type": "string",
  "label": "@settings.title_label",
  "tip": "@settings.title_tip",
  "default": "@settings.title_default"
}
```

At render time, `GeoUiScreenRenderer` resolves every string attribute through a new `I18n.lookup(key, fallback)` helper. A string that starts with `@` is looked up in the active locale's map; anything else is passed through untouched (including existing wapps that haven't been translated yet — full backwards compatibility).

Fallback chain: `<exact tag>` → `<language only>` → `en` → the key itself (with the `@` stripped) shown as-is.

### Wapp-side HAL — `hal_i18n_get`

The same translation table is available to `main.c` via a new HAL function:

```c
uint32_t hal_i18n_get(const char *key, uint32_t key_len,
                      char *out, uint32_t out_cap);
```

Returns the number of bytes written (not counting the null). The wapp calls it like this:

```c
char buf[128];
uint32_t n = hal_i18n_get("store.fetching", 14, buf, sizeof(buf));
if (n > 0) send_output(buf, "info");
else send_output("Fetching...", "info"); /* fallback */
```

Usually wrapped in a tiny `t()` helper per wapp. The host-side implementation of `hal_i18n_get` reads from the same per-wapp translation map the GeoUI renderer uses, so UI and C code stay in sync.

### Locale selection

Stored in `iwi/lib/services/preferences_service.dart` under the key `locale`. First-run default comes from `Platform.localeName` (e.g. `pt_PT`). A new row in iwi's Settings page lets the user pick any locale from a hard-coded short list (matching what the parent I18nService supports today: `en`, `pt`, `de`) plus an "Auto" option that follows the OS.

On change, a new `LocaleChangedEvent` fires on the EventBus. The launcher and every open `WappPage` listen and reload their translations. Switching languages mid-session rebuilds the active wapp's screens without requiring a restart.

### Translation loading

`WappPage._loadWapp` gains a step: after reading `manifest.json` and parsing `screens/*.ui.json`, it loads the active locale's `lang/*.json`:

```dart
final locale = PreferencesService.instance.activeLocale();
final langFile = _resolveLangFile(locale);           // e.g. "lang/pt.json"
_translations = await _pkg.readJson(langFile) ?? {};
```

`_translations` is a `Map<String, String>` scoped to the current wapp engine. The engine exposes it to the HAL (`hal_i18n_get` reads it), to the GeoUI renderer (via a new `I18nContext` passed through `GeoUiBindings`), and to the terminal / catalog output parsers.

### GeoUI renderer integration

`GeoUiScreenRenderer` gains an `I18nContext` parameter (or absorbs one via the bindings). Every `label`, `tip`, `hint`, `text` (for `$:"label"` blocks), and `default` (for string fields) is passed through `I18nContext.resolve(raw)`:

```dart
String resolve(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  if (!raw.startsWith('@')) return raw;
  final key = raw.substring(1);
  return _translations[key] ?? _fallbackTranslations[key] ?? key;
}
```

Non-`@` strings short-circuit immediately, so untranslated wapps have zero overhead.

### App Creator tooling

App Creator grows a new "Translations" tab (or a section in the UI tab's inspector) that:

1. **Scans** the current `source_ui` JSON for every `@key` reference.
2. **Shows a table** — one row per key, one column per locale the wapp ships.
3. **Auto-extracts**: a button that walks the UI tree and replaces a selected literal string with a fresh `@generated-key-N` placeholder, adding it to `lang/en.json`.
4. **Writes on Install** — the installer carries `lang/*.json` into `apps/<folder>/` along with `screens/` and `media/`.

Phase 1 does not need this tooling — authors can hand-edit `lang/*.json` in the Code view. Phase 2 adds the translations tab.

### Installer changes

`WappInstallerService.installFromCompiled` gains an optional `Map<String, Map<String, String>> translations` parameter. When present, it writes each map as `apps/<folder>/lang/<locale>.json`. When absent, it skips (or carries forward any pre-existing `lang/` dir during edit-in-place installs).

## Phased rollout

### Phase 1 — runtime resolution, manual translation files

- Add `PreferencesService.activeLocale` getter/setter + `LocaleChangedEvent`.
- Add an `I18nContext` utility that loads `lang/<locale>.json` from a wapp package and exposes a `resolve()` that handles the `@key` prefix.
- Wire `I18nContext` through `WappPage._loadWapp` into the GeoUI bindings so the renderer resolves strings automatically.
- Add `hal_i18n_get` to the HAL + `wapp_engine.dart`.
- Update one built-in wapp (pick `install` — it has the most user-visible strings) to use `@key` references and ship `lang/en.json` + `lang/pt.json`.
- Add a "Language" row to iwi's Settings page with a dropdown of supported locales.

### Phase 2 — App Creator tooling

- New "Translations" tab in App Creator (or a section in the UI tab's inspector).
- Auto-scan for untranslated literals; prompt to promote them to keys.
- Editable table of all locales side-by-side.
- Installer writes the full `lang/` dir on save.

### Phase 3 — richer locale semantics

- Plural forms (ICU MessageFormat or a minimal subset) via a new `@pluralKey:count` sentinel.
- Locale-aware number/date formatting via `intl` package.
- RTL layout support for Arabic / Hebrew wapps — GeoUI renderer wraps its root in a `Directionality`.
- Import/export `lang/*.json` from / to `.po` files so translators can work in standard tooling.

## Files to modify or create

### Phase 1 — files

| Purpose | Path | Change |
|---|---|---|
| Locale preference | `iwi/lib/services/preferences_service.dart` | Add `activeLocale` getter/setter, default to `Platform.localeName` |
| Locale event | `iwi/lib/services/event_bus.dart` | Add `LocaleChangedEvent` |
| I18n context | `iwi/lib/services/i18n_context.dart` | **New**. Loads `lang/<locale>.json` from a `ProfileStorage`, exposes `resolve(raw)` with fallback chain |
| GeoUI renderer | `iwi/lib/geoui/geoui_renderer.dart` | Accept an `I18nContext`; route every string attribute through it |
| Wapp page | `iwi/lib/wapp/wapp_page.dart` | Load the wapp's `lang/` on mount, pass the `I18nContext` to the renderer, subscribe to `LocaleChangedEvent` for live reload |
| HAL | `wapps/hal/geogram_wasm_hal.h` | Add `hal_i18n_get` prototype |
| HAL impl | `iwi/lib/wapp/wapp_engine.dart` | Implement `hal_i18n_get` (read from the wapp's loaded translations) |
| Sample translations | `wapps/archive/install/lang/en.json` + `pt.json` | **New**. Bundle real keys for the install wapp |
| Sample `@key` UI | `wapps/archive/install/screens/home.ui.json` | Replace hard-coded labels / tips with `@key` references |
| Settings UI | `iwi/lib/main.dart` `IwiSettingsPage` | Add "Language" dropdown row |

### Phase 2 — App Creator tooling

- `iwi/lib/wapp/wapp_page.dart` — new `_buildTranslationsTab()` + string-extraction helper + installer plumbing.
- `wapps/archive/app-creator/screens/home.ui.json` — new `$type:"translations"` group.

### Phase 3 — ecosystem

- Plural form grammar documented in `docs/apps/i18n.md`.
- `.po` import/export tooling, possibly a standalone Dart CLI.

## Reused components (do not re-implement)

- **`PreferencesService`** — already the canonical place for user prefs. Add `activeLocale` alongside `wappSigningNsec` / `wappDataDir`.
- **`EventBus`** — already carries `WappLoadedEvent`, `AppStartedEvent`, etc. A `LocaleChangedEvent` is a one-line addition that every open wapp page can subscribe to.
- **`ProfileStorage.readJson`** — handles both filesystem and encrypted backends; loading `lang/<locale>.json` is one call.
- **The existing parent `I18nService`** at `lib/services/i18n_service.dart` — not imported (iwi stays decoupled), but its design (flat key-to-string maps, `Platform.localeName` default, language-name lookup) is the template we're following.
- **`GeoUiScreenRenderer`** — the single choke-point for every string the user sees. Injecting `I18nContext` there covers every field type in one place.
- **`wapp_engine.dart`'s HAL dispatch** — already implements `hal_kv_*`, `hal_http_*`, `hal_msg_*`. `hal_i18n_get` slots into the same pattern.
- **Installer's existing zip-extract path** — `.wapp` unzip automatically carries the `lang/` dir over; no installer-side special-case needed.

## Verification plan (Phase 1)

1. Build + launch with the install wapp's home.ui.json rewritten to use `@key` references and `lang/en.json` + `lang/pt.json` shipped.
2. Switch iwi's language to English via Settings. Open the store. Confirm the search hint reads "Search wapps", the Settings tab says "Repositories", and the empty state says "No repositories yet".
3. Switch to Portuguese. Confirm the same screens read "Procurar wapps", "Repositórios", "Sem repositórios ainda" without restarting the wapp.
4. Leave a key missing in `pt.json` and confirm the fallback chain produces the English string (from `en.json`) rather than a raw `@key` or a crash.
5. Install a user wapp through App Creator that doesn't ship any `lang/` directory. Confirm every string renders as-authored (no regression for legacy wapps).
6. Recompile the install wapp with a `hal_i18n_get` call for one of its log lines. Confirm the log tab renders the localized string.
7. Switch the locale while the wapp store is visible; confirm the on-screen labels update without closing/reopening the wapp.
8. `dart analyze` stays clean; `flutter build linux --debug` builds; no new stderr at launch.

## Out of scope / follow-ups

- **Plural forms / gender** — only needed once a locale with complex plural rules (Polish, Russian, Arabic) is actually requested.
- **Right-to-left (RTL) layout** — the GeoUI renderer's hard-coded Row / Column paddings need an RTL pass before Arabic / Hebrew make sense.
- **Runtime locale negotiation between wapps** — a wapp that providers a widget to another wapp currently speaks its own locale. Whether the provider should resolve in the *consumer's* locale is a Phase 3 question.
- **Translation memory / fuzzy matching** — when an author edits a source string, old translations don't auto-mark as stale. A proper TMS integration is a much larger feature.
- **Downloading additional locales from a wapp store** — today every locale the wapp supports ships inside the `.wapp`. Splitting them into optional packs shaves a few KB but adds distribution complexity; revisit only if size becomes a real problem.
