# Session Todo - 2026-04-22

## Current Branch
- `feat/refactor-phase1-event-hub`
- Created from: latest stabilized `dev` state

## Branch Context
- Stabilization fixes were synced back into `dev` and isolated bugfix follow-ups now move in their own short-lived fix branches
- Current work is the first dedicated architecture-refactor slice continuing on top of that stabilized `dev` state
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
- [x] Migrate first listener subset off raw `window.addEventListener(...)`
- [x] Define official use-case entrypoint contracts
- [x] Add initial request ownership token model for chat generation

### Phase 2: Request Ownership Safety Slice
- [x] Added explicit `ownerKey` + `requestToken` metadata to chat generation registry state
- [x] Guarded stream updates against stale session/request ownership
- [x] Guarded completion/error finalization against stale session/request ownership
- [x] Kept impersonation lifecycle separate from chat generation ownership metadata
- [x] `npm run build` passes after ownership slice
- [ ] Add automated overlap coverage for abort/regenerate races
- [ ] Extend explicit ownership model to other generation-like flows where needed

### Safe Emitter Subset Migrated
- generation started / ended
- chat updated
- sync data refreshed
- API context settings changed
- open API sheet

### First Listener Subset Migrated
- `App.vue`: open API sheet, sync data refreshed
- `ChatView.vue`: generation ended, API context settings changed
- `DialogList.vue`: sync data refreshed, chat updated, generation started, generation ended
- `LorebookSheet.vue`: sync data refreshed
- `CharacterList.vue`: sync data refreshed

### Initial Use-Case Entrypoints Added
- `src/core/llm/usecases/generateChat.js`
- `src/core/llm/usecases/calculateContext.js`
- `src/core/llm/usecases/generateSummary.js`
- `src/core/llm/usecases/generateMemoryDraft.js`
- `ChatView.vue` and `PresetView.vue` now import these entrypoints instead of calling `generationService.js` actions directly

### Phase 3: Use-Case Boundary Extraction (Partial)
- [x] Moved the chat execution/orchestration shell from `ChatView.vue` into `src/core/llm/usecases/generateChat.js`
- [x] Kept Vue-owned state and UI side effects injected from the view instead of coupling the use case directly to Vue refs
- [x] Preserved existing `generationService.js` prompt/request engine as the inner compatibility layer
- [x] Extracted deterministic chat prompt-preparation into `src/core/llm/usecases/chatPreparation.js`
- [x] Updated `generationService.js` to consume that preparation helper instead of owning the full preparation path inline
- [x] Extracted final chat request assembly/execution into `src/core/llm/usecases/chatRequestExecution.js`
- [x] Extracted shared prompt-preparation primitives into `src/core/llm/usecases/chatPromptShared.js` to avoid service/use-case cycle
- [x] Switched `ChatView.vue` from inline chat-generation orchestration to `executeChatGenerationUseCase(...)`
- [x] Grouped injected chat-use-case services into `app` / `preparation` / `lifecycle` / `effects` / `postprocess`
- [x] Replaced raw app event naming in the chat use case with a narrower `notifyGenerationStarted(...)` adapter
- [x] Moved chat persistence access behind `lifecycle.persistence` so the chat use case no longer reads `getChatData` / `db` from loose top-level injections
- [x] Dropped unused lifecycle callback arguments from the chat use-case handoff to keep the boundary narrower and match actual handler contracts
- [x] Switched lifecycle and prompt-ready handlers to consume the shared `persistence` facade directly instead of separate `getChatData` / `db` arguments
- [x] Switched completion/error notifications to narrow app adapters so lifecycle handlers no longer dispatch raw `window` events directly
- [x] Extracted the post-worker chat prompt pipeline (late vector retrieval, memory injection, prompt-ready callback, final request handoff) into `src/core/llm/usecases/chatPostPromptPipeline.js`
- [x] Extracted prepared prompt execution preflight (API config guard, worker execution, abort/vars-save handling) into `src/core/llm/usecases/chatPreparedPromptExecution.js`
- [x] Extracted context-calculation orchestration (worker payload, memory/vector breakdown merge, fallback handling) into `src/core/llm/usecases/chatContextCalculation.js`
- [x] Extracted summary and memory-draft request paths into `src/core/llm/usecases/summaryRequest.js` and `src/core/llm/usecases/memoryDraftRequest.js`
- [x] Extracted memory-book retrieval/index maintenance into `src/core/llm/usecases/memoryBookContext.js` and switched `memoryBooksService.js` to use it directly
- [x] Replaced remaining direct `window.dispatchEvent` calls in `ChatView.vue` for generation/chat events with canonical `createGenerationAppAdapters()` from `src/core/llm/usecases/chatGenerationAppAdapters.js`
- [x] Extracted ChatView generation-service wiring into `createChatGenerationServices` factory (`src/core/llm/usecases/chatGenerationServiceFactory.js`), removing ~65 lines of manual service assembly from the view
- [x] `npm run build` passes after extraction
- [ ] Continue shrinking the remaining orchestration still owned by `generationService.js`
- [ ] Reduce dependency surface passed from `ChatView.vue` into the chat use case

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
10. `refactor: split chat prompt and late-enrichment pipeline`

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
