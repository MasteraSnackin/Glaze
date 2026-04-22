# Session Todo - 2026-04-22

## Current Branch
- `fixes/urgent-bugfixes`
- Created from: `origin/dev` (23d7b36)

---

## Active Bugfix Focus

### 1. Sync — Settings Not Syncing (In Progress)

**Problem:**
- Cloud sync is slow and does not sync:
  - API runtime settings (endpoint, model, temp, stream, reasoning, etc.)
  - Theme/app settings (active theme preset, accent color, layout, battery saver, etc.)
  - App language and general UI settings

**Root cause found:**
- `syncEngine.js` only synced a narrow `localStorage` whitelist and `theme_presets` DB blob.
- Active theme state (`gz_theme_active_preset`) and many runtime API keys were excluded.
- After `pull`, `App.vue::reloadSyncedData()` did not re-apply API runtime settings into live state.

**Fix applied:**
- Added `THEME_STATE` entity type for `gz_theme_active_preset`.
- Expanded `lsKeys` to include API runtime, theme, layout, and app settings.
- Added `applyApiRuntimeConfig({})` in `reloadSyncedData()`.

**Still needs verification:**
- [ ] Does `fullPull()` on device B correctly restore API endpoint/model/temp?
- [ ] Does active theme preset switch correctly after sync?
- [ ] Does sync speed improve when large theme preset images are unchanged?
- [ ] Are API keys intentionally synced? (Security risk — currently included; may need opt-out.)

---

### 2. Sync — Wipe Cloud Should Wipe Manifest + Encryption

**Problem:**
- User asked: does cloud wipe also wipe local encryption state and cloud manifests?

**Current behavior:**
- `wipeCloudData()` deletes all files under `/Glaze` via adapter.
- `resetSyncIdentityAfterWipe()` deletes local sync key, manifest, deleted-entries log, and device ID.
- This effectively wipes encryption state locally.

**Still needs verification:**
- [ ] Confirm that after wipe + reconnect, no stale manifest remains in cloud root.
- [ ] Confirm that old `.enc` files do not reappear on next push if encryption is re-enabled.

---

### 3. Chat Open / Swipe Crash on Imported Chats

**Problem:**
- App crashes when opening an imported chat (~400 messages).
- Crash happens on:
  - First open after import
  - Swipe gesture
  - Message scroll / virtual-scroll loading
- Export JSONL contains empty messages (no text, no swipes).
- TXT import format is shown/accepted but may not be handled correctly.

**Root causes found:**
- `convertMessage()` imported `stMsg.swipes` without filtering `null`/`undefined` entries.
- `swipesMeta` length could mismatch `swipes` length after import, causing `changeSwipe` to read out of bounds.
- `exportSillyTavernChat()` exported empty messages (no text, no meaningful swipes), cluttering the file.
- `importSillyTavernChat()` did not skip empty converted messages, inserting null-content rows.

**Fix applied:**
- Filter `null`/`undefined` from imported `swipes`.
- Normalize `swipesMeta` length to match `swipes` after conversion.
- Skip empty messages during both import (JSON array + JSONL) and export.

**Still needs verification:**
- [ ] Re-import the same chat that previously crashed; verify open + swipe + scroll.
- [ ] Verify exported JSONL no longer contains empty lines.
- [ ] Verify TXT format is either rejected gracefully or handled without crash.
- [ ] If crash persists, investigate virtual-scroll rendering with 400+ messages and empty text.

---

### 4. Import / Export Format Edge Cases

**Problem:**
- TXT format visible in import picker; user unsure if it should be supported.
- Export JSONL may still contain system/empty rows from SillyTavern originals.

**Fix applied:**
- Empty-message filtering added to both import and export.

**Still needs decision / verification:**
- [ ] Should TXT import be explicitly rejected with a clear message?
- [ ] Should export skip `is_system: true` messages or include them?

---

## Known Unfinished Architecture Work (Deferred)

The following remains tracked in `REFACTOR_PLAN.md` and `REFACTOR_PHASE_0_CHECKLIST.md`. It is **out of scope for this bugfix branch** and will be picked up on a dedicated refactor branch after stabilization.

- Event hub + event catalog formalization
- Request ownership token model
- `generateChat` use-case boundary extraction
- Prompt preview / trace singleton decoupling
- MemoryBooks completion (extraction context, maintenance pass, UI polish)
- Summary simple-mode prompts defaults + editability
- Vector ranking bias tuning (only if real user case forces it)

---

## Commit Plan for This Branch

1. `fix: include API runtime and theme state in cloud sync`
2. `fix: harden chat import/export against empty messages and null swipes`
3. `docs: update sync architecture description and session todo`

Target PR: `upstream/dev`

---

## Verification Checklist Before PR

- [ ] `npm run build` passes
- [ ] `npm test -- --run` passes
- [ ] Manual smoke: chat generation start/stop
- [ ] Manual smoke: abort + regenerate
- [ ] Manual check: sync push/pull with updated settings round-trips correctly
- [ ] Manual check: re-import previously crashing chat opens and swipes safely

