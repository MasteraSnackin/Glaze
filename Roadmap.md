# Roadmap

## Purpose

This file tracks the current implementation roadmap for the chat context pipeline, summary flow, lorebook retrieval, and future memory systems.

It is the source of truth for:
- what is already done;
- what was intentionally rejected;
- what is currently planned next;
- the intended architecture direction, so work can resume after unrelated tasks without re-deciding old questions.

## Task Tracking Rules

Every roadmap item should be broken into smaller concrete subtasks whenever possible.

For each task or subtask, always record:
- completion status: `done` or `not done`

If something is only partially complete, split the unfinished portion into a separate follow-up subtask instead of leaving one broad mixed-status item.

Items requiring manual user verification should be explicitly listed in a "Manual Verification" section at the end of the relevant feature.

## Current Direction

The current roadmap is:

1. Finalize the summary block
2. Implement vectorization
3. Add vector-based lorebook entries and retrieval
4. Build memory books on top of that foundation

## Current Refactor Branch

- Branch: `feat/refactor-phase1-event-hub`
- Base: latest stabilized `dev`
- Scope: `REFACTOR_PLAN.md` Phases 1–6 in progress (event hub, request ownership, composable extraction, deterministic pipelines, projections, extension API)
- Phase 1 status: `done`
- Phase 2 status: `done`
- Phase 3 status: `done`
- Phase 4 status: `done`
- Phase 5 status: `done`
- Phase 6 status: `done`
- Phase 7 status: `done`
- Phase 8 status: `done` (ChatView reduced from 3767 → 1611 lines, target <2000 met)
- Phase 11 status: `done` (use-case layer re-architecture — pipeline dir, split scope-creep files, fix naming, eliminate hollow entrypoints)
- Phase 12 status: `done` (transport split, legacy cleanup, dead param removal)
- Phase 13a status: `done` (App.vue decomposition — 1229 → 622 lines script + 5 composables: useAppNavigation, useEditorController, useAppEventSubscriptions, useGlossaryPopup, useAppInit)
- Phase 13b status: `done` (PresetView.vue decomposition — usePresetEditor.js god-object (2080 lines) → 11 focused composables (max 177 lines each) + 279 lines glue in PresetView.vue script. Deleted usePresetEditor.js. New composables: usePresetNavigation (107), usePresetLoader (89), usePresetConnections (33), usePresetCRUD (173), usePresetSelectors (171), usePresetImage (40), useBlockManager (141), useBlockEditor (94), useAuthorsNoteSheet (73), useSummarySheet (126), usePresetTokenPreview (177))
- Phase 13c status: `done` (lorebookState.js decomposition — 1319 → 326 lines state+CRUD. Extracted: lorebookSearchService.js (182), lorebookVectorSearch.js (431), lorebookEmbeddingService.js (352). Re-exports from lorebookState.js for backward compatibility)
- Phase 13d status: `done` (ChatMessage.vue decomposition — 1985 → 1621 lines. Extracted: useMessageSwipe.js (262 — touch/swipe/long-press/guided swipe/guidance editing), useMessageImageGen.js (149 — image gen click handler/parseIIG/openImage). Script reduced from 624 → 334 lines)
- Phase 13e status: `done` (ChatInput.vue decomposition — 1155 → 905 lines. Extracted: useContentEditable.js (128 — getCaretIndex/setCaretPosition/getText/updatePreview), useInputActions.js (168 — send/guidance/image/magic drawer/fullscreen editor). Script reduced from 420 → 170 lines)
- Current slice testing: `tested` (`npm run build` + `npm run lint`)

### Bugs Found & Fixed on This Branch

1. **Fix: missing `await` on `completeStructuredResponse` in `completeJsonResponse`**
   - Status: `done`
   - File: `src/core/llm/transport/responseHandling.js:30`
   - Issue: `completeJsonResponse()` called `completeStructuredResponse()` without `await`. Since `completeStructuredResponse` is async, the caller returned before the completion path finished processing, creating a race condition. `finalizeStreamResponse` could execute before `onComplete` fired, or errors in the completion path could escape unhandled.
   - Fix: Added `await` before `completeStructuredResponse(...)` call.

2. **Fix: missing `onError` propagation and try/catch in `completeStructuredResponse` / `finalizeStreamResponse`**
   - Status: `done`
   - Files: `src/core/llm/transport/requestOutcome.js`, `src/core/llm/transport/chatCompletionsClient.js`, `src/core/llm/transport/responseHandling.js`, `src/core/services/llmApi.js`
   - Issue: `completeStructuredResponse` and `finalizeStreamResponse` had no try/catch. If `extractOpenAiMessage` or `streamAccumulator.finalize()` threw (e.g. malformed API response), the exception propagated uncaught, breaking the callback contract — neither `onComplete` nor `onError` would fire, leaving `isTyping` stuck forever. The `onError` callback was also not threaded through from `executeRequest` → `chatCompletionsClient` → `completeJsonResponse` → `completeStructuredResponse`.
   - Fix:
     - Added `onError` parameter propagation through the full call chain: `llmApi.js` → `chatCompletionsClient.js` → `responseHandling.js` → `requestOutcome.js`.
     - Wrapped `extractOpenAiMessage()` in try/catch in `completeStructuredResponse` — on failure, calls `onError` instead of crashing.
     - Wrapped `streamAccumulator.finalize()` in try/catch in `finalizeStreamResponse` — on failure, calls `onError` instead of crashing.
     - Added `await` on all `onComplete`/`onError` calls in `requestOutcome.js` (they were fire-and-forget, now properly awaited).

3. **Fix: stale `activeChatChar` capture in generation services — foreground path never executed**
   - Status: `done`
   - Files: `src/views/ChatView.vue`, `src/composables/chat/useGenerationCompleteHandler.js`, `src/composables/chat/useGenerationFinalization.js`, `src/composables/chat/useGenerationStateSetup.js`
   - Issue: `createChatGenerationServices()` in ChatView.vue (line 1335) received `activeChatChar` — a module-level `let` variable initialized as `null` at `<script>` load time. The value `null` was captured once and never updated. All generation handlers (`handleGenerationComplete`, `finalizeGenerationState`, `setupGenerationState`) received `activeChatChar = null`, causing:
     - `isGenerating.value = false` never set by handlers (condition `activeChatChar && activeChatChar.id === char.id` always false). The stop button only disappeared via the `onGenerationEnded` event listener which used the live module-level `activeChatChar`.
     - Foreground completion path in `handleGenerationComplete` (line 190) never executed — always fell through to background path which only updates `msg.isTyping = false` in DB, not in `currentMessages.value`.
     - Messages stayed with `isTyping: true` permanently in the reactive UI after generation completed.
   - Fix: Pass `activeChar` (a `ref` that stays synchronized with `activeChatChar` via `activeChar.value = activeChatChar`) instead of the stale `let`. Updated all handler checks from `activeChatChar && activeChatChar.id` to `activeChatChar?.value && activeChatChar.value.id`.

4. **Fix: `streamAccumulator.getPartial()` returned raw text instead of effective text during reasoning**
   - Status: `done`
   - File: `src/core/llm/transport/streamAccumulator.js`
   - Issue: `getPartial()` returned `fullText` (raw accumulated text without reasoning tag stripping) and `accumulatedReasoning` (raw reasoning buffer) instead of the effective (display-ready) text and reasoning. This meant partial results sent during abort/timeout paths contained unprocessed `<reasoning>` tags and duplicate content.
   - Fix: `getPartial()` now returns `previousEffectiveText` (processed text) and `latestEffectiveReasoning` (processed reasoning) with correct fallback.

### Vector / Embedding Fixes (on This Branch)

5. **Fix: vector search queries contained raw HTML, images, base64 data, and reasoning tags**
   - Status: `done`
   - Files: `src/core/states/lorebookState.js`
   - Issue: Query text assembled from chat messages for embedding included unprocessed HTML tags, `<style>`/`<script>`/`<svg>` blocks, base64-encoded images, `<think>...</think>` reasoning blocks, and `imggen-loading` class names. These bloated the query token count, degraded embedding quality, and could exceed embedding model context limits.
   - Fix: Added `sanitizeVectorQueryText()` that strips heavy HTML blocks, converts remaining HTML to plain text via `htmlToPlainText()`, removes reasoning tags, collapses whitespace. Applied in `vectorSearchLorebooks()` before embedding queries.

6. **Fix: vector query text was unbounded — could exceed embedding model context**
   - Status: `done`
   - Files: `src/core/states/lorebookState.js`
   - Issue: `focusedQueryParts` and `fallbackQueryParts` were joined with `\n` and sent directly to the embedding API without any token/length limit. Long chats could produce query text well over 8K tokens, causing API errors or truncated embeddings.
   - Fix: Added `buildBoundedQueryText()` that iterates parts from most recent backward, trims each part to a char limit, and stops when total tokens or chars exceed configurable thresholds. `focusedQuery` capped at 1024 tokens / 6000 chars, `fallbackQuery` at 1536 tokens / 10000 chars.

7. **Fix: stale embeddings used for vector search — no hash check at query time**
   - Status: `done`
   - Files: `src/core/states/lorebookState.js`
   - Issue: `vectorSearchLorebooks()` checked that an embedding record existed (`emb && (emb.vectors || emb.vector)`) but never verified that the stored `textHash` still matched the current entry content. If a lorebook entry was edited after indexing, the stale (incorrect) embedding was still used for retrieval, producing wrong results.
   - Fix: Added per-candidate hash check at query time — compute current `buildEmbeddingFingerprint` hash, compare with `emb.textHash`. Only fresh embeddings participate in search. Stale ones are reported in `missingEmbeddings` with `reason: 'stale_or_invalid'`.

8. **Fix: stale embedding detection in UI — `getEmbeddingStatus` always returned 'indexed' for existing records**
   - Status: `done`
   - Files: `src/core/states/lorebookState.js`
   - Issue: `getEmbeddingStatus(entryId)` checked if a DB record existed and had no error, but never compared the stored hash with current entry content. Edited entries showed "indexed" status even though the embedding was stale.
   - Fix: `getEmbeddingStatus` now accepts entry object, computes current hash, and returns `'stale'` when hash differs. Added `isLorebookEmbeddingFresh()` helper. LorebookSheet uses the new signature everywhere.

9. **Fix: no rate limit (429) handling for embedding API**
   - Status: `done`
   - Files: `src/core/services/embeddingService.js`, `src/core/states/lorebookState.js`, `src/core/services/memoryBooksService.js`, `src/composables/chat/useMemoryBooks.js`, `src/components/sheets/LorebookSheet.vue`, `src/locales/en/index.json`, `src/locales/ru/index.json`
   - Issue: Embedding API calls had no 429 handling. When a provider rate-limited bulk indexing, every subsequent request also failed with an unhandled error, and the UI showed no feedback. Users would see "Index All" spin forever or fail silently.
   - Fix:
     - Added `RateLimitError` class in `embeddingService.js` with `retryAfter` from `Retry-After` header.
     - Both native (CapacitorHttp) and web (fetch) paths now detect 429 and throw `RateLimitError`.
     - `indexLorebookEntries` catches `RateLimitError`, marks all remaining entries as rate-limited errors, returns `{ rateLimited: true, retryAfter }`.
     - `reindexAllMemoryEntries` catches `RateLimitError` and returns `{ rateLimited: true, retryAfter }` instead of crashing.
     - LorebookSheet shows cooldown timer on "Index All" / "Retry Failed" buttons during rate limit.
     - Memory Books reindex shows toast with retry countdown on rate limit.
     - Added 200ms delay between chunked embedding requests to reduce rate limit risk.
     - i18n keys: `btn_rate_limited` (en/ru).

10. **Fix: entries with embedding errors were skipped during "Index All" instead of re-indexed**
    - Status: `done`
    - Files: `src/core/states/lorebookState.js`
    - Issue: `indexLorebookEntries` skipped entries where `existing.textHash === textHash` even when `existing.error` was set. Previously failed entries were never retried during normal "Index All" — only the separate "Retry Failed" path would catch them.
    - Fix: Added `&& !existing.error` condition — entries with errors are always re-indexed regardless of hash match.

11. **Fix: deleting a lorebook entry did not delete its embedding from IndexedDB**
    - Status: `done`
    - Files: `src/components/sheets/LorebookSheet.vue`
    - Issue: `handleDeleteEntry()` spliced the entry from the array but left the orphaned embedding record in IndexedDB, wasting storage and potentially appearing in vector search.
    - Fix: `handleDeleteEntry` now calls `deleteLorebookEntryEmbedding(entry.id)` before removing the entry, then refreshes vector status.

12. **Fix: vector search did not respect `characterFilter` on entries**
    - Status: `done`
    - Files: `src/core/states/lorebookState.js`
    - Issue: `vectorSearchLorebooks()` collected all entries with `vectorSearch: true` without checking `characterFilter`. Entries intended for specific characters were matched for all characters.
    - Fix: Added character filter check in vector entry collection — respects `isExclude` and `names` from `entry.characterFilter`.

13. **Fix: vector search failure blocked entire generation**
    - Status: `done`
    - Files: `src/core/llm/usecases/chatPostPromptPipeline.js`
    - Issue: When vector search failed (provider down, config error, etc.), `runChatPostPromptPipeline` showed an error bottom sheet and called `onError`, aborting the entire generation. Users couldn't generate at all if the embedding endpoint was down, even though keyword lorebook retrieval was unaffected.
    - Fix: Vector search failure now degrades gracefully — generation continues without vector lorebook results. Warning is logged but no error popup and no generation abort.

14. **Fix: `ctx.loreEntries` lost after vector merge in pipeline**
    - Status: `done`
    - Files: `src/core/llm/usecases/chatPipelineSteps.js`
    - Issue: After `mergeLateVectorLoreEntries` in `stepVectorSearch`, `ctx.loreEntries` was overwritten with the merge result but the original `ctx.result.loreEntries` was not propagated back. Subsequent pipeline steps could see empty `loreEntries`.
    - Fix: After merge, `ctx.loreEntries` is restored from `ctx.result.loreEntries` if available.

15. **Fix: `stepPromptReady` was synchronous but `onPromptReady` callback is async**
    - Status: `done`
    - Files: `src/core/llm/usecases/chatPipelineSteps.js`
    - Issue: `stepPromptReady` called `onPromptReady(...)` without `await`, so the prompt-ready handler (which persists lore/memory refs to messages) could race with the generation request dispatch.
    - Fix: Made `stepPromptReady` async and added `await` on `onPromptReady`.

16. **Fix: `maxInjectedEntries` capped at 5 regardless of user setting**
    - Status: `done`
    - Files: `src/core/llm/usecases/memoryBookContext.js`
    - Issue: `buildMemoryInjection` used `.slice(0, Math.max(1, Math.min(5, settings.maxInjectedEntries || 3)))`, which clamped `maxInjectedEntries` to 5 even if the user configured a higher value.
    - Fix: Removed the `Math.min(5, ...)` cap — now uses `Math.max(1, settings.maxInjectedEntries || 3)`.

17. **Fix: `userAvatar` getter crash when `activeChatChar` ref is null**
    - Status: `done`
    - Files: `src/core/llm/usecases/chatGenerationServiceFactory.js`
    - Issue: After passing `activeChar` ref (from the stale-capture fix), the getter `activeChatChar.value?.avatar` would crash when `activeChar.value === null` because `null.value` is undefined access on a non-ref.
    - Fix: Changed to `activeChatChar?.value?.avatar` — optional chaining on the ref itself.

### Memory Automation Fixes (on This Branch)

18. **Fix: `runMemoryAutomationAfterStableTurn` crashed for background characters**
    - Status: `done`
    - Files: `src/composables/chat/useMemoryAutomation.js`
    - Issue: `runMemoryAutomationAfterStableTurn` used `activeChatChar.value.id` for DB saves and UI sync. When called for a background character (e.g. from `handleGenerationComplete` background path where `activeChatChar.value` is a different character), it saved data under the wrong character ID and updated the wrong UI.
    - Fix: Added `charId` and `syncUi` parameters. Uses `targetCharId` (from param or `activeChatChar.value?.id`) for all DB writes. Only calls `updatePendingMemoryMessageIds` when `syncUi && activeChatChar.value?.id === targetCharId`.

