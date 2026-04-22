# Session Todo - 2026-04-22

## Current Branch
- `feat/refactor-phase1-event-hub`
- Created from: `fixes/urgent-bugfixes`

## Branch Context
- Stabilization work continues to live on `fixes/urgent-bugfixes`
- Current work is the first dedicated architecture-refactor slice branched from that stabilized bugfix branch
- Refactor rule for this branch: structural changes only, no intentional prompt/transport behavior changes

---

## Completed In This Session

### 1. Sync — Settings Not Syncing ✅
- Added `THEME_STATE` entity type for `gz_theme_active_preset`
- Expanded `lsKeys` whitelist to include API runtime, theme, layout, and app settings
- Added `applyApiRuntimeConfig({})` in `reloadSyncedData()` after sync pull

### 2. Chat Import/Export Hardening ✅
- Filter null/undefined from imported `swipes`
- Normalize `swipesMeta` length to match `swipes`
- Skip empty messages during both import and export
- Reject TXT import with clear error message

### 3. Unified Provider Settings (Foundation) ✅
- Created `ProviderProfiles.js` — central module for all provider profiles
- Added tabs to ApiView.vue: LLM, Embeddings, Image Gen, Memory
- Added "Use LLM API" toggles for embeddings, image gen, and memory
- Created legacy compatibility bridge (`getLegacyApiConfig`, `getLegacyEmbeddingConfig`)

### 4. Cloud Sync — API Key Toggle ✅
- Added `isSyncIncludingApiKeys()` / `setSyncIncludeApiKeys()` in `ProviderProfiles.js`
- Added toggle in SyncSheet.vue: "Include API Keys in Sync"
- Updated `syncEngine.js` to conditionally include credential keys based on toggle

### 5. Memory Generation UI Refactor ✅
- Replaced Provider/Override Model fields in ChatView.vue with single Model dropdown
- Dropdown fetches available models from endpoint (LLM or custom)
- Removed "Use LLM API" and "Model" from Generation Settings — kept in quick row
- Added quick model switcher row in MemoryBooksSheet.vue header

### 6. Sync Coverage Expansion ✅
- Added `gz_provider_profiles`, `gz_active_llm_profile_id`, `gz_service_profile_map` to sync whitelist
- Added `gz_imggen_*` (non-sensitive) and `gz_embedding_*` (non-sensitive) settings to sync
- `gz_provider_profiles` and `gz_imggen_api_key` synced only when "Include API Keys" toggle is ON
- `gz_sync_include_api_keys` itself synced so behavior is consistent across devices

---

## Bugfix Follow-Ups (Deferred While Refactor Slice Is Isolated)

### 1. Sync Verification
- [x] Verify `fullPull()` restores API endpoint/model/temp across devices
- [x] Verify active theme preset switches correctly after sync
- [x] Verify API keys are NOT synced when toggle is OFF
- [x] Verify API keys ARE synced when toggle is ON
- [ ] Test sync speed with unchanged theme images

### 2. Chat Open / Swipe Crash
- [ ] Re-import previously crashing chat and test open + swipe + scroll
- [x] Verify exported JSONL no longer contains empty lines
- [ ] If crash persists on 400+ messages, investigate virtual scroll rendering

### 3. TXT Import Rejection ✅
- [x] File picker/import flow handles TXT explicitly
- [x] `importSillyTavernChat` throws explicit error for .txt
- [x] Error message localized (EN/RU)

### 4. JSONL Import Picker Visibility Follow-Up ✅
- [x] Keep `.jsonl` and `.txt` visible/selectable in the picker instead of silently hiding `.txt`
- [x] Preserve explicit `.txt` rejection in `importSillyTavernChat(...)`

---

## Unified Provider Settings — Remaining Work

### Phase 1: Foundation ✅ (Done)
- [x] ProviderProfiles.js module
- [x] Profile CRUD API
- [x] Service-to-profile mapping
- [x] Legacy compatibility bridge

### Phase 2: UI Integration (Partial)
- [x] ApiView.vue tabs (LLM, Embeddings, Image Gen, Memory)
- [x] "Use LLM API" toggles in UI
- [x] Memory Books quick model switcher in sheet header
- [ ] Image Gen actual provider profile integration (reads from localStorage, not profiles yet)
- [ ] Embeddings actual provider profile integration
- [ ] Profile selector dropdown (currently only default profile exists)
- [ ] Add/Edit/Delete custom provider profiles in UI
- [ ] Memory Books generation settings — link `generationSource` to provider profile system

### Phase 3: Full Migration
- [ ] Migrate imageGenService.js to use ProviderProfiles
- [ ] Migrate embeddingSettings.js to use ProviderProfiles
- [ ] Migrate MemoryBooks generation settings to use ProviderProfiles
- [ ] Remove legacy localStorage keys after migration
- [ ] Export/Import provider profiles

---

## Known Unfinished Architecture Work (Deferred)

Tracked in `REFACTOR_PLAN.md` and `REFACTOR_PHASE_0_CHECKLIST.md`:
- Event hub + event catalog formalization
- Request ownership token model
- `generateChat` use-case boundary extraction
- Prompt preview / trace singleton decoupling
- MemoryBooks completion
- Summary simple-mode prompts defaults + editability
- Vector ranking bias tuning (only if real user case forces it)

---

## Current Refactor Slice

### Phase 1: Event Hub + Event Catalog Skeleton
- [x] Created dedicated refactor branch from `fixes/urgent-bugfixes`
- [x] Added `src/core/events/eventNames.js`
- [x] Added `src/core/events/contracts.js`
- [x] Added `src/core/events/eventHub.js`
- [x] Added `src/core/events/bridges/windowEventBridge.js`
- [x] Initialized window compatibility bridge in `src/main.js`
- [x] Migrated a safe emitter subset to canonical app events
- [x] Updated `ARCHITECTURE.md` during implementation
- [x] `npm run build` passes
- [ ] Migrate first listener subset off raw `window.addEventListener(...)`
- [ ] Define official use-case entrypoint contracts
- [ ] Add request ownership token model (next phase)

### Safe Emitter Subset Migrated
- generation started / ended
- chat updated
- sync data refreshed
- API context settings changed
- open API sheet

---

## Commit Log

1. `fix: include API runtime and theme state in cloud sync`
2. `fix: harden chat import/export against empty messages and null swipes`
3. `docs: update sync architecture description and session todo`
4. `fix: reject TXT chat imports and show clear error message`
5. `feat: add unified provider profiles foundation`
6. `feat: add API settings tabs for LLM/embeddings/imagegen + sync key toggle`
7. `feat: add memory books provider tab to API settings`
8. `feat: refactor memory generation UI with model dropdown and quick model row`
9. `feat: expand sync coverage for provider profiles, image gen, and embedding settings`

Target PR: `upstream/dev`

---

## Verification Checklist Before PR

- [x] `npm run build` passes
- [ ] `npm test -- --run` passes
- [x] Refactor slice: legacy `window` listeners preserved via event bridge
- [x] Manual: chat generation start/stop
- [x] Manual: abort + regenerate
- [x] Manual: sync push/pull with updated settings round-trips correctly
- [x] Manual: re-import previously crashing chat opens and swipes safely
- [x] Manual: API settings tabs switch correctly
- [x] Manual: sync key toggle excludes/includes credentials
- [x] Manual: memory generation model dropdown fetches models
- [x] Manual: quick model switcher in memory books sheet updates model
