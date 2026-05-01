# Refactor History

Completed phases of the architecture refactor. This file is for reference only — it records what was done and why, not what to do next.

For current gaps and deferred items, see `docs/rules/known-gaps.md`.

## Target Architecture

The refactor target is a hybrid model:

```text
UI
  -> Use Cases
    -> Ordered Pipelines
      -> Transport

Side effects / observers
  <- Event Hub <- Use Cases / Pipelines
```

- `UI` gathers user intent and renders state.
- `Use Cases` own actions like chat generation, summary generation, and memory-draft generation.
- `Ordered Pipelines` preserve correctness-critical ordering for prompt and request flow.
- `Event Hub` carries domain facts and optional side effects, but does not replace orchestration.

## Before Refactor

The app was functional, but core ownership was too concentrated:

- `ChatView.vue` owned too much chat-generation orchestration, UI coordination, and request lifecycle glue.
- `generationService.js` mixed prompt construction, enrichment, payload assembly, preview state, and request dispatch.
- Many cross-feature reactions depended on ad-hoc `window.dispatchEvent(...)` with no catalog or ownership boundary.

## Phase 1 — Event Layer Skeleton

Files added: `eventNames.js`, `contracts.js`, `eventHub.js`

- 56 canonical events across 4 namespaces (`nav.*`, `domain.*`, `debug.*`, `ui.*`)
- All internal emitters use `publishAppEvent()`, all listeners use `subscribeAppEvent()`
- Legacy `windowEventBridge` removed
- Cancelable events via `publishCancelableAppEvent()` with `preventDefault()` semantics
- Dead code events (5): listeners with no dispatches — not removed, future cleanup

Files migrated: App.vue, AppHeader.vue, ChatInput.vue, ChatMessage.vue, GenericEditor.vue, DesktopLeftSidebar.vue, BottomSheet.vue, DragDropOverlay.vue, HelpTip.vue, CharacterCardSheet.vue, GlossarySheet.vue, LorebookSheet.vue, RegexSheet.vue, SyncSheet.vue, NotificationsSheet.vue, ImageViewer.vue, HoloCardViewer.vue, ApiView.vue, CatalogView.vue, CharacterList.vue, DialogList.vue, PersonasView.vue, PresetView.vue, ToolsView.vue, MenuView.vue, SettingsView.vue, ThemeSettingsView.vue, AboutView.vue, OnboardingView.vue, ui.js, notificationService.js, APISettings.js, catalogState.js, main.js, characterIO.js, errors.js, useChatMessageDisplay.js

## Phase 2 — Request Ownership Safety Slice

- Generation state carries `ownerKey`, `requestToken`, `sessionId`, `type`
- Stream/completion/error/abort validate ownership before mutating state
- Impersonation keeps separate ownership scope
- Fixed: `onUnmounted` now calls `clearGenerationState`
- Fixed: stale completion path uses `finalizeGenerationState`

## Phase 9 — State Ownership Boundaries

- `generationState.js` — explicit generation state module with ownership API
- `useGenerationRegistry.js` — registers generation state per-session with ownership tokens
- `useAutoSync.js` — depends on `syncState` instead of importing from ChatView
- `usePromptMetadataSnapshots.js` — stores/restores snapshots for rollback
- Fixed TDZ bug: `getScrollAnchor` reorder in ChatView.vue

## Phase 11 — Use-Case Layer Re-architecture

File renames/moves:
- `chatPipelineContext.js` → `pipeline/pipelineContext.js`
- `chatPipelineSteps.js` → `pipeline/steps.js`
- `chatPostPromptPipeline.js` → `pipeline/postPromptOrchestrator.js`
- `chatContextCalculation.js` → `usecases/contextCalculation.js`
- `chatRequestExecution.js` → `usecases/chatRequestAssembly.js`
- `nonChatGenerationHooks.js` → `usecases/sharedRequestHooks.js`
- `chatCompletionsClient.js` → `transport/completionsClient.js`

File splits:
- `chatLateEnrichment.js` → `vectorLoreInjection.js` + `memoryMessageInjection.js`
- `chatPromptShared.js` → `promptConfigReaders.js` + `promptWorkerLifecycle.js` + `promptPayloadBuilder.js`
- `memoryBookContext.js` → `memoryEmbeddingIndex.js` + `memoryKeyMatching.js` + `memoryContextInjection.js`

Hollow entrypoints eliminated: `calculateContext.js`, `generateSummary.js`, `generateMemoryDraft.js` now own their dependency assembly locally.