### Database Fixes (on This Branch)

19. **Fix: Vue reactive proxies persisted to IndexedDB**
    - Status: `done`
    - Files: `src/utils/db.js`
    - Issue: `saveChat` and `patchChatData` stored `normalizeChatData(chatData)` directly, which could contain Vue reactive Proxy objects. IndexedDB serialization of Proxies can produce incomplete or incorrect data (missing properties, getter side effects). This could cause data loss or corruption on reload.
    - Fix: Added `toPlain()` deep snapshot before writing — strips all Proxy layers, producing a plain object for IndexedDB.

### Navigation / UI Fixes (on This Branch)

20. **Fix: editor close used stale `currentView` after resetting state**
    - Status: `done`
    - Files: `src/App.vue`
    - Issue: `closeEditor()` read `currentView.value` after already setting `previousViewForEditor.value = null` and changing `currentView.value`. The view check for `view-character-edit` vs `view-persona-edit` could match the new view instead of the closing one. Editing indices were not reset, causing stale editor state on next open.
    - Fix: Capture `closingView` before resetting state. Reset `isHeaderEditorMode`, `editingCharacterIndex`, and `editingPersonaIndex` explicitly. Pass `currentView` (not `effectiveMainView`) to AppHeader so it sees the real view name.

21. **Fix: AppHeader back button didn't route to correct close action for editors/settings**
    - Status: `done`
    - Files: `src/components/layout/AppHeader.vue`
    - Issue: `handleBack()` always dispatched a global `app-back-navigation` event. For editor headers (character edit, persona edit) and nested settings views, the global listener could be from a different view, causing incorrect navigation (e.g. closing the whole app instead of the editor).
    - Fix: Added explicit routing in `handleBack()`: editor views emit `action-close` directly; settings/submenu views call `state.onBack()` directly; only falls through to global event for standard views.

22. **Fix: back navigation fired on hidden/closed sheets**
    - Status: `done`
    - Files: `src/components/sheets/LorebookSheet.vue`, `src/components/sheets/RegexSheet.vue`, `src/views/ApiView.vue`, `src/views/PersonasView.vue`, `src/views/PresetView.vue`
    - Issue: `handleBackNavigation` event listeners on sheets fired even when the sheet was closed or not visible. This caused spurious `preventDefault()` calls that blocked normal Android hardware back button behavior (navigating between views).
    - Fix: Added visibility guard — `handleBackNavigation` returns early if `!sheet.value?.isVisible`.

23. **Fix: LorebookSheet/RegexSheet close didn't reset internal view state**
    - Status: `done`
    - Files: `src/components/sheets/LorebookSheet.vue`, `src/components/sheets/RegexSheet.vue`
    - Issue: `close()` called `sheet.value?.close()` but left `currentView` on the detail/edit sub-view. Next time the sheet opened, it showed the previous detail view instead of the list.
    - Fix: `close()` now sets `currentView.value = 'list'` before closing the sheet.

24. **Fix: null-safe key array access in LorebookSheet**
    - Status: `done`
    - Files: `src/components/sheets/LorebookSheet.vue`
    - Issue: Several template bindings accessed `entry.keys.join(...)`, `activeEntry.secondary_keys?.join(...)`, `activeEntry.characterFilter?.names.join(...)` without null guards. Entries with missing/undefined `keys` arrays crashed the template renderer.
    - Fix: Added `|| []` fallbacks and `?.join?.()` optional chaining on all key/array accesses in template.

25. **Fix: `triggerAutoSyncCheck` crash when `isGenerating` not passed**
    - Status: `done`
    - Files: `src/composables/chat/useAutoSync.js`
    - Issue: `triggerAutoSyncCheck({ isGenerating })` required `isGenerating` but some callers didn't pass it. Accessing `isGenerating.value` on undefined crashed.
    - Fix: Default destructuring to `{ isGenerating } = {}`, use optional chaining `isGenerating?.value`.

Phase 3 composable extractions:
- [done] Extract `triggerAutoSyncCheck` into `composables/chat/useAutoSync.js`
- [done] Extract memory automation functions into `composables/chat/useMemoryAutomation.js`
- [done] Extract memory prompt presets into `core/services/memoryPromptPresets.js`
- [done] Extract message edit helpers into `core/utils/messageEditHelpers.js`
- [done] Extract context breakdown computed properties into `composables/chat/useContextBreakdown.js`
- [done] Extract message selection state + delete/hide actions into `composables/chat/useMessageSelection.js`
- [done] Extract chat search into `composables/chat/useChatSearch.js`
- [done] Extract memory sheet UI (DOM builders, entry editor, prompt manager, generation settings, event handlers) into `composables/chat/useMemorySheetUI.js`
- [done] Extract swipe/greeting navigation into `composables/chat/useSwipeNavigation.js`
- [done] Extract message display helpers into `composables/chat/useChatMessageDisplay.js`
- [done] ChatView.vue reduced from ~5700 to 3774 lines (33.8%)

Phase 4 deterministic pipelines:
- [done] Extract `executeImpersonationUseCase` into `core/llm/usecases/impersonationRequest.js` — fixes broken `generateChatResponse` call in `startImpersonation`
- [done] Introduce `PipelineContext` class in `core/llm/usecases/chatPipelineContext.js` — context object with step logging, abort flags, documented forbidden reorderings
- [done] Refactor `chatPostPromptPipeline` to use `PipelineContext` + 6 named steps in `chatPipelineSteps.js`
- [done] Deduplicate `updateContextCutoff` authors note logic — replaced inline 16-line block with `buildGenerationAuthorsNote` call
- [done] Route `calculateContext` through use-case facade, remove unused `executeRequest`/`generateMemoryDraft` imports from ChatView
- [done] Extract `useGenerationAbort` composable — unifies `abortActiveChatGeneration` + `abortAnyActiveGeneration` + `abortImpersonation`, removes duplicated abort logic in `sendMessage`
- [done] Migrate 13 `window.dispatchEvent`/`addEventListener` calls to `publishAppEvent`/`subscribeAppEvent`, add 10 new `APP_EVENTS` names, activate legacy bridge in `main.js`

Phase 5 side effects and projections:
- [done] Split prompt preview state out of `generationService.js` singleton into keyed `core/states/promptPreviewState.js`
- [done] Split network trace state out of `networkDebugService.js` singleton into keyed `core/states/requestTraceState.js`
- [done] Thread `debugKey` through chat, impersonation, summary, and memory-draft request flows so preview and trace belong to the same request/session
- [done] Update `RequestPreviewSheet.vue` to read a matched prompt preview + request trace pair instead of mixing unrelated "last" globals
- [done] Keep backward-compatible `getLastPrompt()` / `getLastNetworkTrace()` facades and legacy persisted trace hydration during migration
- [done] Publish richer domain/debug events from pipelines and transport: `domain.generation.promptReady`, `domain.generation.requestDispatched`, and `debug.*` trace/preview events
- [done] Move prompt preview + request trace writes behind `core/events/projections/debugStateProjection.js` subscribers instead of direct orchestration updates
- [done] Add `core/states/requestPreviewState.js` read model so UI consumes a single request-preview snapshot instead of manually stitching prompt + trace state

Phase 6 extension API:
- [done] Add `core/extensions/extensionRegistry.js` with declared generation hook definitions, registration helpers, priority ordering, and disposer-based unregistration
- [done] Define read-only vs mutating hook contracts for `beforePromptBuild`, `afterPromptBuild`, `beforeRequestAssembly`, `beforeRequestSend`, `afterResponseNormalize`, and `afterGenerationCommit`
- [done] Wire chat generation to declared hooks at real use-case/transport boundaries instead of adding new ad-hoc event points
- [done] Apply `afterResponseNormalize` to both JSON and SSE completion paths so extensions see one normalized response boundary
- [done] Extend the same extension API coverage to summary and memory-draft request flows
- [done] Add `core/extensions/appExtensions.js` bootstrap surface and initialize it from `main.js` for app-start extension registration
- [done] Keep feature-local registration possible as well: `registerGenerationHook(...)` and `registerAppExtension(...)` remain directly usable where scoped registration is safer than app-wide bootstrap

Phase 7 compatibility cleanup:
- [done] Replace internal `subscribeLegacyCompatibleEvent(...)` usage with direct `subscribeAppEvent(...)` where dual listening was no longer required
- [done] Replace internal `sync-data-refreshed` `window.dispatchEvent(...)` source with `publishAppEvent(APP_EVENTS.domain.sync.dataRefreshed, ...)`
- [done] Remove dead debug compat helpers `getLastPrompt()`, `getLastNetworkTrace()`, and `clearLastNetworkTrace()` and switch callers to keyed state/read models
- [done] Remove old-format persisted network trace hydration branch; keep only keyed persisted trace hydration
- [done] Remove `core/events/legacyCompatibleSubscription.js` after internal callers were migrated off it
- [done] Keep `window` event bridge only as an external compatibility adapter, not as an internal subscription boundary

Phase 8 ChatView decomposition:
- [done] Extract session management into `composables/chat/useSessionManagement.js` — session create/switch/delete, session name editing, session data persistence (~203 lines)
- [done] Extract message actions into `composables/chat/useMessageActions.js` — message delete/hide, edit save/cancel, branch creation, image regeneration, guidance text patching (~194 lines)
- [done] Extract chat generation into `composables/chat/useChatGeneration.js` — sendMessage, startGeneration, handleImageRegenerate, generation preflight checks, image-gen lifecycle (~152 lines)
- [done] Clean up unused imports after extraction (15+ unused import references removed)
- [done] `activeChatChar` plain `let` passed via `getActiveChatChar()`/`setActiveChatChar()` callbacks instead of direct capture
- [done] `chatGenerationServices` lazy `let` passed via `getChatGenerationServices()` factory
- [done] `_cleanupScroll` let passed via `getCleanupScroll()`/`setCleanupScroll()` callbacks
- [not done] Extract `openChat()` (~400 lines) into composable — deferred: ~30+ dependency injections, marginal ROI
- [not done] Extract context/tokenizer sheet actions (~32 lines) — too small for dedicated composable
- [done] ChatView.vue reduced from 3767 → 1611 lines (-57%, target <2000 met)

This roadmap intentionally assumes the tokenizer and current context UI are already in place and are not being redesigned again unless a new decision is made explicitly.

## Decisions Already Made

These decisions are considered settled unless explicitly reopened:

- Source-based token breakdown is the correct direction.
- The tokenizer stays in the current UI flow.
- The previously discussed top tokenizer button / separate top bar is not part of the plan.
- Lorebook reserve stays in the current model; the earlier idea of moving it outside the context budget was rejected.
- History management is based on hiding the upper part of history rather than introducing a separate trim model.
- The tokenizer color model is already implemented and should be preserved unless there is a specific bug.

## Done

The following work is considered completed:

- Reworked token breakdown from heuristic estimation toward source-based attribution.
- Split context attribution into:
  - Character
  - Preset
  - Summary
  - Author's Note
  - Lorebook
  - History
- Fixed attribution issues caused by macro replacement order.
- Fixed lorebook attribution bleed when lorebook content is injected through macros like `{{lorebooks}}`.
- Moved tokenizer/context access from header UI into MagicDrawer.
- Renamed the quick-access entry to `Tokenizer`.
- Moved `Hide top messages` into the tokenizer sheet above `Settings`.
- Preserved the current hide flow, including summary handoff and related settings.
- Added and stabilized the current tokenizer color-based presentation.
- Fixed legacy / SillyTavern-style preset block ID compatibility for token counting and attribution.
- Added per-character `{{char}}` macro override support via a dedicated character card field, so macro naming can differ from the card title.

## Rejected / Not Planned

These items were discussed previously but are currently not part of the roadmap:

- Moving lorebook reserve outside the context budget.
- Reintroducing a top tokenizer button / top progress bar entry point.
- Replacing the current hide-based history flow with a separate trimming model.

These should stay documented so they are not accidentally reintroduced during future refactors.

## Active Roadmap

### 1. Summary Block (core implementation done)

Goal:
Make summary generation and summary saving a first-class, explicit workflow with clear user actions and predictable prompt behavior.

Summary is not just a recap feature. It is intended to serve as a practical fallback alternative to Memory Books for users who do not have access to embedding models.

Target behavior:
- The summary area should expose three explicit actions:
  - Summarize without block
  - Summarize with block
  - Save
- The distinction between "without block" and "with block" must be clear in logic and UI.
- `Summarize without block` is the clean rebuild path:
  - intended for a new chat with no prior summary;
  - still remains available later if the user wants to regenerate summary from scratch.
- `Summarize with block` is the update path:
  - intended for an existing chat with saved summary;
  - updates the current memory-like summary instead of rebuilding from zero.
- Saving summary content must remain possible independently from generation.
- The summary workflow should be easy to extend later when memory systems are introduced.
- The summary workflow must support user-defined summarization instructions without overloading the main UI.
- Summary should be designed around structured sections instead of one monolithic text block.

Architecture direction:
- Summary generation should not depend on the active preset pipeline in the same way normal generation does.
- Summary prompting should use its own dedicated request path.
- The summary request should be structured so it can evolve independently from normal chat generation.
- The summary result should be storable as durable chat state and also remain usable by the tokenizer/context UI.
- Summary should be stored as structured sections rather than plain text.
- Summary updates should support delta-based regeneration using messages since the last summary point plus an overlap window.
- The overlap window should allow the model to preserve continuity around the handoff boundary.
- Hidden messages should remain usable as summary input when building or updating summary, as long as the request remains within the available context budget.

Implementation status (done):
- `src/core/services/summaryModel.js` — section parser, serializer, model CRUD, delta range, per-section prompts, update from generation results
- `src/core/services/__tests__/summaryModel.test.js` — 28 unit tests
- `src/views/ChatView.vue` — model-aware persistence (openChat, asyncSave, deep watcher), legacy string migration
- `src/views/PresetView.vue` — per-section generation (parallel with sequential fallback), per-section regenerate buttons, token budget
- `src/core/services/generationService.js` — generateSummary with proper prompt passthrough

Implemented features:
- Section-based storage: timeline, characterArcs, conflictsThreads, notHappenedYet, notes
- Delta-based updates with configurable overlap (10 messages)
- Token budget: uses 50% of (contextSize - maxTokens) instead of hardcoded slice(-50)
- Multi-request generation: 5 parallel API requests (one per section), falls back to sequential on error
- Per-section regenerate buttons in advanced sheet
- Per-section prompt templates with focused instructions
- Two generation paths: fresh (full history) and update (delta + current sections)
- Metadata tracking: updatedAt, messageCount, tokenCount, lastMessageIndex
- Backward compatible: legacy string summaries auto-migrate to section model
- Two modes: Advanced (per-section generation, instruction editing, second screen) and Simple (single-request, no second screen)
- Advanced mode toggle persisted in localStorage (`gz_summary_mode`)
- Per-section custom instructions with Save/Restore Default UI in advanced sheet
- Sections with empty custom instructions are dimmed and skipped during generation
- Simple mode uses `buildSummaryPromptForFresh`/`buildSummaryPromptForUpdate` — one API request, result parsed into sections
- Persistence on Done/Back in advanced sheet — `char._summaryModel` always stays in sync

Remaining work:
- **Simple mode prompts need proper defaults and editability.** Currently simple mode uses a generic "Summarize the following roleplay conversation..." prompt. This needs:
  - Two distinct, well-written default prompts: one for fresh summary, one for update.
  - A way for the user to view and edit these prompts without adding clutter to the main screen.
  - Possible approach: a small "edit prompt" link/button that expands an inline textarea, similar to the instruction UI pattern in advanced mode.
  - The prompts should support `{{char}}`, `{{user}}`, `{{history}}` macros at minimum.
  - Stored per-chat or globally (likely globally in localStorage or in the preset).
- **Grouped section updates** (e.g. two sections at a time) — infrastructure ready, not wired in UI.
- **Summary UI polish** — deferred until the model is battle-tested in real usage.

### 2. Vectorization (stable — WORKS, do not touch unless there is a concrete bug)

Goal:
Introduce vector infrastructure so semantic retrieval can be added cleanly instead of relying only on keyword activation.

Tokenizer commits are preserved in `archive/feat/tokenizer` (4 cherry-picks from `archive/feat/summary`):
- `dc43605` feat: add chat context breakdown controls
- `2fc893a` feat: source-based token breakdown, tokenizer sheet in MagicDrawer, summary refactor, lorebook reserve mode
- `b73d9a0` fix: normalize legacy preset block ids for token counting
- `8eceba4` feat: add per-character {{char}} macro override

Decisions made:
- **Separate embedding API config** — endpoint, model, key, identical UX to LLM API settings. Toggle "Use same as LLM" enabled by default. Local embeddings work by pointing endpoint at localhost (Ollama, LM Studio, text-embeddings-inference — all expose OpenAI-compatible `/embeddings`).
- **Endpoint normalization** — the user can paste either `https://api.rout.my/v1/embeddings` or `https://api.rout.my/v1` and it works. Code strips trailing `/embeddings` then appends it back on API call.
- **No chat vectorization** — chat messages are embedded on-the-fly per generation as a query vector, never stored. The query is assembled statelessly from the last N messages at generation time and discarded after matching.
- **Only lorebook entries (and later memory books) get stored vectors.** Infrastructure is extensible for future source types but chat is explicitly out of scope.
- **Embedding target is configurable:** user chooses whether to embed entry content or entry keys. Setting lives in the embedding API config. Default is content (richer embeddings, better semantic matching). Keys option available for very long entries or models with small context.
- **Storage:** IndexedDB, separate `embeddings` store. Schema: `{ id, sourceType, sourceId, vector[], textHash, updatedAt }`. `sourceType` allows future expansion (`"lorebook_entry"`, `"memory"`, etc.). Vectors are NOT exported with lorebook JSON — they stay in IndexedDB only.
- **Invalidation:** `textHash` (SHA-256) on stored vectors. If entry content changes, hash differs → re-embed on next index.
- **Search:** cosine similarity between query vector (from chat) and stored entry vectors. Top-K results above configurable threshold. Results merged with keyword matches (deduplicated by entry id).
- **Vector search depth:** configurable parameter (how many recent chat messages to include in query), similar to keyword scan depth.
- **Auto-chunking:** `maxChunkTokens` setting (default 8192). Long texts are auto-split at sentence/paragraph boundaries, chunks are embedded separately, then averaged into a single vector.
- **Bulk operations:** "Enable/Disable Vector Search All" toggle and "Index All Vector Entries" action available per lorebook via entries menu.
- **Default topK:** 10 (was 5, raised because users with large lorebooks need more results).

Architecture direction:
- Vectorization is implemented as infrastructure first, not lorebook-specific hacks.
- Embedding generation, storage, invalidation, and lookup are separated from the UI layer.
- The retrieval layer is designed so memory books can reuse it later.
- Vector search runs AFTER the keyword-based worker scan, in `generationService.js`. Results are merged (union, deduped by entry id). This keeps the worker synchronous and avoids IPC complexity.
- `embeddingService.js` handles both native (CapacitorHttp) and web (fetch) paths, same pattern as `llmApi.js`.

Implementation pieces (done):
- `src/core/config/embeddingSettings.js` — embedding API config (endpoint, model, key, target, scanDepth, threshold, topK, maxChunkTokens), endpoint normalization, "use same as LLM" toggle
- `src/core/services/embeddingService.js` — `getEmbedding(text)`, `getEmbeddings(texts[])`, auto-chunking, Capacitor native + web fetch, `testEmbeddingConnection()`
- `src/utils/vectorMath.js` — `cosineSimilarity(a, b)`, `findTopK(queryVector, candidates, k, threshold)`
- `src/utils/db.js` — `embeddings` IndexedDB store (DB_VERSION 7), CRUD methods: `getEmbedding`, `getAllEmbeddings`, `getEmbeddingsBySource`, `saveEmbedding`, `deleteEmbedding`, `deleteEmbeddingsBySource`
- `src/core/states/lorebookState.js` — `indexLorebookEntry` (single, hash-check), `indexLorebookEntries` (bulk, per-entry hash-check, progress callback, failed count), `getEmbeddingStatus`, `vectorSearchLorebooks`; entries with `vectorSearch` flag are excluded from keyword matching
- `src/core/services/generationService.js` — vector search merged into `generateChatResponse` after worker returns
- `src/workers/generationWorker.js` — entries with `vectorSearch` flag excluded from `scanLorebooksPure`
- `src/views/ApiView.vue` — embedding settings section: enable toggle, use-same-as-LLM toggle, endpoint/model/key fields, target selector, scan depth, threshold slider, topK, max chunk tokens, test connection button
- `src/components/sheets/LorebookSheet.vue` — per-entry `vectorSearch` toggle, "Index Entry" button with status, visible toolbar with "Enable/Disable Vector All" and "Index All" buttons, progress display (X of Y), result summary (indexed/skipped/failed), `vec` + `idx` badges in entries list, injection position restricted to @worldInfoBefore/@worldInfoAfter with macro override hint
- `src/locales/en/index.json` + `src/locales/ru/index.json` — i18n keys for vector search UI
- Retrieval metadata is auto-generated during embedding indexing and stored alongside embedding records as `retrievalHints` (derived from `comment`, `keys`, and early `content` lines / `Label: Value` fragments).
- Embedding invalidation now fingerprints both indexed text and `retrievalHints`, so `Index All` can refresh stale retrieval metadata without requiring content edits.
- Retrieval now combines `focused` user/current-query search with `fallback` recent-context search instead of choosing only one path.
- Ranking now applies lightweight `hybridBoost` (`comment`/`keys`) and `descriptorBoost` (early `content` + `retrievalHints`) on top of vector similarity.
- Indexing now stores per-entry diagnostics for failed embeddings, including user-visible error status (`err`), reason text, and retry-only-failed flow.
- A reproducible automated QA check now covers the vector-only path end-to-end:
  - entry indexes successfully;
  - semantic retrieval matches it;
  - it appears in `triggeredLorebooks`/`loreEntries`;
  - it is injected into the final prompt.

Current status:
- **Vector lorebook retrieval is considered working.**
- **Do not reopen or refactor vector backend now unless there is a concrete regression or a narrowly scoped bug.**
- Remaining vector work, if any, should be treated as optional quality tuning rather than foundational backend work.

Known issues / remaining:
- **Vector ranking is still too scene-biased for some character retrieval.** Real test case: after an opening message about `Forum`/`Sina` and a follow-up request describing a blue-haired catgirl, retrieval still ranked `Forum`, `Sina`, `girls dormitory`, `Siri Wing`, `Orel`, `Dara`, etc. above `Asei`, even after reindexing and auto-hints. This confirms the pipeline works technically, but ranking still needs stronger entity/appearance-aware bias and/or weaker fallback influence.
- Summary simple mode prompts still need proper defaults and editability.

Expected result:
- The project gains a reusable vector layer rather than a one-off lorebook feature.

### 3. Vector Lorebook Entries (merged into phase 2 above)

Merged with vectorization — building both together since lorebook is the primary consumer.

Design answers:
- Vector search is **per-entry** toggle (each entry can opt in).
- Vector search **replaces** keywords for entries with `vectorSearch` enabled — those entries are excluded from keyword scan and only matched via semantic similarity.
- Number of vector matches controlled by existing lorebook reserve/budget logic.
- Collisions handled by deduplication — if keyword match already found the entry, vector match is skipped.

### 4. Memory Books

Goal:
Build a higher-level long-term memory system on top of the already stabilized summary and vector layers, without introducing a second fragile lore/memory pipeline that will need a rewrite later.

Current pain points that must be solved:
- [done] First memory creation is no longer manual — Scan Chat + Generate Drafts batch flow available.
- [done] Per-message markers: MEM (approved), DRAFT (pending drafts), PENDING (automation queue), REBUILD, STALE badges.
- [done] Deleting messages or branching a chat can leave orphaned / stale memories that no longer match the current chat history.
- [done] Imported chats can use Scan Chat to segment history and Generate Drafts to bootstrap memory entries. Auto-draft on import disabled; user must manually trigger.
- [not done] Memory books need to behave like lorebooks for retrieval features (vectors, keys, Glaze keys), but they must inject into the summary area and have a separate activation/count budget from normal lorebooks.
- [not done] Memory usage should appear in the tokenizer/context UI as summary-like context, not as normal lorebook context.
- [not done] Import/export and future cloud sync integration must not break when memory books are introduced.
- [done] Cloud sync already exists on `feat/cloud-sync` / PR #20 with `syncEngine`, `syncService`, `syncQueue`, conflict resolution UI, encryption, and `updatedAt`-aware DB changes. Memory books must plug into that model instead of inventing a parallel sync path.

Architecture direction:
- [done] Reuse the existing vector infrastructure rather than creating a separate memory retrieval engine. The current embeddings schema already supports future `sourceType` expansion beyond `lorebook_entry`.
- [done] Reuse lorebook-style entry semantics for memory entries: keys, vector search, retrieval hints, and inspectable entry records remain the correct primitive.
- [done] Do not make memory books just a hidden naming convention inside normal lorebooks. They need their own container/type so lifecycle, injection budget, UI, and sync/import behavior are explicit.
- [done] Keep memory entries structurally compatible with lorebook entries where possible, but store memory-book metadata separately from normal lorebook presentation concerns.
- [done] Message-range ownership must be first-class. Memory entries should track the message range or explicit message IDs they summarize so lifecycle operations can be deterministic.
- [done] Memory retrieval injects into the summary block path with its own budget. Memory injection filter: entries only eligible when first segment message leaves context window.

Recommended implementation shape:
- [done] Introduce a dedicated memory book container persisted per chat/session, instead of storing memory books as ordinary lorebooks only.
- [done] Keep each memory entry lorebook-compatible internally at the schema level: `content`, `keys`, `vectorSearch`, and `glazeKeys` are now present so retrieval wiring can build on stable entry fields.
- [done] Add memory-specific metadata on top of the entry data:
  - `messageRange` / explicit message IDs covered by the entry
  - source session ID
  - derived segment hash/fingerprint
  - lifecycle status (`active`, `stale`, `orphaned`, `needs_rebuild`)
  - creation mode (`manual`, `auto`, `import_bootstrap`)
- [not done] Treat the memory book as a dedicated chat-level data container that can feed a summary-like prompt block during generation while still reusing indexing/search internals.

Why this shape is preferred:
- [done] The generation pipeline already distinguishes `summary` and `lorebook` token sources, so memory books can be integrated as a summary-adjacent source without pretending they are ordinary lorebook injections.
- [done] Messages already expose `triggeredLorebooks`, which means the chat UI already has a pattern for showing source-trigger metadata on individual messages.
- [done] Chat lifecycle events already exist in `ChatView.vue` for delete, branch, import, and save flows, which gives a clear place to attach memory lifecycle maintenance.
- [done] Import/export already goes through centralized chat/backup services, so a dedicated memory container is safer than hiding memory state inside ad hoc lorebook fields.

Planned execution order:
- [done] 4.1. Data model and persistence foundation.
- [done] 4.2. Lifecycle maintenance tied to chat mutations.
- [done] 4.3. Retrieval and prompt injection integration.
- [done] 4.4. UI and tokenizer visualization.
- [done] 4.5. Import/export/bootstrap and cloud-sync-safe serialization foundation in this branch.
- [not done] 4.6. Automation rules and quality tuning.

4.1. Data model and persistence foundation:
- [done] Add a dedicated persisted memory-book container per chat/session.
- [done] Define a memory entry schema that extends lorebook-compatible entry fields with message ownership metadata.
- [done] Add deterministic identifiers for memory books and entries so imports, sync merges, and branch operations can reconcile data instead of duplicating it.
- [done] Decide whether message ownership uses stable message IDs, timestamps, or both. Current recommendation: introduce explicit stable message IDs and keep timestamps as secondary metadata.
- [done] Add DB migration / persistence support so memory books survive chat reloads, backup restore, and future sync.
- [not done] Align memory persistence with the cloud-sync data model from PR #20: stable IDs, `updatedAt`, conflict-safe records, and deterministic serialization.

4.2. Lifecycle maintenance tied to chat mutations:
- [done] On message deletion, detect memory entries whose covered range is now invalid and mark or rebuild them instead of leaving stale memories behind.
- [done] On chat branching, reconcile memory books explicitly instead of copying them blindly.
- [done] Copy only memory entries whose covered message IDs/ranges are fully preserved inside the new branch history.
- [done] If a memory entry only partially survives the fork boundary, do not keep it active; mark it as `needs_rebuild` or convert it into a draft for re-approval.
- [done] If a memory entry belongs only to messages that do not exist in the child branch, remove it from the child branch entirely.
- [not done] Add a maintenance pass that can recompute memory coverage for an entire session and clean up orphaned entries.
- [not done] Surface stale/orphaned state in the memory UI instead of silently keeping broken data.

4.3. Retrieval and prompt injection integration:
- [done] Reuse vector indexing/search for memory entries via a separate `sourceType` such as `memory_entry`.
- [done] Support the same activation styles as lorebooks where useful: vectors, keys, and Glaze keys.
: runtime retrieval now supports key/glaze-key matching plus vector-backed memory entry search; deeper worker-level unification can remain follow-up cleanup.
- [done] Keep normal lorebook activation limits separate from memory activation limits.
- [done] Inject retrieved memories into the summary block path or an adjacent dedicated memory-summary block, not into the normal lorebook block.
- [done] Expose separate memory context accounting in generation metadata so the UI can show memory independently from lorebooks.
- [done] Memory retrieval already behaves like a lightweight lorebook-style top-k selection pass: relevant entries are searched, ranked, capped by session settings, and injected into the prompt.
- [done] Session settings already include a `maxInjectedEntries`-style memory cap (`количество мемори в памяти`) that controls how many retrieved memory entries can be added to the prompt.
- [done] Expose an explicit memory injection target setting in UI so the user can choose whether memory entries are injected into the dedicated summary block path or through the `{{summary}}` macro location.

4.4. UI and tokenizer visualization:
- [done] Add per-message markers showing whether a message is already covered by a memory segment / memory entry.
- [done] Add a way to inspect which memory entry covers which message range directly from the chat UI.
- [done] Add a dedicated memory books window/sheet rather than burying the feature entirely inside the lorebook sheet.
- [done] In the tokenizer/context breakdown, display memory usage as summary-like context rather than lorebook usage.
- [done] In message trigger UI, show memory-triggered entries distinctly from regular lorebook hits.