`generationService.js` reduced from 267 → 158 lines.

## Phase 12 — Transport Split & Legacy Cleanup

- Transport fully split: `requestOrchestrator.js` → `completionsClient.js`, `requestLifecycle.js`, `requestExecution.js`, `streamingSse.js`, `responseHandling.js`, `requestOutcome.js`, `requestRuntimePolicy.js`, `streamAccumulator.js`, `responseNormalizer.js`, `sseParser.js`
- Dead params removed from use-case signatures
- `createChatGenerationServices` factory wires all deps, ChatView no longer assembles ~30-function injection bundle

## Phase 13a — App.vue Decomposition

App.vue: 1229 → 622 lines script. Extracted:
- `useAppNavigation.js` — view routing, desktop/mobile detection
- `useEditorController.js` — character/persona editor lifecycle
- `useAppEventSubscriptions.js` — 23 subscribeAppEvent calls + cleanup
- `useGlossaryPopup.js` — desktop glossary drag popup
- `useAppInit.js` — onMounted initialization sequence

## Phase 13b — PresetView Decomposition

Deleted: `usePresetEditor.js` (2080-line god-object)

Extracted (all `src/composables/app/`):
- `usePresetNavigation.js` (107) — switching, list, drag reorder
- `usePresetLoader.js` (89) — loading, cache, flush save
- `usePresetConnections.js` (33) — connection queries
- `usePresetCRUD.js` (173) — create, delete, duplicate, rename, import, export
- `usePresetSelectors.js` (171) — bottom-sheet selectors
- `usePresetImage.js` (40) — image selection, compression
- `useBlockManager.js` (141) — block CRUD, stash/unstash
- `useBlockEditor.js` (94) — CodeMirror lifecycle
- `useAuthorsNoteSheet.js` (73) — authors note sheet
- `useSummarySheet.js` (126) — summary sheet
- `usePresetTokenPreview.js` (177) — token estimation, macro preview

PresetView.vue: 279 lines script (from 2080).

## Phase 13c — lorebookState.js Decomposition

lorebookState.js: 1319 → 326 lines (state + CRUD). Extracted:
- `lorebookSearchService.js` (182) — keyword scan logic
- `lorebookVectorSearch.js` (431) — vector search, hybrid/descriptor scoring
- `lorebookEmbeddingService.js` (352) — embedding orchestration, hash, status
- Re-exports from lorebookState.js for backward compatibility

## Phase 13d — ChatMessage.vue Decomposition

ChatMessage.vue: 1985 → 1621 lines. Extracted:
- `useMessageSwipe.js` (262) — touch/swipe/long-press
- `useMessageImageGen.js` (149) — image gen handler

Script: 624 → 334 lines.

## Phase 13e — ChatInput.vue Decomposition

ChatInput.vue: 1155 → 905 lines. Extracted:
- `useContentEditable.js` (128) — caret, text, preview
- `useInputActions.js` (168) — send, guidance, image, fullscreen

Script: 420 → 170 lines.

## Phase 13f–13g — LorebookSheet.vue Decomposition

Extracted:
- `useLorebookEntries.js` (157) — entry CRUD, reorder, search/filter
- `useLorebookIndexing.js` (93) — index, retry, status counts

Script: 572 → 290 lines.

## Phase 13h–13i — ApiView.vue Decomposition

Extracted:
- `useApiSettings.js` (237) — API state, presets, connection, model selector
- `useServiceProviders.js` (128) — embedding, imageGen, memory provider settings

Script: ~645 → 140 lines.

## Phase 13j–13k — CharacterList.vue Decomposition

Extracted:
- `useCharacterActions.js` (179) — add/import, edit, export, favorite, delete
- `useSessionSheet.js` (168) — session list, CRUD, import chat

Script: 585 → 175 lines.

## Phase 13l — ThemeSettingsView.vue Decomposition

Extracted:
- `useThemePresets.js` (267) — preset CRUD, apply, export, import

Script: 495 → 236 lines.

## Phase 14 — Final Legacy Cleanup

- Deleted 7 dead re-export shims + dead `useViewer` composable
- Removed `getLegacyApiConfig`/`getLegacyEmbeddingConfig` + `emitLegacyCompatibleEvent`
- Migrated `app-back-navigation` from `window.dispatchEvent` to `publishCancelableAppEvent`
- Removed `windowEventBridge` entirely