Current implementation status notes:
- [done] Messages now store compact `contextRefs` and `memoryCoverage` metadata.
- [done] Manual memory creation/removal from selected messages is available.
- [done] A first visible `Memory Books` entry point exists in the magic drawer.
- [done] `Memory Generation` currently supports provider source selection (`current` vs `custom`) and reuses the main API settings for `current` mode.
- [done] `Current provider` mode now supports an optional model override without duplicating endpoint/key fields from the main API settings.
- [done] `Memory Generation` now has its own rules/prompt preset selection, custom prompts, and temperature override, so memory generation can bypass the main preset configuration.
- [done] Prompt rules can now be previewed before selection, and custom prompts can be viewed/edited directly from the manager.
- [done] Closing prompt preview now returns to the originating memory sheet flow instead of dropping the user out of the settings/manager stack.
- [done] Draft generation now includes a first continuity layer from nearby approved memories instead of sending the segment alone.
- [done] Draft generation now also includes compact historical lore-trigger candidates and a summary excerpt for higher-quality extraction context.
- [done] Normal generation now injects selected memory-book entries as a separate memory context block and records triggered memories on the source message.
- [done] Dialog export now includes a Glaze full-fidelity chat format that preserves memory books, message refs, and memory coverage metadata.
- [done] ST chat import/export now preserves Glaze message IDs, context refs, memory coverage, and triggered memories in `extra` when available.
- [done] Memory entries and drafts now persist retrieval-facing fields (`keys`, `glazeKeys`, `vectorSearch`) and surface them in Memory Books preview UI.
- [done] Approved memory entries can now be edited after approval, including title/content/keys/Glaze keys updates, per-entry `vectorSearch` toggle changes, and manual `Reindex` actions from the Memory Books UI.
- [done] Memory Books now expose a session-level vector-search toggle and a selectable key match mode; keyword retrieval uses only the entry `Keys` field while preview cards keep inline `Edit` / `Reindex` / `Delete` actions.
- [done] Memory Books now expose a user-facing session-level retrieved-entry cap (`maxInjectedEntries`) as the "количество мемори в памяти" control.
- [done] Memory generation prompts now ask for both memory text and optional retrieval keys in a simple text format (`Memory:` / `Keys:`), avoiding JSON-only contracts.
- [done] Draft parsing now supports vector-first usage: if the model leaves `Keys:` empty, fallback keys are generated automatically while vector retrieval can still dominate when configured.
- [done] Replace the temporary bottom-sheet implementation with a dedicated polished memory sheet component before considering the UI complete. — **Done in Phase 6.** `MemoryBooksSheet.vue` created.
- [done] Add an explicit session setting for "раз в сколько сообщений создается мемори" so automation/bootstrap can use a user-configurable interval instead of a hardcoded threshold.
- [done] Add an explicit session setting for memory injection target selection: `{{summary}}` macro slot vs dedicated chat summary block injection.
- [done] Batch 3 persistence hardening: Memory Generation now preserves unsaved modal state across prompt preview/reopen flows, and DB normalization now keeps `autoCreateInterval`, `useDelayedAutomation`, `injectionTarget`, and the current Memory Books key-match defaults aligned during reload/save paths.
- [done] Lorebook insertion now has a global default injection position and per-entry `Match Global` / `{{lorebooks}}` targets, so the `{{lorebooks}}` macro is legal at the lorebook-entry level instead of acting as a preset-wide override.
- [done] Restore an explicit Lorebooks global setting for `Max Injected Entries`, separate from `scan depth`, so users can cap how many triggered lore entries actually reach the prompt.
- [done] Lorebook ST round-trip now preserves Glaze-specific injection targets via `glazeMetadata`, so `Match Global` / `{{lorebooks}}` are not collapsed during export/import back into Glaze.

4.5. Import/export/bootstrap and cloud-sync-safe serialization:
- [done] On chat import, add an initial segmentation/bootstrap flow that can create first-pass memory drafts automatically from imported message history when the imported session has no existing memory-book state yet.
- [done] Ensure exported chat or backup data includes memory book state in a deterministic form that can be rehydrated without manual repair.
- [done] Keep SillyTavern-compatible chat export separate from full-fidelity Glaze-to-Glaze export. ST export may stay lossy, but Glaze-to-Glaze export/import must preserve memory books, message coverage markers, context refs, and related session metadata.
- [done] Add a dedicated Glaze-to-Glaze chat/session format or extension path so memory-book state can round-trip without relying on ST JSONL fields that do not support Glaze metadata.
- [not done] Keep embeddings export rules explicit: vectors may stay rebuildable/derived, but the core memory entries and message ownership metadata must persist.
- [done] Design the stored format so cloud sync can merge or replace memory books predictably using stable IDs and updated timestamps, instead of treating them as opaque blobs.
- [not done] Reuse the cloud-sync conflict model from PR #20 so memory books can participate in manual conflict resolution rather than bypassing it.
- [not done] Extend cloud sync to include memory-book records and per-message memory metadata, so sync does not silently drop memory coverage or leave orphaned memory state across devices.

4.6. Automation rules and quality tuning:
- [not done] Define when automatic memory creation runs: for example after N new messages, after summary update, or on explicit background maintenance.
- [done] Make the automatic creation interval user-configurable in UI as "раз в сколько сообщений создается мемори" instead of hardcoding the trigger threshold.
- [done] Add a user-facing toggle for delayed automation (`работать с отставанием`) so automatic memory creation can intentionally wait for an extra user+assistant exchange before materializing a memory entry.
- [done] Split auto mode into two stages: automatic segmentation always creates draft placeholders first, while a separate `Auto-Generate Draft Text` toggle controls whether those new drafts immediately request generated text.
- [done] Define delayed-trigger semantics for `Create memory every N messages`: when the threshold is reached on an assistant reply, wait until the user replies and receives one more assistant reply; when the threshold is reached on a user message, wait until that user message gets an assistant reply and then wait for one more full user+assistant exchange before creating the memory entry.
- [done] Keep delayed automation as the recommended default so users can still edit their last user turn or regenerate the latest assistant reply before a memory entry becomes fixed.
- [done] A first session-level delayed automation engine now tracks pending auto-memory triggers and evaluates them after stable assistant reply completion in the normal generation flow.
- [done] Allow the system to create memory entries via Scan Chat + Generate Drafts when enough chat history exists. Auto-creation on import disabled to prevent unwanted drafts.
- [done] Define a first segmentation policy for auto/bootstrap flows: start from the user-configured `N`-message interval, but prefer ending segments on a nearby assistant reply so generated memory windows align better with completed exchanges.
- [done] Add a first deduplication/conflict layer so exact-duplicate and high-overlap memory segments are blocked during draft generation and draft approval.
- [done] Add a first session-wide Memory Books maintenance pass that can reconcile coverage, clear orphaned pending drafts, remove fully orphaned approved entries, and optionally reindex approved memory entries.
- [done] Surface lifecycle state in the Memory Books manager with visible status badges and summary counters for active entries, drafts, needs-rebuild entries, and stale message coverage.
- [not done] Add recency/importance controls only after the core lifecycle model is stable.
- [done] Add a proper first-pass memory-generation rules manager with built-in prompt presets, user-defined prompts, preview support, and prompt selection independent from the main chat preset.
- [done] Add memory-generation temperature override independent from the main chat preset.
- [done] Allow `current provider` memory generation to override only the model while still reusing the main endpoint/key.
- [done] Ensure memory generation can preview the selected rule text before running drafts.
- [done] Ensure prompt preview close returns to the relevant memory settings/manager sheet.

Memory extraction context algorithm (fixed direction):
- [not done] Do not reconstruct extraction context from the current live lorebook inject alone. It may differ from the lore context that existed when the target messages were generated.
- [not done] Do not send the full set of triggered lore entries from all messages in the segment to the model. Message-level trigger history is an audit/debug source, not direct prompt payload.
- [not done] For each message, store only compact trigger references needed for UI and reconstruction candidates:
  - stable entry ID
  - source type (`lorebook` / `memory`)
  - optional compact label/title
- [not done] For a target segment, build extraction context in two stages.

Stage A. Candidate collection:
- [not done] Collect the target message segment.
- [not done] Collect the union of lore entry IDs that were actually triggered on messages inside the segment.
- [done] Collect the nearest approved memory entries adjacent to the segment.
- [done] Run lightweight retrieval on the segment text itself to get current top lore candidates.
- [done] Optionally collect a compact summary excerpt and minimal setting context.

Stage B. Candidate compression:
- [not done] Rank lore candidates by a weighted score combining:
  - trigger frequency within the segment
  - recency inside the segment (later messages weigh more)
  - direct entity/key overlap with the segment text
  - current retrieval score from vector/keyword lookup
- [not done] Deduplicate by entry ID before scoring.
- [not done] Keep only a hard-capped top-k lore set for the model.
- [not done] Keep only a hard-capped top-k memory continuity set for the model.
- [not done] Drop low-value context aggressively instead of letting the prompt expand without bound.

Prompt payload limits (initial target):
- [not done] Message segment: one target segment only.
- [done] Memory continuity context: 1-3 approved memory entries max.
- [not done] Lore context: 3-5 lore entries max.
- [not done] Summary context: one compact excerpt only when needed.
- [not done] Setting/card context: compact fallback only, not full card by default.

Initial ranking formula direction:
- [not done] Historical trigger score is primary when reconstructing older segments.
- [not done] Current retrieval score is secondary and used as a tie-breaker / recovery signal, not the sole source of truth.
- [not done] Memory continuity relevance outranks generic recency.
- [not done] Entries that match both historical triggers and current retrieval should be preferred.

Implementation start order (to avoid refactor later):
- [done] Step 1. Add stable message IDs and compact per-message trigger references.
- [done] Step 2. Add dedicated memory book container + entry schema with message ownership metadata.
- [done] Step 3. Add lifecycle helpers for delete/branch/import rebuild detection.
- [done] Step 4. Add extraction-context builder with top-k compression.
: implemented as a compact heuristic layer for memory continuity + lore-trigger candidates + summary excerpt; vector-backed memory retrieval is still future work.
- [done] Step 5. Add draft/approval workflow for one or multiple sequential memory generation jobs (batch generation with Scan Chat + Generate Drafts).
- [done] Step 6. Add summary-path injection + tokenizer visualization.
- [done] Step 7. Add backup/sync-safe persistence integration.

Manual verification that must stay visible in the roadmap:
- [not done] Verify that deleting covered messages marks the related memory entries stale or removes them correctly.
- [not done] Verify that branching from the middle of a chat does not carry over active memories for messages that no longer exist in the child branch.
- [not done] Verify that partially preserved memory entries after branch are downgraded to `needs_rebuild` instead of staying active.
- [not done] Verify that imported chats can bootstrap first memories without requiring a manually created seed entry.
- [not done] Verify that `Current provider` generation uses the override model while still keeping the main endpoint/key path unchanged.
- [not done] Verify that closing prompt preview returns to `Memory Generation` or the prompt manager instead of closing the whole flow.
- [not done] Verify that unsaved `Memory Generation` changes survive `Preview Rule` and return to the sheet without resetting `promptPreset`, `injectionTarget`, `autoCreateEnabled`, or related controls.
- [not done] Verify that memory injections count separately from lorebook injections during generation.
- [not done] Verify that tokenizer visualization shows memory usage with summary-style accounting.
- [not done] Verify that editing an approved memory entry correctly updates persisted content/keys and does not break message coverage metadata.
- [not done] Verify that disabling `vectorSearch` deletes the memory-entry embedding, and re-enabling or manual `Reindex` rebuilds it correctly.
- [not done] Verify that the Memory Books key match mode (`plain` / `glaze` / `both`) changes retrieval as expected while using only the `Keys` field.
- [not done] Verify that `Create memory every N messages` respects delayed mode correctly on both threshold cases: assistant-triggered thresholds wait one extra user+assistant exchange, and user-triggered thresholds wait for the current assistant reply plus one extra user+assistant exchange.
- [not done] Verify that disabling `работать с отставанием` switches automation back to immediate threshold behavior without breaking edit/regenerate workflows.
- [not done] Verify that auto mode without `Auto-Generate Draft Text` only creates `pending_generation` draft placeholders and never starts background generation by itself.
- [not done] Verify that enabling `Auto-Generate Draft Text` immediately upgrades newly auto-created placeholders into generated drafts without skipping the placeholder step.
- [not done] Verify that lorebook entries set to `Match Global`, `@worldInfoBefore`, `@worldInfoAfter`, and `{{lorebooks}}` inject at the expected locations without preset-level override regressions.
- [not done] Verify that Lorebooks `Max Injected Entries` caps final prompt injection independently from `scan depth` and still preserves entry ordering.
- [not done] Current known limitation: lorebook/memory entries now aggregate into single injected blocks per target, but when the target is a macro inside another preset block, the injected content still lands as a separate block adjacent to that area rather than truly inside the host block. Revisit later.
- [not done] Verify that Glaze lorebook export/import preserves `Match Global` and `{{lorebooks}}` through the new `glazeMetadata` round-trip path.
- [not done] Verify that backup export/import preserves memory books and rebuilds any derived vectors safely.
- [not done] Verify that future cloud-sync serialization can round-trip memory books without duplication or orphaned entries.
- [not done] Verify that Glaze-to-Glaze export/import preserves memory books, per-message markers, and memory generation settings without loss.
- [not done] Verify that reloading a chat preserves `autoCreateInterval`, `useDelayedAutomation`, `injectionTarget`, and Memory Books search defaults for both fresh and legacy sessions.

Important constraint:
- [done] Do not implement memory books as a quick lorebook hack that hides lifecycle state in entry text or comments. That would reintroduce later refactor pressure.
- [done] Summary and vector foundations are stable enough to build on, but memory books should be added as a thin new layer over those primitives, not by forking them.

Expected result:
- [not done] A durable memory layer with deterministic ownership over chat history, reusable retrieval infrastructure, separate injection accounting, and import/export/sync-safe persistence.
- [done] A durable memory layer foundation with deterministic ownership over chat history, separate injection accounting, tokenizer visibility, and Glaze chat round-trip persistence is now in place.

## Post-Merge Conflict Audit (COMPLETED — 2026-04-16)

Upstream принял PR #20 (cloud sync) → после этого PR #24 (vectorization-v2) показал 17 конфликтов. Upstream зарезолвил их сам. Наш PR #27 (memory books + lorebook fixes) тоже был принят.

Current active work branch: `fast-fixes` (branched from `upstream/dev` after audit)

### Merge topology
```
efbb4e5  ← common ancestor (tokenizer features)
  ├── 9cff2fc  ← PR #20 merge (cloud sync into dev)
  │     └── 15920df  ← merge dev into feat/vectorization-v2 (17 conflicts resolved here)
  │           └── 906ee75  ← PR #24 merge (vectorization-v2 into dev)
  │                 └── 886b4b1  ← merge dev into feat/memorybook
  │                       └── 8ec4ff0  ← PR #27 merge (memorybook into dev)
  │                             └── 8c58ff4, 867ff8d, 45cde4d  ← upstream fixes
  └── c43a820  ← feat/vectorization-v2 branch tip
```

### Conflicting files (intersection of changes on both sides)
7 files had overlapping changes between cloud sync and vectorization-v2:
1. `.gitignore` — **A (structural)**: both added entries
2. `CLAUDE.md` — **A (structural)**: both updated instructions
3. `src/components/sheets/LorebookSheet.vue` — **B+C (behavioral + UI)**: vector UI + sync event listeners
4. `src/core/states/lorebookState.js` — **B+D (behavioral + data model)**: vector indexing + sync force init + position handling
5. `src/locales/en/index.json` — **A (structural)**: both added i18n keys
6. `src/locales/ru/index.json` — **A (structural)**: both added i18n keys
7. `src/utils/db.js` — **D (data model)**: embeddings store + sync helpers + updatedAt timestamps

Additionally, `src/views/ChatView.vue` was changed on cloud sync side only (auto-sync + tokenizer property removal), but cloud sync PR itself had removed tokenizer computed properties. Our PR #27 restored them.

### Audit results — ALL CLEAR

| File | Status | Details |
|------|--------|---------|
| `generationService.js` | **IDENTICAL** upstream/dev ↔ our branch | All 6 memory/lorebook injection features present |
| `generationWorker.js` | **IDENTICAL** | All 6 lorebook fixes present |
| `lorebookState.js` | **upstream/dev is BETTER** | All 14 features present: vector + cloud sync + memory book |
| `LorebookSheet.vue` | **upstream/dev is BETTER** | All 8 features present: vector UI + sync listeners + matchGlobal |
| `ChatMessage.vue` | **IDENTICAL** | Memory coverage badge present |
| `ChatView.vue` | **upstream/dev is COMPLETE** | Tokenizer props restored + auto-sync + all memory book code |
| `db.js` | **upstream/dev is BETTER** | Cloud sync helpers added alongside vector storage |
| Locale files | **IDENTICAL** | No diff |

### Key findings
1. **Tokenizer computed properties**: cloud sync PR (`9cff2fc`) accidentally removed them from ChatView.vue. Our PR #27 (`8ec4ff0`) restored them because our branch still had them. Final state in upstream/dev is correct.
2. **LorebookSheet sync integration**: cloud sync added `sync-data-refreshed` event listener and `onUnmounted` cleanup. Our branch had a simpler `updateVectorReindexNotice`. Upstream/dev correctly merged both: the sync-aware version that checks ALL lorebooks + the event listener.
3. **LorebookState force init**: cloud sync added `force` parameter and state reset. Upstream/dev correctly merged this alongside vectorization functions.
4. **Minor edge case**: `lorebooksMacro` position slot in generationWorker.js is initialized but `injectLore('lorebooksMacro')` is never called directly. Entries with `position: 'lorebooksMacro'` only surface via `{{lorebooks}}` macro in preset blocks. Not a regression, pre-existing.

### Decision
- **No corrective branch needed.** All conflicts resolved correctly.
- **Local `dev` synced** with `upstream/dev` at `45cde4d`.

### Branch cleanup
Deleted local branches:
- `archive/feat/summary`
- `archive/feat/tokenizer`
- `feat/cloud-sync`
- `feat/memorybook`
- `feat/vectorization`
- `feat/vectorization-v2`
- `test-cloud-sync`

Deleted remote branches on origin:
- `origin/archive/feat/summary`
- `origin/archive/feat/tokenizer`
- `origin/feat/cloud-sync`
- `origin/feat/memorybook`
- `origin/feat/vectorization-v2`
- `origin/fix/lorebook-macro-resolution`
- `origin/test-cloud-sync`

Remaining branches: `dev`, `main` (local); `upstream/dev`, `upstream/main`, `upstream/feature/desktop-layout` (remote).

## Suggested Execution Order

The intended order of work is:

1. Finish the summary block and summary request path.
2. Build reusable vector infrastructure.
3. Attach vector retrieval to lorebook entries.
4. Build memory books using summary + vectors as the base.

This order is deliberate:
- summary creates durable structured context;
- vectorization creates reusable retrieval infrastructure;
- vector lorebooks validate the retrieval layer on an existing system;
- memory books are then implemented on top of proven components.

## Next Up

The immediate next milestone is:
- [done] Lorebook injection/export fixes are folded into `feat/memorybook`; continue shipping them together with Memory Books instead of splitting a separate PR/branch.
- [done] Vectors are in maintenance mode: WORKS, do not touch without a concrete bug report.
- [not done] Improve vector ranking only if a real user-facing retrieval miss forces it.
- [not done] Summary simple mode prompts — proper defaults and editability.
- [done] Memory books data model foundation exists; continue with generation UX, inspection UX, lifecycle cleanup, and automation instead of reopening the schema.
- [not done] Finish the remaining Memory Books gaps in this branch, then ship one combined PR with both Memory Books and lorebook fixes.

## Resume Notes

When returning to this roadmap after unrelated work:
- do not reopen rejected tokenizer / reserve ideas unless there is a new explicit decision;
- vectorization infrastructure is done on `feat/vectorization-v2` (clean branch from `upstream/dev`);
- entries with `vectorSearch: true` are excluded from keyword matching (both `lorebookState.js` and `generationWorker.js`);
- vector QA coverage now includes automated end-to-end verification of the vector-only retrieval path;
- feature work now continues from `feat/memorybook`, created on top of `feat/vectorization-v2`;
- memory books should converge vectorization and future cloud-sync-safe data modeling instead of inventing a third storage path;
- cloud sync implementation lives in `feat/cloud-sync` / PR #20 and already includes encryption, delta sync, queueing, conflict resolution, and `updatedAt` support that memory books must reuse;
- keep future retrieval work aligned with reusable vector infrastructure, not feature-specific hacks.

## Fast Fixes — Mobile Testing Batch (ORDERED: easy → hard)

Active branch: `fast-fixes`

### ✅ DONE (Batch 1)
1. **Fix: `memoryDraftTimer` is not defined (CRITICAL CRASH)**
   - Status: `done (code path)`
   - Fix: Moved functions from `<script>` to `<script setup>` scope
   - Testing: Message with `isTyping` should not crash Vue

2. **Fix: vector search toggle should disable keyword search UI**
   - Status: `done (code path)`
   - Fix: Hide keys/secondary keys/logic selectors when `vectorSearch=true`
   - Testing: Enable vector search on entry → UI shows only index button and vector badges

3. **Fix: embedding API key inheritance bug**
   - Status: `done (code path)`
   - Fix: Reset `endpoint/key/model` fields when `useSame=true` in `loadEmbeddingSettings()`
   - Testing: Switch from "Use LLM API" → fields should clear, not show LLM key

4. **Fix: tokenizer doesn't count vector lorebook tokens in breakdown**
   - Status: `done (code path)`
   - Fix: Add `vectorLore` to context breakdown, aggregate tokens from `newVectorEntries`
   - Testing: Generate with vector lorebook entries → breakdown shows purple "Vector Lorebook" segment

5. **Add NovelAI model to Naistera image generation**
   - Status: `done (code path)`
   - Fix: Add 'novelai' to `normalizeNaisteraModel()`, UI selector, disable references for it
   - Testing: Select NovelAI → no reference images sent (per API behavior)

6. **Fix: LorebookSheet.vue build error (Invalid end tag)**
   - Status: `done`
   - Fix: Removed extra `</div>` at line 1001, changed `<template v-if>` to `<div v-if>` for reliability
   - Testing: `npm run build` passes without Vue template errors

7. **Fix: Memory books Key Match Mode visible during vector search**
   - Status: `done`
   - Fix: Wrap Key Match Mode selector in `${!vectorEnabled ? '...' : ''}` in `openMemoryBooksSheet()`
   - Testing: Enable vector search in Memory Books → Key Match Mode should be hidden

### ✅ DONE (Batch 3 — merged into PR #30)

8. **Fix: lorebook injections shown for user but not assistant messages**
    - Status: `done`
    - Complexity: easy
    - Issue: Injection badges only appear on user messages, missing on assistant replies
    - Root cause: `onPromptReady` in `ChatView.vue` redirected `triggeredLorebooks`/`triggeredMemories`/`contextRefs` to `msgIndex - 1` (user message) only
    - Fix: Assign refs to both assistant message at `msgIndex` AND preceding user message at `msgIndex - 1`
    - PR: #30

9. **Add i18n keys for new features**
    - Status: `done`
    - Complexity: easy
    - Added 12 missing keys + 2 asymmetric fixes to both `en/index.json` and `ru/index.json`
    - New keys: `api_create_preset_desc`, `api_presets`, `avatar`, `desc_show_reasoning`, `error_generation`, `imggen_notification_body`, `imggen_notification_title`, `label_custom_model`, `label_model`, `label_show_reasoning`, `no_models_found`, `no_prompt`
    - Symmetry fixes: `top_p` → en, `regex_slash_commands` → ru
    - PR: #30

10. **Fix: streaming quote formatting breaks mid-quote**
    - Status: `done`
    - Complexity: medium
    - Issue: Blue quote styling doesn't apply to streaming text when opening quote arrives without closing quote
    - Root cause: `textFormatter.js` regex matches complete quote pairs only
    - Fix: Added 6 regex patterns after the paired-quote matcher to handle unclosed `"`, `"`, `«` at end of text during streaming
    - PR: #30

11. **Fix: messages stuck in "generating" state**
    - Status: `done`
    - Complexity: medium-hard
    - Issue: Message stays with typing indicator after generation should complete (both streaming and non-streaming)
    - Root causes found:
      - Non-streaming mode: Invalid API responses (missing `data.choices[0]`) caused crashes without calling `onComplete`
      - `onComplete`/`onError` handlers could fail with exceptions, leaving `isTyping=true`
      - `onUnmounted` cleared timers but did NOT abort controllers or delete `generatingStates`, allowing background responses to update unmounted components
      - No defensive checks in non-streaming JSON parsing
    - Fixes applied:
      - Added defensive validation before accessing `data.choices[0].message` in both Native and Web non-streaming paths (`llmApi.js:95-99, 276-280`)
      - Wrapped `onComplete` handler in try/catch with `ensureCleanup()` fallback to guarantee `isTyping` cleared even on handler exceptions (`ChatView.vue:3734-3951`)
      - Wrapped `onError` handler in try/catch with `ensureTypingCleared()` fallback (`ChatView.vue:3542-3638`)
      - Added controller abort, timer cleanup, and localStorage flag removal in `onUnmounted` for ALL `generatingStates` (`ChatView.vue:5122-5159`)
    - Files modified:
      - `src/core/services/llmApi.js` (defensive checks for invalid API responses)
      - `src/views/ChatView.vue` (robust error handling + unmount cleanup)
    - PR: #30

12. **Multi-vector retrieval with MaxSim and dual-channel lorebook search**
    - Status: `done`
    - Complexity: hard
    - Implementation:
      - **Multi-vector storage**: Entries chunked (512 tokens default), each chunk embedded separately
      - **MaxSim algorithm**: Query-chunk × candidate-chunk matrix, take maximum similarity score
      - **Dual-channel retrieval**: Vector entries now participate in BOTH keyword scan AND vector search
      - **Keyword priority**: Keyword matches always ranked above vector matches during injection
      - **OOC stripping**: Strip `[OOC: ...]` from query before embedding
      - **Force reindex**: Legacy single-vector embeddings auto-detected and reindexed
      - **DB migration v8**: Convert old `vector` field to new `vectors[]` format
      - **Debug logging**: Per-chunk similarity breakdown for diagnostics
    - Architecture:
      - `vectorMath.js`: `findTopKMulti()` — cross-product MaxSim implementation
      - `lorebookState.js`: `vectorSearchLorebooks()` — dual-channel merge, keyword priority
      - `embeddingService.js`: `getEmbeddings()` returns `[[{text, vector}, ...], ...]`
      - `db.js`: Migration v8, backward-compatible legacy format support
    - Testing:
      - Indexed 102 entries (Vareti lorebook) + Project Tokyo lorebooks with bge-m3
      - Verified keyword matches appear above vector matches
      - Verified Asei entry retrieved via keyword dual-channel
      - Verified semantic retrieval for character descriptions
      - Verified OOC-stripped queries produce cleaner embeddings
      - Verified force-reindex rebuilds legacy embeddings
    - PR: #30
    - Branch: `feat/multi-vector-retrieval` (linear chain from `feat/fast-fixes-batch3`)

### ⏳ PENDING

13. **Sync infrastructure fixes — encryption optional + redirect URI fix**
    - Status: `done`
    - Complexity: medium-hard
    - Branch: `feat/sync-infrastructure-fixes` (linear chain from `feat/multi-vector-retrieval`)
    - Changes:
      - **Encryption is now optional**: Sync works without encryption key. Data stored as plain `.json` instead of `.enc`. If key exists — encrypts as before.
      - **Redirect URI fix**: Both Dropbox and Google Drive adapters now use configurable redirect URIs via env vars (`VITE_DROPBOX_REDIRECT_NATIVE`, `VITE_DROPBOX_REDIRECT_WEB`, `VITE_GDRIVE_REDIRECT_NATIVE`, `VITE_GDRIVE_REDIRECT_WEB`). Web defaults to `window.location.origin` instead of hardcoded `localhost:5173`.
      - **Electron OAuth**: Added Electron-specific OAuth flow for Dropbox (loopback server pattern, same as gdrive already had).
      - **Error 400 root cause**: `redirect_uri` must exactly match what's registered in the OAuth console (Dropbox App Console / Google Cloud Console). Hardcoded `localhost:5173` only works in dev. Fixed: now uses `window.location.origin` as default.
      - **Backward compatibility**: `readCloudEntityByEntry` tries both `.enc` and `.json` extensions. `decryptEntity` auto-detects encrypted vs plain payload.
      - **SyncSheet UI**: Push/Pull/Auto-sync available without encryption. Encryption shown as optional section. `doWipe` no longer forces new key generation.
      - **Mobile callback plumbing**: Android now declares a `VIEW`/`BROWSABLE` intent-filter for `com.hydall.glaze://...`; iOS now registers `CFBundleURLTypes` for the same scheme so Capacitor `appUrlOpen` can receive OAuth callbacks.
      - **Provider gating**: SyncSheet only shows providers that have their required env key configured in the current build.
      - **Google OAuth cleanup**: Google Drive uses PKCE client-side flow without `VITE_GDRIVE_CLIENT_SECRET`.
      - **Push path fix**: `syncService.js` now reads encryption state through `isEncryptionEnabled()` instead of referencing an out-of-scope `_encryptionEnabled` variable.
    - Files modified:
      - `src/core/services/syncEngine.js` — `_encryptionEnabled` state, `ext()`, optional encrypt/decrypt, dual-extension fallback
      - `src/core/services/syncService.js` — removed mandatory `hasSyncKey` checks, uses `detectEncryptionState()`
      - `src/core/services/adapters/dropboxAdapter.js` — configurable redirect URIs, Electron OAuth, `isElectron()` helper
      - `src/core/services/adapters/gdriveAdapter.js` — configurable redirect URIs, `window.location.origin` default
      - `src/components/sheets/SyncSheet.vue` — encryption optional in UI, new states (`ready`, `has_cloud_data`)
      - `android/app/src/main/AndroidManifest.xml` — OAuth deep link intent-filter for `com.hydall.glaze://...`
      - `ios/App/App/Info.plist` — URL scheme registration for `com.hydall.glaze`
      - `src/core/config/syncConfig.js` — env-driven provider availability
    - Manual verification needed:
      - [not tested] Verify Dropbox connect/disconnect works on native (Android/iOS) with correct `com.hydall.glaze://oauth/dropbox`
      - [not tested] Verify Google Drive connect/disconnect works on native with `com.hydall.glaze://oauth/gdrive`
      - [not tested] Verify Push/Pull works WITHOUT encryption key (plain JSON)
      - [not tested] Verify Push/Pull works WITH encryption key (encrypted `.enc`)
      - [not tested] Verify fallback: pull from cloud with old `.enc` files when encryption is disabled
      - [not tested] Verify error 400 is fixed after setting correct redirect URI in OAuth console
      - [not tested] Verify Electron OAuth flow works on Windows/Linux desktop builds

14. **Infrastructure: Sync service migration to upstream project**
    - Status: `not done`
    - Complexity: hard
    - Goal: Move cloud sync infrastructure (encryption, delta, queueing) to developer's repo
    - Deliverables:
      - Sync endpoint configuration guide (PC/Linux/iOS/Android)
      - Error 400/402 troubleshooting runbook
      - OAuth/app token setup instructions per platform

14. **Fix: Tokenizer lorebook display and reserve visualization**
    - Status: `done`
    - Complexity: medium
    - Branch: `bug-fixes`
    - Issue: Lorebook tokens not counted or displayed incorrectly in tokenizer breakdown
    - Root causes:
      - Vector lorebooks marked as `source: 'lorebook'` instead of `source: 'vectorLore'`
      - Worker didn't recognize `vectorLore` as valid source (not in `sourceKeys` array)
      - `calculateContext()` didn't run vector search, so tokenizer showed 0 for vector lorebooks
      - Lorebooks displayed in main bar instead of inside reserve zone
    - Fixes applied:
      - Changed vector lorebook source from `'lorebook'` to `'vectorLore'` in `generationService.js`
      - Added `'vectorLore'` to `sourceKeys` array in `generationWorker.js`
      - Added `vectorLore` field to breakdown structure in worker
      - Updated `fixedBase` calculation to include `vectorLore`
      - Added vector search to `calculateContext()` for accurate tokenizer display
      - Modified UI to show lorebooks **inside** reserve zone, not in main bar
      - Created nested reserve visualization: reserve contains keyword + vector lorebooks + unused space
      - Updated labels: "Keyword Lorebook", "Vector Lorebook", "Lorebook Total"
      - Added `.chat-context-reserve-container` CSS for nested segment display
    - Files modified:
      - `src/workers/generationWorker.js` — add vectorLore to sourceKeys, breakdown, fixedBase calculation
      - `src/core/services/generationService.js` — change source to vectorLore, add vector search to calculateContext
      - `src/views/ChatView.vue` — nested reserve visualization, updated labels, CSS changes
    - Additional fixes (second commit):
      - Fixed `remaining` calculation: changed from `safeContext - totalUsed` to `contextSize - totalUsed`
      - Excluded lorebook/vectorLore from `fixedBase` (they're inside reserve, not in base)
      - Now `fixedBase = character + preset + summary + authorsNote` (without lorebooks)
      - Result: `remaining` now shows correct value relative to full context (80000)
    - Testing:
      - Tokenizer now correctly shows keyword lorebook (0 tokens) + vector lorebook (~8657 tokens)
      - Visual bar: lorebooks display inside green reserve zone on the right
      - Reserve shows: [Vector Lorebook (purple)] [Unused Reserve (green)]
      - Main bar shows: Character, Preset, Summary, Memory, History (no lorebooks)
      - Remaining calculation: 80000 - totalUsed (instead of 72000 - totalUsed)
    - Commits: `f33a9d3`, `915dbf3`
    - PR: pending

15. **Image Generation Improvements — Info Blocks & Dynamic Character State**
    - Status: `not started`
    - Complexity: hard
    - Branch: `img-gen-improve` (from `dev`)
    - Goal: Implement comprehensive image generation system with dynamic character state tracking, dual API endpoints, and quick generation workflow
    
    **Phase 1: Info Blocks — Dynamic State Tracking**
    - Problem: User persona describes "favorite outfit: tweed", but user wrote "wearing hoodie today" 20 messages ago. Current system uses static persona, not dynamic session state.
    - Proposed Solution: **Info Blocks** — dedicated structured data blocks that track current session state
    - Info Block Structure:
      - `current_outfit_user`: What {{user}} is wearing right now
      - `current_outfit_char`: What {{char}} is wearing
      - `current_location`: Current scene location  
      - `time_of_day`: Morning/afternoon/evening/night
      - `lighting`: Scene lighting conditions
      - `weather`: If outdoors
      - `current_pose`: Action/position of characters
    - Implementation:
      - Create new Memory Book type: `info_blocks` (high priority, always included)
      - Auto-extract from chat: Pattern matching for outfit/location/time changes (keywords: "wearing", "dressed in", "changed into", "now in")
      - Manual edit: UI for quick state updates (floating button or context menu)
      - Image gen integration: Use info_blocks as primary source, persona as fallback
    - Alternative Approaches Considered:
      - Parsing last N messages: Too slow, unreliable with complex descriptions
      - Static Memory Books: Requires manual updates, not automatic
    
    **Phase 2: Dual API Setup (SFW/NSFW)**
    - Support two separate image generation endpoints:
      - SFW endpoint: Standard generation (OpenAI/Gemini/Naistera)
      - NSFW endpoint: Uncensored generation (NovelAI/Naistera specialized)
    - Settings:
      - Two sets of credentials: `sfw_endpoint`, `sfw_key`, `nsfw_endpoint`, `nsfw_key`
      - Default toggle: Auto-detect content type or manual selection
      - Style presets per endpoint
    - Use case: Different models for different content types without switching settings manually
    
    **Phase 3: Quick Image Generation Button**
    - Location: Bottom-left button group in ChatInput (4th button or replace existing image-gen)
    - Workflow:
      1. Long-press or context menu: Choose SFW/NSFW/Settings
      2. Click: Quick menu with options:
         - "Generate scene" (uses current info_blocks + last 3 messages)
         - "Generate portrait - {{char}}" (character focus)
         - "Generate portrait - {{user}}" (user focus)
         - "Custom prompt..." (manual override)
      3. Auto-prompt building from:
         - Info blocks (primary)
         - Current macros: {{char}}, {{user}}, {{scenario}}, {{persona}}
         - Last 3-5 chat messages for context
      4. Direct generation without waiting for model response
      5. Insert as new message or inline in chat
    
    **Phase 4: Multi-Character Support**
    - Problem: Character cards can define multiple characters (main + NPCs)
    - Solution: Parse character definitions from card and lorebooks
    - Auto-detect speaking characters from recent messages
    - Generate composite prompts with all present characters
    - Per-character outfit tracking in info_blocks
    
    **Pre-Generation Preview (Optional Enhancement)**
    - Show detected state before generation:
      - Detected: "You in hoodie and jeans, {{char}} in dress, location: cafe, evening"
      - Editable fields for quick correction
      - Generate button
    - Benefits: User can fix misdetected state before wasting API call
    
    **Technical Notes:**
    - Prerequisite for reliable automated image generation
    - Without accurate state tracking, generated images mismatch actual scene
    - Info blocks solve the "static vs dynamic" state problem
    - Dual API enables content-appropriate generation without manual switching
    
    **Files to Modify (Future):**
    - `src/core/services/imageGenService.js` — dual API support, auto-prompt builder
    - `src/components/sheets/ImageGenSheet.vue` — dual endpoint settings UI
    - `src/components/chat/ChatInput.vue` — quick gen button
    - `src/core/services/infoBlockService.js` — new service for state tracking
    - `src/core/services/characterExtractor.js` — multi-char parsing
    - `src/components/sheets/InfoBlockEditor.vue` — manual state editor
    
    **Deferred for Later:**
    - Advanced pattern matching for outfit changes
    - Automatic pose detection from action verbs
    - Scene mood extraction from dialogue tone
    - Background/location detail enrichment from lorebooks

### Branch Strategy (updated)
- Current bugfix chain: merged and closed (`fixes/mobile-network-memorybooks-batch1` -> PR #46, `fixes/regressions-post-merge` -> PR #47)
- Current refactor branch: `feat/network-architecture-refactor`
- Previous: Merged branches deleted (bug-fixes, feat/dual-lorebook-debug)
- Policy: **Linear chain workflow** — each feature branches from previous feature OR origin/dev for new chains
- Never create branches from dev that contain multiple unmerged features
- All PRs target `upstream/dev`, never `main`

## Provider / Network Refactor (Active)

Branch: `feat/network-architecture-refactor`
Status: In progress
Goal: finish moving chat/provider request architecture toward explicit provider, assembler, and transport boundaries without changing prompt semantics or regressing mobile/network behavior.

### Current State

Done and tested:
- [done] Added provider-oriented foundation under `src/core/llm/`:
  - `contracts/providerContracts.js`
  - `providers/providerRegistry.js`
  - `providers/openaiCompatibleProvider.js`
  - `assemblers/requestIntents.js`
  - `assemblers/payloadBuilderRegistry.js`
  - `assemblers/requestAssemblers.js`
  - `transport/responseNormalizer.js`
- [done] `generationService.js` now builds chat/summary/memory-draft payloads through request assemblers instead of inlining OpenAI-like payload shape in each use case.
- [done] `APISettings.js` now routes endpoint normalization and model discovery through provider adapters.
- [done] `ApiView.vue` preset creation/apply flow persists `providerId` with API presets.
- [done] Refactor branch was rebased onto the merged mobile/memory/lorebook fixes and re-applied the regression safeguards from PR #47.
- [done] Regression safeguards preserved on refactor branch:
  - late vector lore respects `maxInjectedEntries`
  - prompt metadata is restored on abort/error instead of leaving stale lore/memory refs behind
- [done] Runtime API config centralization started:
  - `APISettings.js` now exposes `getApiRuntimeStorage()`, `saveApiRuntimeSetting()`, `applyApiRuntimeConfig()`, and `getApiReasoningTags()`
  - hot-path callers (`ApiView.vue`, `OnboardingView.vue`, `ToolsView.vue`, `ChatView.vue`, `generationService.js`, `macroEngine.js`, `ChatMessage.vue`) now use these helpers instead of duplicating raw runtime config reads/writes.
- [done] `llmApi.js` transport extraction continued:
  - `transport/chatCompletionsClient.js` now owns fetch-path request orchestration, including streaming fallback and stream finalization
  - `transport/requestOutcome.js` now owns structured completion, streaming finalization, and partial-result handling for abort/error paths
  - `transport/requestExecution.js` now owns native/fetch execution branches and fetch response validation
  - `transport/requestLifecycle.js` now owns timeout config, abort guards, request headers, and network-trace bootstrap
  - `transport/responseHandling.js` now owns fetch JSON completion and SSE capability detection/fallback shaping
  - `transport/streamingSse.js` now owns SSE read/parse/update consumption while preserving the existing callback contract
- [done] Generation lifecycle extraction started in `ChatView.vue` without behavior changes:
  - `useGenerationRegistry.js` owns per-chat generation session state and persisted generating flags
  - `usePromptMetadataSnapshots.js` owns prompt metadata snapshot/restore for abort/error rollback
  - `useTypingStateCleanup.js` centralizes `isTyping` cleanup across stale/error/abort paths
  - `useGenerationStateRestore.js` now owns generation abort/error restore flow for swipe rollback, message removal, and DB fallback cleanup
  - `useGenerationErrorHandler.js` now owns error-path cleanup and persisted error-state writes after generation failures
  - `useGenerationCompleteHandler.js` now owns completion-path cleanup, visible/background completion writes, and stale/abort finalization checks
  - `useGenerationStreamUpdate.js` now owns stream fan-out and throttled background DB persistence during active generation
  - `useGenerationPromptReady.js` now owns prompt metadata assignment and prompt-ready persistence for triggered lorebooks/memories/context refs
  - `useGenerationPreparation.js` now owns authors-note assembly, placeholder message creation, and request history shaping for chat generation
  - `useGenerationStateSetup.js` now owns initial guidance patching plus per-generation UI update/timer state wiring
  - `useGenerationPreparation.js` also resolves generation session context for active and background chat starts

Tested status:
- [done] `npm test -- --run`
- [done] `npm run build`

Still not done:
- [not done] Move more remaining direct runtime API config access behind `APISettings.js` helpers, especially lower-priority UI code and legacy toggles.
- [not done] Extract generation session lifecycle out of `ChatView.vue` into a dedicated composable/service.
- [done] Separate prompt preview storage from network trace storage and stop relying on singleton global last-trace state. — **Done as Candidate 4.** Prompt preview keyed by generation/session, trace history keyed by request.
- [done] Promote explicit request use cases (`generateChat`, `generateSummary`, `generateMemoryDraft`, `calculateContext`) instead of keeping orchestration concentrated in `generationService.js`. — **Done in Phase 11.** `calculateContext.js`, `generateSummary.js`, `generateMemoryDraft.js` now own their dependency assembly locally. `generationService.js` reduced from 267 → 172 lines, only exports `generateChatResponse`.
- [done] Split `llmApi.js` into transport modules — **Done in Phase 12a.** `llmApi.js` moved to `transport/requestOrchestrator.js`, i18n coupling extracted to `reasoningHeaders.js`, dead `requestReasoning` param removed from `streamAccumulator` and `streamingSse`.

Immediate next refactor step:
- [done] Extracted SSE parsing and stream normalization out of `llmApi.js` first, because that was the highest-complexity remaining transport logic and the biggest blocker to finishing the provider/network split cleanly.
- [done] Moved remaining `llmApi.js` orchestration path into `transport/requestOrchestrator.js`, removed i18n coupling from transport layer, removed dead params. Transport split complete.

### Phase 11: Use-Case Layer Re-architecture (2026-04-24)

Branch: `feat/refactor-phase1-event-hub`
Status: `done`
Testing: `tested` (`npm run build` + `npm run lint`, 0 errors)

Goal: Clean up the use-case/pipeline layer — relocate pipeline files, split scope-creep files, fix naming, eliminate hollow entrypoints, document remaining UI leak sites.

Tasks:
- [done] **11a. Pipeline directory** — Created `src/core/llm/pipeline/`, moved 3 files:
  - `chatPipelineContext.js` → `pipeline/pipelineContext.js`
  - `chatPipelineSteps.js` → `pipeline/steps.js`
  - `chatPostPromptPipeline.js` → `pipeline/postPromptOrchestrator.js`
- [done] **11b. Split scope-creep files** — 3 files split into 7:
  - `chatLateEnrichment.js` → `vectorLoreInjection.js` + `memoryMessageInjection.js`
  - `chatPromptShared.js` → `promptConfigReaders.js` + `promptWorkerLifecycle.js` + `promptPayloadBuilder.js`
  - `memoryBookContext.js` → `memoryEmbeddingIndex.js` + `memoryKeyMatching.js` + `memoryContextInjection.js`
- [done] **11c. Fix naming** — 4 files renamed:
  - `chatContextCalculation.js` → `contextCalculation.js`
  - `chatRequestExecution.js` → `chatRequestAssembly.js`
  - `nonChatGenerationHooks.js` → `sharedRequestHooks.js`
  - `transport/chatCompletionsClient.js` → `transport/completionsClient.js`
- [done] **11d. Eliminate hollow entrypoints**:
  - `calculateContext.js`, `generateSummary.js`, `generateMemoryDraft.js` now own dependency assembly locally instead of proxying to `generationService.js`.
  - `generationService.js` reduced from 267 → 172 lines; only exports `generateChatResponse`.
  - Removed dead exports and unused imports from `generationService.js`.
- [done] **11e. Document UI leak sites** for Phase 12:
  - `generationService.js` imports `translations`/`currentLang` (i18n) and `showBottomSheet`/`closeBottomSheet` (UI state) — passed as `t` and sheet callbacks into pipeline.
  - `pipeline/steps.js` `stepContextLimitGuard` receives `showBottomSheet`/`closeBottomSheet` via deps — UI notification from pipeline step.
  - These should become callback-style dep injection or event-driven in Phase 12.

Files changed:
- Moved/renamed: 7 files
- Split: 3 → 7 files (3 new files added)
- Rewritten: `calculateContext.js`, `generateSummary.js`, `generateMemoryDraft.js` (now real entrypoints)
- Trimmed: `generationService.js` (267 → 172 lines)
- Updated: `ARCHITECTURE.md` (Phase 11 section + updated "not changed yet")

### Phase 12: Transport Split & Legacy Cleanup (2026-04-24)

Branch: `feat/refactor-phase1-event-hub`
Status: `done`
Testing: `tested` (`npm run build` + `npm run lint`, 0 errors)

Tasks:
- [done] **12a. Transport extraction** — `llmApi.js` moved to `transport/requestOrchestrator.js`, i18n coupling extracted to `reasoningHeaders.js`, dead `requestReasoning` param removed
- [done] **12b. Naming & organization** — `chatCompletionsClient.js` → `completionsClient.js`, pipeline files renamed, dead exports removed
- [done] **12c. Dead parameter cleanup** — removed unused params from `streamAccumulator`, `streamingSse`, and transport chain

Files changed:
- Moved: `llmApi.js` → `transport/requestOrchestrator.js`
- Renamed: `chatCompletionsClient.js` → `completionsClient.js`
- Trimmed: `generationService.js` (172 → 173 lines)
- New: `transport/reasoningHeaders.js`

### Phase 13a: App.vue Decomposition (2026-04-24)

Branch: `feat/refactor-phase1-event-hub`
Status: `done`
Testing: `tested` (`npm run build` + `npm run lint`, 0 errors)

Goal: Break App.vue from 1229-line god object into thin shell wiring 5 composables.

Tasks:
- [done] Extract `composables/app/useAppNavigation.js` (101 lines) — view routing, desktop/mobile detection, effectiveMainView, floating menu, FAB, layout metrics
- [done] Extract `composables/app/useEditorController.js` (304 lines) — character/persona editor lifecycle, editor configs, save/auto-save/delete, FS editor, close-and-return-to-chat
- [done] Extract `composables/app/useGlossaryPopup.js` (99 lines) — desktop glossary drag popup, position state, header event handlers
- [done] Extract `composables/app/useAppEventSubscriptions.js` (190 lines) — all 25+ subscribeAppEvent calls, sync refresh, open-chat routing, sheet openers, cleanup
- [done] Extract `composables/app/useAppInit.js` (108 lines) — onMounted init (theme, lorebooks, presets, sync, thumbnails, notifications, keyboard, ResizeObserver), onBeforeUnmount cleanup
- [done] Wire composables into App.vue, fix template ref unwrapping bug (inline `chatViewRef` was unwrapped by Vue template compiler → `openChatFromTemplate` wrapper)

Files changed:
- New: 5 composables in `src/composables/app/`
- Trimmed: `App.vue` (1229 → 622 lines)

All 13a–13e complete:
- [done] 13a: App.vue decomposition
- [done] 13b: PresetView.vue decomposition
- [done] 13c: lorebookState.js decomposition
- [done] 13d: ChatMessage.vue decomposition
- [done] 13e: ChatInput.vue decomposition

## Refactoring Phase — Tokenizer, Memory Books, Vectors/Lorebooks (Active)

Branch: `feat/refactor-tokenizer-memorybooks`
Status: In progress
Goal: Clean up technical debt, fix UX issues, improve user-facing workflows

### Analysis Summary

Three deep-dive explorations completed on 2026-04-17:
1. **Tokenizer**: Currently working correctly, recently fixed. No critical issues found. Uses SheetView bottom sheet pattern. Architecture is clean.
2. **Memory Books**: Functionally complete but uses temporary bottom sheet UI. Many features marked `done`. Needs polished dedicated component.
3. **Vectors/Lorebooks**: Backend dual-channel (vector+keyword) works correctly, but UI presents it as mutually exclusive. Creates user confusion.

### Phase 1: Vector/Lorebook UX Fixes (CRITICAL — misleading UI)

Status: `done | ready for testing` (Commit: d215502)

**Problem**: Dual-channel retrieval is implemented and working in backend, but UI hides keyword fields when vector is enabled and shows "Vector search replaces keys" message. This is factually incorrect.

**Root Cause Analysis**:
- Backend (generationWorker.js:167): ALL entries participate in keyword scan regardless of `vectorSearch` flag
- Backend (generationService.js:230-242): Vector results are merged with keyword results, deduplicated, keyword matches prioritized
- Frontend (LorebookSheet.vue:922): Hides keyword UI when `vectorSearch: true`
- Frontend (LorebookSheet.vue:921): Shows misleading "replaces keys" message

**Tasks**:
1. [done | ready for testing] **Remove keyword UI hiding** (LorebookSheet.vue:922)
   - Change: Removed `&& !activeEntry.vectorSearch` condition from `v-if`
   - Show keyword fields at all times — they work regardless of vector flag
   
2. [done | ready for testing] **Fix misleading "replaces keys" message** (LorebookSheet.vue:921)
   - Old: "Vector search replaces keys"
   - New: "Vector search supplements keyword matching (dual-channel retrieval)"
   - Color changed to green (--text-success) to indicate positive feature
   
3. [done | ready for testing] **Add retrieval source visibility**
   - Added badges in triggered lorebooks UI: `[keyword]` (green), `[vector]` (purple)
   - Uses existing `_source` tags from generationService.js:237-238
   - CSS: .retrieval-badge, .keyword-badge, .vector-badge
   
4. [intentional design | not changed] **Decouple constant from vectorSearch**
   - Decision: Keep mutual exclusion (constant entries don't need vector retrieval)
   - Constant entries are always active, so vectorSearch is redundant
   
5. [deferred | future work] **Optional: Add hybrid scoring visibility**
   - Show `hybridBoost` and `descriptorBoost` values in debug/advanced UI
   
6. [done | ready for testing] **Cleanup: Remove debug code** (lorebookState.js:1080-1110)
   - Removed 31 lines of Asei-specific debug logging from production code
   
7. [deferred | future work] **Add keyword+vector statistics**
   - Show summary in tokenizer or lorebook manager: "X by keyword, Y by vector, Z hybrid"

**Files modified**:
- `src/components/sheets/LorebookSheet.vue` — keyword UI visibility, message text, normalize useKeywordSearch
- `src/core/states/lorebookState.js` — removed debug code
- `src/components/chat/ChatMessage.vue` — retrieval source badges, CSS
- `src/workers/generationWorker.js` — filter vector-only entries (useKeywordSearch=false)
- `src/locales/en/index.json` — new i18n keys
- `src/locales/ru/index.json` — new i18n keys

**Testing**: See TESTING_CHECKLIST.md section 1

### Phase 2: Memory Books UX Improvements

Status: `partially done | ready for testing` (Commits: b5857d0, 78be7ed)

**Problem**: Memory Books UX had multiple usability issues: timer not updating, no regenerate button, navigation confusing, prompts too weak.

**Completed Tasks**:
1. [done | ready for testing] **Add PENDING badge for messages awaiting auto-generation**
   - Messages in `automation.pendingTrigger.messageIds` show gold pulsing PENDING badge
   - Users can now see which messages will be processed next by automation
   - Computed: `pendingMemoryMessageIds` ref, updated on chat open and after automation runs
   
2. [done | ready for testing] **Fix draft generation timer updates**
   - Removed refresh-based timer (no more sheet close/reopen flickering)
   - Added watch on `memoryDraftState.elapsedMs` → updates DOM directly via getElementById
   - Timer updates smoothly every 100ms without interruption
   - Message changed: "The timer will update automatically while generation is in progress"
   
3. [done | ready for testing] **Add regenerate button to draft preview**
   - Draft preview now shows "Regenerate" button (not available for approved entries)
   - Calls `generateMemoryDraftForMessages` with same message range
   - Shows toast on success/failure
   - Returns to Memory Books sheet after regeneration
   
4. [done | ready for testing] **Fix navigation: Back vs Close buttons**
   - Draft preview: shows "Back" button → returns to Memory Books sheet
   - Approved entry preview: shows "Close" button → closes preview only
   - Proper navigation flow restored
   
5. [done | ready for testing] **Improve memory generation prompts** (based on SillyTavern-MemoryBooks)
   - Replaced 3 weak prompts with 4 detailed, structured prompts:
     - `detailed_beats` (recommended, new default): beat-by-beat with Timeline/Story Beats/Key Interactions/Notable Details/Outcome
     - `concise_narrative`: 3-5 sentence compact summary
     - `structured_markdown`: markdown structure with clear sections
     - `minimal_factual`: 1-2 sentence minimal summary
   - Keyword guidelines: 5-30 concrete scene-specific keywords (locations, objects, proper nouns, unique actions)
   - Explicitly exclude: abstract themes, emotions, character names, [OOC] conversation
   - Default preset changed: `strict_factual` → `detailed_beats`
   - Reference: https://github.com/aikohanasaki/SillyTavern-MemoryBooks

**Remaining Tasks**:
1. [done] **Extract memory books UI into dedicated component** — Done in Phase 6. `MemoryBooksSheet.vue` created (1176 lines).
   
2. [not done] **Fix: Memory menu in chat doesn't persist settings state**
   - Settings from main Memory Books sheet should sync with in-chat memory UI
   - Both should use same session.memoryBooks[sessionId].settings source
   - Deferred: Need to investigate where in-chat memory menu is located
   
3. [not done] **Add comprehensive testing for memory lifecycle**
   - Test: Message deletion → memory reconciliation (ChatView.vue:2072-2096)
   - Test: Memory automation triggers (ChatView.vue:1022-1092)
   - Test: Vector search toggle for memories
   - Test: Draft generation and approval flow

**Files modified**:
- `src/views/ChatView.vue` — PENDING badge, timer watch, regenerate handler, navigation fix, improved prompts
- `src/components/chat/ChatMessage.vue` — PENDING badge prop, styling with pulse animation
- `src/utils/db.js` — default promptPreset changed to detailed_beats

**Testing**: See TESTING_CHECKLIST.md sections 3-6

### Phase 3: Tokenizer Performance & Loading

Status: `done | ready for testing` (Commit: b5857d0)

**Problem**: Tokenizer shows "Context breakdown is not ready yet" on first open and takes long time to open repeatedly.

**Completed Tasks**:
1. [done | ready for testing] **Fix "not ready yet" error on first open**
   - Added timeout-based wait in `openContextSheet()`: Promise.race with 5s timeout + 1s buffer
   - Improved error message: "Context calculation is taking longer than expected. Please check that your API settings are configured correctly"
   - No more confusing "not ready yet" on normal usage
   
2. [done | ready for testing] **Optimize tokenizer recalculation performance**
   - Added `debouncedUpdateContextCutoff()` helper with 300ms delay
   - Applied debounce to non-critical calls: delete messages, hide messages
   - Reduced redundant recalculations during rapid operations
   - Tokenizer now opens faster on repeated access

**Remaining Tasks (Deferred)**:
1. [not done] **Migrate tokenizer sheet display to dedicated component** (Optional)
   - Refactor ChatView.vue:2633-2745 (openContextSheet) to use SheetView.vue pattern
   - Note: This is LOW priority — current implementation works fine
   
2. [not done] **Add separate menus for different injection types**
   - Current: All lorebooks shown together in one view
   - Requested: Separate views for vector-only, keyword-injected, memory books
   
3. [not done] **Fix: All menus should return to previous screen on save/cancel**
   - Apply to: Tokenizer, Memory Books, Lorebook sheets
   - Use navigation stack pattern (already exists for prompt preview)

**Files modified**:
- `src/views/ChatView.vue` — timeout handling, debounce timer, debouncedUpdateContextCutoff()

**Testing**: See TESTING_CHECKLIST.md section 2

### Phase 4: Lorebook Optional Keyword Search for Vectorized Entries

Status: `done | ready for testing` (Commit: d215502)

**Problem**: When vector search is enabled for a lorebook entry, keyword search also runs (dual-channel), but user cannot optionally disable it.

**Solution**: Added `useKeywordSearch` flag with UI checkbox. Makes dual-channel optional instead of hardcoded.

**Tasks**:
1. [done | ready for testing] **Add `useKeywordSearch` flag to entry schema**
   - Default: `true` (preserves current dual-channel behavior for backward compatibility)
   - Only applies when `vectorSearch: true`
   - When `false`: entry excluded from keyword scan, vector-only retrieval
   - Normalized on `selectEntry()` for existing entries (defaults to true)
   
2. [done | ready for testing] **Update worker to respect flag**
   - generationWorker.js:167-169 — Filter entries with `vectorSearch && useKeywordSearch === false`
   - Comment updated: "DUAL-CHANNEL: All entries participate in keyword scan, unless vectorSearch is enabled AND useKeywordSearch is explicitly disabled"
   - Keeps current behavior for entries with `vectorSearch && useKeywordSearch`
   
3. [done | ready for testing] **Add UI checkbox in LorebookSheet**
   - Shows only when `vectorSearch: true` and `!constant`
   - Label: "Also use keyword matching"
   - Description: "Enable dual-channel retrieval: both vector similarity and keyword matching (recommended)"
   - Default: checked
   - i18n: `label_use_keyword_search`, `desc_use_keyword_search`

**Files modified**:
- `src/components/sheets/LorebookSheet.vue` — UI checkbox, normalize useKeywordSearch on selectEntry, schema default
- `src/workers/generationWorker.js` — keyword scan filter for vector-only entries
- `src/locales/en/index.json`, `src/locales/ru/index.json` — i18n keys

**Testing**: See TESTING_CHECKLIST.md section 1

### Phase 5: Memory Injection, Deletion Protection, Import Cleanup (2026-04-18)

Status: `done | ready for testing` (Commits: 3d5abbd, ddeb132, 587d83c, 7c320b8)
PR: #34

**5.1. Memory Injection Filter**
- [done | ready for testing] Entries only injected when first message of segment leaves context window
- Before: all active entries scored by overlap with recent history (+8 if any messageId in context)
- After: `eligibleEntries` filter — if `messageIds[0]` still in `recentMessageIds`, entry excluded from injection
- Entries without messageIds (manually created) always eligible
- File: `generationService.js:811-816`

**5.2. Delete Protection — Only Last Message(s)**
- [done | ready for testing] Selection toolbar: Delete button hidden unless selected messages are consecutive from end
- [done | ready for testing] Single message actions menu (open-actions): Delete option only for last message
- [done | ready for testing] Safety fallback in `deleteSelectedMessages()` — silently returns if not consecutive from end
- Files: `ChatInput.vue` (v-if canDeleteSelected), `ChatView.vue` (selectionIncludesLast computed, openMessageActions guard)

**5.3. Batch Draft Generation**
- [done] Scan Chat: finds uncovered messages, segments by interval, stores in `automation.plannedSegments`
- [done] Generate Drafts: quick picks (1/3/5/All) + custom number input field
- [done] Sequential generation with progress toasts, planned segments removed after success
- [done] DRAFT badge (purple) on messages covered by pending drafts
- Files: `ChatView.vue` (runBatchDraftGeneration, Scan Chat handler, batch UI), `ChatMessage.vue` (isDraftMemory prop, draft-memory CSS)

**5.4. Import Cleanup**
- [done | ready for testing] `chatImporter.js`: clear `pendingDrafts`, `pendingTrigger`, `plannedSegments` on import
- [done | ready for testing] `chatImporter.js`: reset invalid `promptPreset` (e.g. stale `durable_events` key) to `detailed_beats`
- [done | ready for testing] `chatImporter.js`: clear `generationModel` and `generationUseCurrentModelOverride` (model may not exist on another device)
- [done | ready for testing] `ChatView.vue`: after import, set `lastProcessedMessageCount` = total messages to prevent auto-trigger

**5.5. Prompt Preset Validation**
- [done | ready for testing] Preview Rule: fallback to `options[0]` when preset key not found
- [done | ready for testing] Settings state builder: validate `promptPreset` against `getMemoryPromptOptions()`, fallback to `detailed_beats`
- Root cause: exported chats contained stale preset key `durable_events` which no longer exists in built-in prompts

**5.6. Draft Stop Button**
- [done | ready for testing] `memoryDraftAbortController` — AbortController passed to `generateMemoryDraft()`
- [done | ready for testing] Red "Stop" button in progress card, calls `cancelMemoryDraft()`
- [done | ready for testing] Batch generation loop checks `aborted` signal before each iteration
- [done | ready for testing] CSS: `.context-sheet-btn-destructive` (red background)

**5.7. scanDepth Default Fix**
- [done | ready for testing] Changed global `scanDepth` from `1000` to `10`
- [done | ready for testing] Changed per-entry fallback: `entry.scanDepth ?? globalSettings.scanDepth ?? 10`
- [done | ready for testing] "Apply Global Settings" resets `entry.scanDepth` to `null`

**5.8. Draft Generation Fixes (from 09f8adf)**
- [done | ready for testing] Manual draft skips conflict check (source `manual_draft`/`manual_regenerate`)
- [done | ready for testing] `generateMemoryDraft`: added `onError` callback, `stream: false` parameter
- [done | ready for testing] Error toast now visible (closeBottomSheet before showToast)
- [done | ready for testing] Memory Books sheet opens immediately for manual draft (shows progress card)

### Testing Results & Known Issues (2026-04-18)

**Verified Working:**
- ✅ Tokenizer cache works (instant second open)
- ✅ Match Whole Words updated to ST/Glaze/Off format
- ✅ Regenerate button added for approved entries and drafts
- ✅ PENDING badges show on messages awaiting auto-generation
- ✅ Back navigation for prompt preview works
- ✅ Scan Chat + Generate Drafts batch flow works
- ✅ DRAFT badges (purple) show on messages covered by pending drafts
- ✅ Generate Drafts menu: quick picks + custom number input
- ✅ Draft generation with progress and sequential processing

**Bugs Found During Testing (fixed in this branch):**
1. ✅ **Draft generation status not showing** — FIXED (watch on memoryDraftState, onError callback, stream:false)
2. ✅ **Delete from middle of chat possible** — FIXED (two paths: selection toolbar + open-actions menu)
3. ✅ **Auto-draft triggers on import** — FIXED (cleared pendingDrafts/pendingTrigger, set lastProcessedMessageCount)
4. ✅ **Prompt preset not loading** — FIXED (stale `durable_events` key, added validation + fallback)
5. ✅ **Generate Drafts button did nothing** — FIXED (`action` → `onClick` for BottomSheet items)

**Known Issues (not fixed):**
1. ❌ **Retrieval badges still not showing after regeneration** (HIGH)
   - Issue: _source added to triggeredLorebooks, but badges still invisible
   - Status: `not fixed | pending investigation`

2. ⚠️ **Tokenizer first load slow (4.6s)** (MEDIUM)
   - Acceptable — cache works, optimization deferred
   - Status: `acceptable | optimization deferred`

### Execution Order

1. ✅ **Phase 1** (Vector/Lorebook UX) — COMPLETED
2. ✅ **Phase 4** (Optional keyword search) — COMPLETED
3. ✅ **Phase 2** (Memory Books UX) — COMPLETED (5/5 tasks + extras)
4. ✅ **Phase 3** (Tokenizer) — COMPLETED (2/3 tasks, remaining deferred)
5. ✅ **Phase 5** (Injection filter, deletion, import, batch, stop) — COMPLETED

### Remaining Work (Deferred)

**HIGH Priority:**
- [ ] Fix retrieval badges not showing after regeneration

**MEDIUM Priority:**
- [ ] Memory Books settings sync (main ↔ in-chat menu)
- [x] Extract Memory Books UI to dedicated component (MemoryBooksSheet.vue, done in Phase 6)
- [ ] Separate menus for injection types (vector/keyword/memory)

**LOW Priority:**
- [ ] Background tokenizer pre-calculation (battery consideration)
- [ ] Extract tokenizer to dedicated component
- [ ] Universal navigation stack for all sheets

### Phase 6: Component Extraction Refactoring (2026-04-18)

**Goal:** Reduce ChatView.vue complexity by extracting large UI sections into dedicated SheetView-based components.

**Status:** `done`

**Motivation:**
- ChatView.vue is ~7000 lines, making it difficult to maintain and navigate
- Tokenizer, Memory Books, and Vectorization UIs are implemented as inline HTML in `showBottomSheet` calls
- Moving to dedicated Vue components improves:
  - Code organization and reusability
  - Type safety and IDE support
  - Testing capabilities
  - Maintainability

**Tasks:**

1. **Extract Tokenizer to TokenizerSheet.vue**
   - Status: `done`
   - Create `src/components/sheets/TokenizerSheet.vue` using SheetView
   - Props: breakdown, historyHidePreview, contextSegments, contextLegendItems, contextBreakdownItems, shouldRecommendHide, historyUsagePercent, isCalculating
   - Emits: close, hide-messages, open-settings
   - Replace `openContextSheet()` in ChatView with `tokenizerSheetRef.open()`
   - Files modified:
     - [x] `src/components/sheets/TokenizerSheet.vue` (created, 543 lines)
     - [x] `src/views/ChatView.vue` (integrate component, remove ~100 lines inline HTML)
   - Build: passes ✓
   - Commit: `3d03952`

2. **Extract Memory Books to MemoryBooksSheet.vue**
   - Status: `done`
   - Create dedicated component for memory book management UI
   - Extract `openMemoryBooksSheet()` logic (~500+ lines inline HTML)
   - Complexity: high — many event handlers, dynamic sections (drafts/entries/settings)
   - Props: memoryBook, currentMessages, characterName, sessionId, memoryDraftState, pendingMemoryMessageIds
   - Emits: 11 events (approve-draft, delete-draft, scan-chat, batch-generate, open-settings, open-maintenance, etc.)
   - Files modified:
     - [x] `src/components/sheets/MemoryBooksSheet.vue` (created, 883 lines)
     - [x] `src/views/ChatView.vue` (removed ~500 lines inline HTML, added 11 event handlers, added `loadCurrentMemoryBook()` helper)
   - Build: passes ✓
   - Commit: `f332d0f`

3. **Extract Vectorization UI to VectorizationSheet.vue**
   - Status: `deferred`
   - Priority: low (vectorization UI is relatively small and already modular)
   - Create dedicated component for lorebook vectorization UI
   - Extract embedding status, reindex, and vector search settings

**Summary:**
- ✅ TokenizerSheet.vue (543 lines) — DONE
- ✅ MemoryBooksSheet.vue (883 lines) — DONE
- ⏸️ VectorizationSheet.vue — DEFERRED (low priority)
- ✅ ChatView.vue reduced by ~600 lines of inline HTML (6982 → 6764 lines)

**Impact:**
- Improved code organization: separate components vs inline HTML strings
- Better type safety and IDE support
- Enhanced testability: components can be tested in isolation
- Easier maintenance: changes isolated to specific components

### Phase 7: Backend/Service Extraction (2026-04-18)

**Goal:** Extract business logic from ChatView.vue into reusable services and composables.

**Status:** `done`

**Branch:** `feat/component-extraction` (continues from Phase 6)

**Motivation:**
- ChatView.vue still contains ~68 Memory Books functions and ~11 context/tokenizer functions
- Business logic is tightly coupled with UI
- Pure functions should be in services for better testing and reusability
- Reactive state should be managed in composables

**Tasks:**

1. **Create Memory Books Service**
   - Status: `done`
   - File: `src/core/services/memoryBooksService.js` (616 lines)
   - Extracted 68+ pure functions:
     - Core management (ensureSessionMemoryBook, reconcileMemoryBookForMessages)
     - Entry operations (normalizeMemoryEntryShape, findConflictingMemoryEntry)
     - Vector/embedding (indexMemoryEntryIfNeeded, reindexAllMemoryEntries)
     - Draft generation (generateMemoryDraftForMessages, runBatchDraftGeneration)
     - Prompt management (resolveMemoryPrompt, getMemoryPromptOptions)
     - Automation (runMemoryAutomationAfterStableTurn, buildBootstrapSegments)
     - Utilities (arraysEqual, calculateMessageOverlapRatio, formatElapsedSeconds)
   - Build: passes ✓
   - Commit: `4f43d51`

2. **Create Memory Books Composable**
   - Status: `done`
   - File: `src/composables/chat/useMemoryBooks.js` (650 lines)
   - Reactive state:
     - currentMemoryBookData, pendingMemoryMessageIds, draftMemoryMessageIds
     - memoryDraftState (progress tracking)
   - UI handlers (11 total):
     - handleMemoryKeyModeUpdate, handleMemoryVectorToggle
     - handleMemoryReindexAll, handleMemoryScanChat
     - handleMemoryBatchGenerate, handleMemoryApproveDraft
     - handleMemoryDeleteDraft, handleMemoryDeleteEntry
     - handleMemoryCancelDraft, handleMemoryOpenMaintenance
   - Draft progress functions:
     - startMemoryDraftProgress, stopMemoryDraftProgress, cancelMemoryDraft
   - Data loading:
     - loadCurrentMemoryBook, updatePendingMemoryMessageIds
   - Build: passes ✓
   - Commit: `4f43d51`

3. **Create Context Service (Placeholder)**
   - Status: `done`
   - File: `src/core/services/contextService.js` (empty placeholder)
   - Prepared for future Phase 9 (context/tokenizer extraction)
   - Build: passes ✓
   - Commit: `4f43d51`

4. **Update ChatView.vue**
   - Status: `done`
   - Changes:
     - Added imports for memoryBooksService and useMemoryBooks composable
     - Replaced 68+ local functions with service imports
     - Removed duplicate Memory Books functions
     - Created wrapper handlers to maintain event signature compatibility
     - Updated all calls to loadCurrentMemoryBook/updatePendingMemoryMessageIds
   - Size reduction: 6787 → 6010 lines (-777 lines, -12%)
   - Build: passes ✓
   - Commit: `4f43d51`

**Summary:**
- ✅ memoryBooksService.js (616 lines) — DONE
- ✅ useMemoryBooks.js composable (650 lines) — DONE
- ✅ contextService.js placeholder — DONE
- ✅ ChatView.vue reduced by 777 lines (6787 → 6010 lines)

**Impact:**
- Isolated business logic from UI concerns
- Pure functions can now be unit tested independently
- Better code organization: services → composables → components
- Improved maintainability and reusability
- Reduced ChatView complexity by ~12%

### Phase 8-9: Context Service + Navigation (2026-04-18)

**Goal:** Extract context/tokenizer utilities to service and fix sheet navigation.

**Status:** `done`

**Branch:** `feat/component-extraction` (continues from Phase 7)

**Tasks:**

1. **Create Context Service**
   - Status: `done`
   - File: `src/core/services/contextService.js` (~120 lines)
   - Extracted functions:
     - Validation: clampHistoryFillThreshold, clampHistoryHidePercent
     - Settings: loadHistoryContextSettings, persistHistoryContextSettings
     - Calculations: shouldRecommendHide, calculateHistoryUsagePercent, calculateMessagesToHide
   - Build: passes ✓
   - Commit: `412c6ab`

2. **Fix Sheet Navigation**
   - Status: `done`
   - Problem: Sheets were closing completely instead of returning to MagicDrawer
   - Solution:
     - Added `showBack` prop to TokenizerSheet and MemoryBooksSheet
     - Emit `back` event instead of `close` for actions
     - Added `openMagicDrawer()` to ChatInput exposed methods
     - Created `handleSheetBack()` in ChatView to orchestrate navigation
   - Flow: MagicDrawer → Sheet → Action → back to MagicDrawer ✓
   - Build: passes ✓
   - Commit: `412c6ab`

3. **Update ChatView**
   - Status: `done`
   - Replaced local context functions with contextService imports
   - Simplified history settings initialization
   - Added @back handlers for sheets
   - Size: 6010 → 5995 lines (-15 lines)
   - Build: passes ✓
   - Commit: `412c6ab`

**Summary:**
- ✅ contextService.js (120 lines) — DONE
- ✅ Sheet navigation fixed — DONE
- ✅ ChatView updated — DONE
- ✅ ChatView reduced by 15 lines (6010 → 5995 lines)

**Impact:**
- Context utilities isolated in service
- Proper navigation UX: sheets return to drawer instead of closing
- Better user experience with back button
- Cleaner separation of concerns

### Testing Checklist

After each phase:
- [x] `npm run build` passes without errors
- [x] Manual testing in browser (web build)
- [x] Verify backward compatibility (existing lorebooks/memories load correctly)
- [x] Check console for errors
- [x] Test on mobile: batch generation, delete protection, import cleanup
- [x] PR created: #34

## Sync Setup Guide — For Developers

### Maintainer Goal

- **Status:** done
- **Testing:** not tested
- After merge, the maintainer should only need to add OAuth app keys to `.env`.
- End users still authenticate into their **own** Dropbox or Google Drive accounts. Glaze does not sync everyone into one shared maintainer-owned cloud.
- Provider buttons are only shown when the corresponding OAuth env key is present in the build.

### Shortest Setup Path

1. Copy `.env.example` to `.env` if needed.
2. Add `VITE_DROPBOX_APP_KEY=...`.
3. Register the Dropbox redirect URIs listed below.
4. Build and ship.

That is the shortest maintainer path. Google Drive remains available, but it needs its own OAuth client configuration and is not required for cloud sync to work.

### Platform Status

- **Windows (Electron):** done / not tested
- **Linux (Electron):** done / not tested
- **Android (Capacitor):** done / not tested
- **iPhone (Capacitor iOS):** done / not tested

Meaning: the repo now contains callback plumbing for desktop loopback OAuth and mobile deep-link OAuth, but provider sign-in still needs manual verification against real Dropbox / Google OAuth apps.

### How Cloud Sync Works

Glaze syncs data to cloud storage (Dropbox or Google Drive) using an incremental manifest-based approach:
1. **Manifest** (`manifest.json`) tracks every entity with `{type, id, path, updatedAt, hash, deleted}`
2. **Push**: Compare local manifest vs cloud manifest → upload only changed entities
3. **Pull**: Compare cloud manifest vs local manifest → download only newer entities
4. **Conflicts**: If local is newer AND cloud is newer → surface conflict for manual resolution

### Auth Model

1. Maintainer configures the app-level OAuth client IDs/keys in `.env`.
2. User taps a provider in the Sync sheet.
3. The provider OAuth flow returns tokens for **that specific user account**.
4. Tokens are stored locally on the device.
5. Sync uploads into that user's own cloud storage under `/Glaze`.

This means maintainer credentials only identify the Glaze OAuth app. They do not decide where user data is stored.

### Platform Setup

#### 1. Dropbox

**Create a Dropbox App:**
1. Go to https://www.dropbox.com/developers/apps
2. Click "Create app" → choose "Scoped access" → "Full Dropbox" (or "App folder" if preferred)
3. Note your **App key**

**Configure OAuth redirect URIs:**
- In the Dropbox App Console → Settings → OAuth 2 → Redirect URIs
- Add ALL redirect URIs you will use:
  - **Native (Android/iOS)**: `com.hydall.glaze://oauth/dropbox`
  - **Web (production)**: `https://yourdomain.com/oauth/dropbox/redirect.html`
  - **Web (dev)**: `http://localhost:5173/oauth/dropbox/redirect.html`
  - **Electron (desktop)**: `http://127.0.0.1:PORT/oauth/callback` (loopback)

**Environment variables (`.env`):**
```
VITE_DROPBOX_APP_KEY=your_app_key_here
# Optional overrides (defaults shown):
# VITE_DROPBOX_REDIRECT_NATIVE=com.hydall.glaze://oauth/dropbox
# VITE_DROPBOX_REDIRECT_WEB=https://yourdomain.com/oauth/dropbox/redirect.html
```

**Android/iOS config:**
- Ensure `capacitor.config.json` has `"appId": "com.hydall.glaze"` (must match redirect URI scheme)
- For Android: `android/app/src/main/AndroidManifest.xml` now contains a `VIEW` / `BROWSABLE` intent-filter for `com.hydall.glaze://`
- For iOS: `ios/App/App/Info.plist` now registers `CFBundleURLTypes` for `com.hydall.glaze`, and `ios/App/App/AppDelegate.swift` forwards the callback to Capacitor

#### 2. Google Drive

**Create a Google Cloud project:**
1. Go to https://console.cloud.google.com
2. Create a project → Enable Google Drive API
3. Go to "Credentials" → "Create OAuth client ID" → "Web application"
4. Note your **Client ID**

**Configure redirect URIs:**
- In Google Cloud Console → Credentials → your OAuth client → "Authorized redirect URIs"
- Add ALL redirect URIs:
  - **Native (Android/iOS)**: `com.hydall.glaze://oauth/gdrive`
  - **Web (production)**: `https://yourdomain.com/oauth/gdrive/redirect.html`
  - **Web (dev)**: `http://localhost:5173/oauth/gdrive/redirect.html`
  - **Electron (desktop)**: `http://127.0.0.1:PORT/oauth/callback` (loopback)

**Environment variables (`.env`):**
```
VITE_GDRIVE_CLIENT_ID=your_client_id_here
# Optional overrides:
# VITE_GDRIVE_REDIRECT_NATIVE=com.hydall.glaze://oauth/gdrive
# VITE_GDRIVE_REDIRECT_WEB=https://yourdomain.com/oauth/gdrive/redirect.html
```

Glaze uses OAuth PKCE in the client, so `VITE_GDRIVE_CLIENT_SECRET` is intentionally not used.

### Error 400 Troubleshooting

**Error 400 on OAuth token exchange** = `redirect_uri` mismatch.

The `redirect_uri` sent in the OAuth authorize request must **exactly match** the `redirect_uri` sent in the token exchange request AND must be registered in the provider's OAuth console.

Common causes:
1. **Hardcoded localhost in production**: Old code used `http://localhost:5173/...` — this only works in dev. Fixed: now uses `window.location.origin` as default.
2. **Missing redirect URI in OAuth console**: The URI you deploy with must be added to the app's redirect URI list in Dropbox/Google console.
3. **Platform mismatch**: Native builds use `com.hydall.glaze://...` scheme. Web builds use `https://...`. Each platform needs its own redirect URI registered.
4. **Port mismatch for Electron**: Electron uses loopback `http://127.0.0.1:PORT/oauth/callback` with a random port. The OAuth provider must allow loopback redirects (Google does by default for "Desktop app" client type; Dropbox requires adding it explicitly).

### Error 401/403 Troubleshooting

- **401**: Access token expired → auto-refresh via `refresh_token`. If refresh also fails → user must reconnect.
- **403**: App permissions revoked or API quota exceeded. User must reconnect.

### Encryption (Optional)

Encryption uses AES-256-GCM via Web Crypto API, key derived from a 12-word BIP39 mnemonic.
- **Without encryption**: Data stored as plain JSON in cloud. Simple, portable, debuggable.
- **With encryption**: Each entity encrypted before upload. Recovery phrase required to decrypt on other devices.
- **Migration**: If cloud has `.enc` files and encryption is disabled, the system attempts to read both `.enc` and `.json` variants.
- **Key files**: `src/core/services/crypto/syncCrypto.js` (AES-GCM), `src/core/services/crypto/keyManager.js` (BIP39, storage)
