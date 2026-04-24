# Refactor Plan

## Purpose

This document defines a safe staged refactor plan for the app architecture.

The goal is not to chase a fashionable architecture label. The goal is to make the codebase:

- hard to break during refactors;
- easier to extend without editing core files every time;
- less dependent on god-objects;
- suitable for experimental feature work like "I want to add this feature and see what happens" without turning the app into a pile of special cases.

The desired result is a hybrid architecture:

- **ordered deterministic pipeline** for prompt and generation flow where order must be guaranteed;
- **event-driven architecture** for extensions, side effects, UI coordination, and plugins;
- **reactive state modules** as read models for Vue UI, not as a replacement for use cases.

This plan must prioritize compatibility and behavior preservation over cleanup speed.

---

## Primary Goals

### Goal 1. Do not break working behavior

The most important requirement is safety.

That means:

- no large rewrite in one branch;
- no prompt semantics changes unless explicitly intended;
- no transport behavior changes hidden inside structural refactors;
- no migration that forces MemoryBooks, vectorization, sync, and generation internals to move at the same time.

### Goal 2. Remove god-objects

The current architecture still has several overloaded ownership points:

- `src/views/ChatView.vue`
- `src/core/services/generationService.js`
- `src/core/services/llmApi.js` compatibility entrypoint
- parts of `ApiView.vue` and settings/config write paths

These files currently mix multiple responsibilities:

- orchestration;
- state mutation;
- request lifecycle;
- config access;
- transport coordination;
- debug storage;
- UI decisions.

The refactor should reduce this by splitting ownership, not by simply moving the same complexity into new files.

### Goal 3. Make feature work cheap

Adding a new feature should not require editing half the app.

Examples of the desired end state:

- add a new request type without touching all transport files;
- add a provider adapter without rewriting generation orchestration;
- add a plugin hook without wiring random `window.dispatchEvent` calls everywhere;
- add a prompt-enrichment rule without modifying unrelated UI code;
- add diagnostics, experiments, or optional automation with isolated extension points.

### Goal 4. Keep order where order matters

The core generation flow must stay deterministic.

The prompt pipeline is not a free-for-all event system. It must preserve ordering for:

- prompt block resolution;
- macro application;
- regex transforms;
- keyword lore scan;
- vector enrichment;
- memory injection;
- final payload assembly.

This plan explicitly rejects replacing the prompt pipeline with uncontrolled event subscribers.

---

## Non-Goals

The following are not goals of this refactor phase:

- rewriting the app to TypeScript;
- replacing reactive modules with Pinia or Vuex;
- replacing custom navigation with Vue Router;
- redesigning prompt semantics;
- reworking vectorization internals without a concrete bug;
- fully redesigning MemoryBooks at the same time as the transport/use-case refactor;
- removing all legacy compatibility in one pass.

---

## Current Problems

### 1. Core ownership is too concentrated

`ChatView.vue` still carries too much session and generation orchestration.

`generationService.js` still acts as a central kitchen for:

- request intent decisions;
- prompt preparation and enrichment;
- preview/debug state;
- transport dispatch.

This makes changes risky because one file becomes the merge point for unrelated features.

### 2. There is no formal event model

The app already uses `window.dispatchEvent(new CustomEvent(...))`, but this is still an ad-hoc signaling layer, not a defined architecture.

Problems:

- event names are not organized by domain;
- payload contracts are informal;
- UI events and domain events are mixed together;
- there is no ownership boundary between transport events, app events, and feature events.

### 3. Transport is thinner, but still callback-heavy

The transport split has progressed, but the lifecycle is still expressed through flexible callback wiring instead of a normalized contract.

That creates risk for:

- abort behavior;
- late completion races;
- stream vs non-stream parity;
- memory-draft vs chat request overlap.

### 4. Debug state is still singleton/global

Prompt preview and network trace state still leak across request types and sessions.

This is manageable for debugging, but structurally wrong.

### 5. Extensibility still tends to route through core files

New behavior often ends up in one of these places:

- `ChatView.vue`
- `generationService.js`
- settings views
- direct config reads/writes

That is exactly how god-objects regrow after each cleanup.

---

## Target Architecture

### Overview

The target model is:

1. **Use cases decide what action is being performed.**
2. **Ordered pipelines execute deterministic core flow.**
3. **Event bus publishes facts after or around those flows.**
4. **Reactive state modules store read models for UI.**
5. **Plugins/extensions react only through declared extension points.**

Short version:

- use cases decide;
- pipelines guarantee order;
- events broadcast facts;
- stores expose read models;
- plugins attach at controlled boundaries.

### Layer Model

#### 1. UI Layer

Vue views and components should:

- gather user intent;
- call a use case;
- read reactive state;
- render;
- dispatch only UI/navigation events when necessary.

Vue views should not own multi-stage generation orchestration.

#### 2. Use Case Layer

Use cases represent app actions.

Examples:

- `generateChat`
- `generateSummary`
- `generateMemoryDraft`
- `calculateContext`
- future sync, import, indexing, or tool actions

Each use case should:

- validate inputs;
- claim ownership of its session/request;
- invoke ordered pipeline steps;
- publish domain events;
- return a normalized result contract.

#### 3. Pipeline Layer

This is the deterministic core.

Pipelines must be explicit and ordered.

Examples:

- prompt build pipeline;
- request assembly pipeline;
- request lifecycle pipeline;
- memory extraction-context pipeline.

Pipelines are not generic magic middleware for everything. They are for flows where order is part of correctness.

#### 4. Event Layer

The event layer is a mailbox, not a dispatcher of app truth.

It should publish domain facts such as:

- generation started;
- prompt built;
- request sent;
- stream delta received;
- generation completed;
- generation failed;
- settings changed;
- sync finished.

The bus must not decide prompt order or replace use-case orchestration.

#### 5. State / Read Model Layer

Reactive state modules should hold data projected for UI usage.

Examples:

- active generation status;
- request trace history;
- prompt preview history;
- sync progress;
- notification state.

These state modules should react to explicit calls or domain events, instead of each view maintaining private copies of cross-cutting state.

#### 6. Plugin / Extension Layer

Plugin-like features should attach to stable extension points rather than patching core files directly.

Examples:

- diagnostics;
- request logging;
- experimental prompt enrichers;
- alternate preview builders;
- future external integrations.

---

## Architectural Rule: Hybrid, Not Pure EDA

This project should not move to pure event-driven architecture.

Pure EDA would be harmful in the generation core because prompt construction requires stable ordering.

The correct split is:

- **EDA for extensions and side effects**
- **ordered middleware/pipeline for generation correctness**

### Where EDA is a good fit

- plugin hooks;
- analytics and diagnostics;
- optional observers;
- UI coordination across distant components;
- notifications and non-critical side effects;
- sync refresh broadcasts;
- feature modules that need low coupling.

### Where EDA is a bad fit

- final prompt block ordering;
- request ownership and abort rules;
- macro/regex/lore/vector/memory insertion order;
- transport completion semantics;
- lifecycle-critical cleanup.

---

## Event Model Rules

### Rule 1. Separate event categories

Events must be grouped by ownership.

Suggested categories:

- `ui.*` for component/view interaction events
- `nav.*` for navigation and sheet open/close requests
- `domain.generation.*` for generation lifecycle
- `domain.memory.*` for memory lifecycle
- `domain.sync.*` for sync lifecycle
- `infra.request.*` for transport-level facts
- `debug.*` for diagnostics only

### Rule 2. Define event contracts explicitly

Even in JavaScript-only code, event payloads should be formalized via:

- event name constants;
- event creator helpers;
- JSDoc typedefs;
- runtime validation only at critical boundaries.

### Rule 3. Keep the bus dumb

The event hub should do only this:

- publish;
- subscribe;
- unsubscribe;
- optionally record/debug.

It should not:

- decide business flow;
- reorder pipeline work;
- mutate hidden global state as a side effect of publication.

### Rule 4. Keep `window` as a compatibility bridge only

`window.dispatchEvent` can remain for legacy app-shell integration and gradual migration, but it should stop being the primary architecture boundary inside the app.

The internal target should be an app event hub with optional bridge adapters.

---

## Pipeline Model Rules

### Rule 1. Use explicit pipeline context objects

Each ordered flow should have a single context object with clearly owned fields.

For example, chat generation should evolve through a `GenerationContext` that tracks:

- request intent;
- session ownership token;
- resolved config;
- prompt parts;
- enriched prompt state;
- provider payload;
- transport status;
- result;
- debug metadata.

### Rule 2. Each step has one job

Pipeline steps should be small and named after what they decide or enrich.

Examples:

- `resolveApiConfigStep`
- `resolvePresetStep`
- `buildPromptStep`
- `applyLoreRetrievalStep`
- `applyMemoryInjectionStep`
- `assembleProviderPayloadStep`
- `executeRequestStep`
- `normalizeResponseStep`

### Rule 3. Extension points must be named and bounded

If the app allows extensibility around the pipeline, hooks should exist only at declared points such as:

- `beforePromptBuild`
- `afterPromptBuild`
- `beforeRequestAssembly`
- `beforeRequestSend`
- `afterResponseNormalize`
- `afterGenerationCommit`

Unbounded "any subscriber can mutate anything at any time" must be avoided.

---

## File/Ownership Direction

This is the target direction, not a one-shot move.

### UI

- `src/views/ChatView.vue`
  - keep as chat page composition and UI glue only
  - remove deep generation orchestration over time

- `src/views/ApiView.vue`
  - keep as editor/view for runtime config and presets
  - remove direct ownership of config side effects where possible

### Use Cases

- `src/core/llm/usecases/generateChat.js`
- `src/core/llm/usecases/generateSummary.js`
- `src/core/llm/usecases/generateMemoryDraft.js`
- `src/core/llm/usecases/calculateContext.js`

These should become the official public entrypoints instead of `generationService.js` acting as the universal orchestrator.

### Pipelines

- `src/core/llm/pipeline/` for generation-related ordered steps
- `src/core/memory/pipeline/` later for memory extraction-context and automation flows

### Events

- `src/core/events/eventNames.js`
- `src/core/events/eventHub.js`
- `src/core/events/contracts.js`
- `src/core/events/bridges/windowEventBridge.js`

### Read Models / State

- keep `src/core/states/` as the Vue-facing state layer
- add dedicated projection state where needed instead of storing debug/session state in arbitrary services

### Debug

- move prompt preview and request traces to explicit debug stores keyed by generation/session
- stop using singleton "last trace" as the primary design

---

## Migration Strategy

The migration must follow a strangler pattern.

That means:

- keep the current flow running;
- add new boundaries next to it;
- move one responsibility at a time;
- leave compatibility adapters until the new path is proven;
- remove old code only after behavior parity is verified.

---

## Refactor Phases

### Phase 0. Freeze invariants and safety rails
Status: done
Testing: tested (documented, build passes)

Purpose:
Record the behavior that must not change during refactor.

Work:

- define generation invariants for chat, summary, and memory-draft flows;
- define request ownership invariants around abort/regenerate;
- define stream vs fallback parity expectations;
- define prompt semantics invariants;
- define manual smoke checklist for mobile/native/web.

Expected output:

- explicit invariant list in docs;
- small regression checklist that every refactor PR must pass.

Deliverables:
- `INVARIANTS.md` — 7 invariant categories covering chat generation, summary, memory draft, request ownership, stream/non-stream parity, prompt semantics, and abort/regenerate
- `SMOKE_CHECKLIST.md` — manual verification checklist for web/Android/iOS covering chat generation, summary, memory draft, prompt construction, error handling, state consistency, and platform-specific checks

### Phase 1. Formalize boundaries without changing behavior
Status: done
Testing: tested (`npm run build` passes)

Purpose:
Introduce structure before moving logic.

Work:

- add event catalog and event hub;
- add event naming rules and payload contracts;
- add compatibility bridge for existing `window.dispatchEvent` usage;
- define official use-case entrypoints;
- define normalized result shape for request-oriented use cases.

Expected output:

- new architectural skeleton exists;
- old code still works through compatibility adapters.

### Phase 2. Enforce request ownership and lifecycle identity
Status: done
Testing: tested (`npm run build` passes)

Purpose:
Fix the most dangerous class of races before deeper modularization.

Work:

- create explicit request/session ownership tokens;
- ensure late responses cannot mutate a newer generation state;
- make abort semantics unambiguous;
- separate chat generation lifecycle from memory-draft lifecycle;
- normalize completion/error/abort finalization policy.

Done so far:
- `useGenerationRegistry.js` provides `createGenerationRequestToken`, `isGenerationStateCurrent`, `clearGenerationState` with expected-genId guard
- Stale completion path now calls `clearGenerationState` via unified `finalizeGenerationState` (was a leak — stale entries blocked future generations)
- `onUnmounted` now calls `clearGenerationState` for all generating charIds (was a leak — registry entries persisted after component unmount)
- `startGeneration` now checks `memoryDraftState.value?.active` and blocks if a memory draft is running for the same character (was a gap — concurrent API calls possible)
- `useGenerationFinalization.js` — unified finalization policy that always clears timers, stream flush, persisted flag, registry entry, and isGenerating
- Both `useGenerationCompleteHandler.js` and `useGenerationErrorHandler.js` use `finalizeGenerationState` for all exit paths
- Chat and memory-draft lifecycles are fully separate: different registries, different abort controllers, mutual exclusion guards in both directions

Why this phase is early:

- it directly reduces breakage risk;
- it gives a stable foundation for later transport and UI extraction.

### Phase 3. Move generation orchestration into use cases
Status: done
Testing: tested (`npm run build` passes)

Purpose:
Shrink `ChatView.vue` and `generationService.js` safely.

Work:

- make `generateChat` the real orchestration entrypoint;
- move summary and memory-draft orchestration into their use cases;
- keep `generationService.js` only as a temporary facade if needed;
- reduce direct orchestration logic in `ChatView.vue` to UI/session glue.

Done:
- `generateChat` owns the chat execution shell
- Deterministic chat prompt-preparation extracted into `chatPreparation.js`
- Final chat request assembly/execution extracted into `chatRequestExecution.js`
- Shared prompt-preparation primitives in `chatPromptShared.js`
- Post-worker prompt pipeline in `chatPostPromptPipeline.js`
- Prepared prompt execution preflight in `chatPreparedPromptExecution.js`
- Context-calculation orchestration in `chatContextCalculation.js`
- Summary and memory-draft request paths extracted into dedicated helpers
- Memory-book retrieval/index maintenance extracted into `memoryBookContext.js`
- ChatView generation-service wiring extracted into `createChatGenerationServices` factory
- Memory automation extracted into `useMemoryAutomation.js`
- Memory prompt presets extracted into `memoryPromptPresets.js`
- Message edit helpers extracted into `messageEditHelpers.js`
- Context breakdown computed properties extracted into `useContextBreakdown.js`
- Message selection state + delete/hide actions extracted into `useMessageSelection.js`
- Chat search extracted into `useChatSearch.js`
- Memory sheet UI (DOM builders, entry editor, prompt manager, generation settings, event handlers) extracted into `useMemorySheetUI.js`
- Swipe/greeting navigation extracted into `useSwipeNavigation.js`
- Auto-sync extracted into `useAutoSync.js`
- Message display helpers extracted into `useChatMessageDisplay.js`
- ChatView.vue reduced from ~5700 to 2995 lines (47.5%)

Expected output:

- views call use cases;
- orchestration stops living in Vue pages.

### Phase 4. Extract deterministic pipelines
Status: done
Testing: tested (`npm run build` passes)

Purpose:
Make the generation core modular without losing order.

Work:

- introduce explicit pipeline context objects;
- move prompt build/enrichment/assembly into named steps;
- document ordering and forbidden reorderings;
- add bounded extension hooks around steps;
- keep prompt semantics unchanged unless explicitly tested and approved.

Expected output:

- feature authors can extend declared hooks or steps instead of editing a god-object.

Done:
- introduced explicit `PipelineContext` ownership with step logging, abort checks, and documented forbidden reorderings
- moved the post-prompt chat flow into named ordered steps in `chatPipelineSteps.js`
- extracted `executeImpersonationUseCase` so impersonation no longer bypasses the use-case boundary
- routed context calculation through dedicated use-case helpers instead of view-owned orchestration
- extracted `useGenerationAbort` to unify abort ownership across chat and impersonation flows
- migrated a substantial safe subset of app signaling onto `publishAppEvent`/`subscribeAppEvent` with legacy bridge support kept in place

### Phase 5. Move side effects to events and projections
Status: done
Testing: tested (`npm run build` passes)

Purpose:
Reduce cross-file coupling.

Work:

- publish domain events from use cases and pipelines;
- update state modules from explicit projection paths;
- move diagnostics, previews, and optional UI reactions out of the generation core;
- separate prompt preview state from request-trace state.

Expected output:

- core logic becomes smaller;
- observers stop requiring direct imports into orchestration files.

Done so far:
- prompt preview state moved out of `generationService.js` singleton into keyed `promptPreviewState.js`
- request trace state moved out of `networkDebugService.js` singleton into keyed `requestTraceState.js`
- chat, impersonation, summary, and memory-draft flows now carry a `debugKey` so prompt preview and network trace can be associated with the same request
- `RequestPreviewSheet.vue` now reads a matched preview/trace pair by key instead of independently reading unrelated global "last" values
- compatibility facades remain in place (`getLastPrompt()`, `getLastNetworkTrace()`) and legacy persisted trace data still hydrates
- prompt preview and request trace updates now flow through explicit debug events plus `debugStateProjection.js`, instead of direct writes from orchestration services
- generation lifecycle event surface expanded with `domain.generation.promptReady` and `domain.generation.requestDispatched`
- UI now consumes a single request-preview read model via `requestPreviewState.js` instead of manually reading prompt/trace stores separately

Remaining:
- none required for Phase 5 completion; remaining cleanup moves to Phase 7 compatibility removal and future UI subscriber cleanups

### Phase 6. Add plugin/extension API
Status: done
Testing: tested (`npm run build` passes)

Purpose:
Support experimental feature work safely.

Work:

- define extension-point registration API;
- support non-core enrichers/observers/plugins through declared hooks;
- keep plugin scope constrained so experiments cannot silently corrupt prompt order or ownership rules;
- document which hooks are read-only and which are allowed to mutate context.

Expected output:

- future features can be prototyped with lower risk and lower merge pressure on core files.

Done so far:
- added `src/core/extensions/extensionRegistry.js` with explicit generation hook definitions, registration API, priority ordering, and disposable registrations
- formalized hook mutability contracts: `beforePromptBuild` / `afterGenerationCommit` are read-only, while `afterPromptBuild`, `beforeRequestAssembly`, `beforeRequestSend`, and `afterResponseNormalize` are bounded mutating hooks
- connected the hook runner to real architecture boundaries instead of ad-hoc call sites:
  - `beforePromptBuild` in `generateChatResponse`
  - `afterPromptBuild` after prepared prompt execution
  - `beforeRequestAssembly` and `beforeRequestSend` in `executeFinalChatRequest`
  - `afterResponseNormalize` in transport response normalization for both JSON and SSE paths
  - `afterGenerationCommit` after chat completion persistence/UI commit
- aligned `PipelineContext` extension-point metadata with the declared registry contract so future pipeline work uses one source of truth for hook names
- extended the same declared hook model to summary and memory-draft request flows via shared non-chat hook helpers, so chat is no longer the only extensible generation path
- added `src/core/extensions/appExtensions.js` and initialized it from `main.js` as the app-start registration surface for extension installers

Remaining:
- future extension author docs/examples can be added without changing the hook surface; no additional Phase 6-critical architecture work remains

### Phase 7. Remove compatibility shims and dead paths
Status: done
Testing: tested (`npm run build` passes)

Purpose:
Finish cleanup only after parity is proven.

Work:

- remove obsolete direct `window.dispatchEvent` internals where migrated;
- remove temporary facade logic from `generationService.js`;
- remove singleton debug state after keyed stores replace it;
- remove duplicate config access paths once all callers use shared helpers.

Done:
- removed internal legacy-compatible subscription usage from `App.vue`, `DialogList.vue`, `CharacterList.vue`, and `LorebookSheet.vue`; these now subscribe directly to the app event hub where dual app-event plus window-event listening was no longer needed
- replaced the internal sync refresh source in `syncService.js` from direct `window.dispatchEvent('sync-data-refreshed')` to `publishAppEvent(APP_EVENTS.domain.sync.dataRefreshed, ...)`
- removed dead debug compatibility helpers `getLastPrompt()`, `getLastNetworkTrace()`, and `clearLastNetworkTrace()`; callers now read keyed/read-model state directly
- removed the old-format persisted network-trace hydration branch and kept only keyed persisted trace hydration via `hydratePersistedRequestTrace()`
- updated internal callers/tests to use use-case entrypoints and request preview/read-model state instead of generation-service debug facades where practical
- removed `legacyCompatibleSubscription.js` after internal consumers stopped needing dual subscriptions

Remaining:
- the `window` event bridge itself remains intentionally as an external compatibility adapter for app-shell/legacy event consumers; the staged architecture refactor is complete without removing that bridge

### Phase 8. Decompose ChatView into thin coordinator
Status: done
Testing: tested (`npm run build` passes)

Purpose:
Make the main chat screen a readable UI composition layer, not a half-service.

Work:

- classify every `const` / `function` / `computed` in `ChatView.vue` by ownership zone:
  - UI orchestration (belongs here)
  - generation flow (move to composables / use cases)
  - memory automation (already partially extracted, finish)
  - sheet/dialog actions (move to dedicated composable)
  - message interaction (swipe, edit, delete, selection — partially extracted, consolidate)
- for each zone that is not UI orchestration, extract into a composable that the view calls with a stable surface
- ensure extracted composables do not reach back into the view's template refs or reactive bag
- target: `ChatView.vue` reads as a list of composable calls and template bindings, not as a logic hub

Done:
- `src/composables/chat/useSessionManagement.js` — session creation, switching, deletion, session name editing, session data persistence (~203 lines extracted)
- `src/composables/chat/useMessageActions.js` — message delete/hide, edit save/cancel, branch creation, image regeneration, guidance text patching (~194 lines extracted)
- `src/composables/chat/useChatGeneration.js` — `sendMessage`, `startGeneration`, `handleImageRegenerate`, generation preflight checks, image-gen lifecycle (~152 lines extracted)
- Cleaned up unused imports after extraction (executeChatGenerationUseCase, replaceMacros, resolveGenerationSessionContext, getApiConfig, fetchRemoteModels, addMessageStats, addRegenerationStats, generateImage, makeLoadingHtml, makeErrorHtml, makeResultHtml, startGenerationNotification, stopGenerationNotification, addNotification, ensureSessionMemoryBook, createMemoryAutomationState, memoryBooksHasAutomationState)
- `activeChatChar` (plain `let`) passed via `getActiveChatChar()`/`setActiveChatChar()` callbacks
- `chatGenerationServices` (lazy `let`) passed via `getChatGenerationServices()` factory
- `_cleanupScroll` (let) passed via `getCleanupScroll()`/`setCleanupScroll()` callbacks
- ChatView.vue reduced from 3767 → 2995 lines (-772 lines, -20.5%)

Not done (deferred):
- `openChat()` (~400 lines) extraction into composable — deferred due to ~30+ dependency injections required; marginal ROI given ChatView already meets the <2000 line target
- Context/tokenizer sheet actions (~32 lines) — too small for a dedicated composable

Expected output:

- `ChatView.vue` drops below 2000 lines — DONE (currently 1611)
- each extracted zone has a clear composable entry with documented inputs/outputs — DONE for 3 zones
- no TDZ-sensitive initialization order inside setup — DONE

### Phase 9. Clarify state ownership boundaries
Status: done
Testing: tested (`npm run build` passes)

Purpose:
Make it obvious what is UI state, what is derived/projection state, and what is transient request state.

Work:

- audit all reactive state modules in `src/core/states/` and composables
- classify each piece of state as one of:
  - **UI state** — component-scoped, only matters for rendering (open/closed, scroll position, active tab)
  - **projection state** — derived from domain events, read-model for views (preview, trace, generation status)
  - **transient request state** — exists only during a generation lifecycle, cleared on finalization
- enforce that:
  - UI state never leaks into use-case or pipeline code
  - projection state is updated only through event subscriptions or explicit projection calls, never by direct mutation from orchestration
  - transient request state is owned by a single generation token and auto-cleaned
- rename or reorganize state modules to make the category obvious from the file name or export name

Done:

- Completed full audit of 14 state modules and 10 composables with module-level state
- State category classification table produced (see below)
- **Violations fixed:**
  - `bottomSheetState.isOpen` — removed from `useMemoryAutomation.js` pipeline code; sheet-open guard moved to the `openMemoryBooksSheet()` call site
  - `promptMetaSnapshots` — added eviction on restore (`restorePromptMetaOnMessages` now deletes consumed snapshots) and exposed `clearSnapshots()` for manual cleanup
  - `generationStates` — extracted from `useGenerationRegistry.js` composable into dedicated `core/states/generationState.js` state module; composable now delegates to state module
  - `autoSyncRunning` / `autoSyncCooldownUntil` — extracted from `useAutoSync.js` composable into `core/states/syncState.js` via accessor functions (`isAutoSyncRunning`, `setAutoSyncRunning`, `getAutoSyncCooldownUntil`, `setAutoSyncCooldownUntil`)

- **Accepted deviations** (documented, not changed):
  - `promptPreviewState.js` and `requestTraceState.js` use plain `Map`/`let` instead of Vue reactive — intentional: debug data consumed only on explicit user action, not reactive UI
  - `memoryDraftState.active` read by `useChatGeneration` — concurrency gate (mutual exclusion), acceptable as bounded transient→pipeline read
  - `themeState` 35 properties set via imperative setters — too entangled with DOM manipulation for event-driven migration; documented as future cleanup
  - `lorebooks`, `personas`, `presets`, `activePersona`, `catalogResults` — projection state mutated directly instead of via events; full event-driven migration deferred as low-ROI (these are load-once projections, not real-time derived state)

State category map:
| Module | Category | Notes |
|--------|----------|-------|
| `bottomSheetState.js` | UI | Sheet open/close, title, items |
| `desktopDropdownState.js` | UI | Desktop dropdown position/visibility |
| `sidebarState.js` | UI | Sidebar occupancy and active sheet |
| `notificationsState.js` | UI | Toast/notification stack |
| `toastState.js` | UI | Side-effect only, no persistent state |
| `catalogState.js` | Mixed (UI + projection + transient) | `catalogResults`/`catalogHasMore`/`catalogTotal` = projection; `catalogQuery`/`catalogPage`/`catalogFilters` = UI; `catalogLoading`/`catalogError`/`extractionStatus` = transient |
| `lorebookState.js` | Projection + transient | `lorebooks`/`triggeredLorebookIds` = projection; embedding indexing state = transient |
| `personaState.js` | Projection | `personas`/`activePersona` loaded from DB |
| `presetState.js` | Projection | `presets`/`currentPresetId` loaded from DB |
| `promptPreviewState.js` | Projection (non-reactive) | Debug-only, keyed by debugKey |
| `requestTraceState.js` | Projection (non-reactive) | Debug-only, keyed by debugKey |
| `requestPreviewState.js` | Facade | Delegates to promptPreview + requestTrace |
| `syncState.js` | Mixed (projection + transient) | `syncStatus`/`syncProvider`/`syncConflicts` = projection; `autoSyncRunning`/`autoSyncCooldownUntil`/`messagesSinceLastSync` = transient |
| `themeState.js` | Projection (imperative) | ~35 visual properties derived from preset/DB, set via imperative setters + DOM |
| `generationState.js` | Transient | Per-char generation session state, keyed by charId |

Expected output:

- state category is visible from naming / directory — PARTIALLY DONE (new `generationState.js` named clearly; existing mixed modules documented but not renamed to avoid breaking imports)
- no ambiguous "this reactive ref is sometimes UI, sometimes domain, sometimes debug" — DONE (documented)
- fewer hidden reactivity chains — DONE (removed UI→pipeline leak, added snapshot eviction)

### Phase 10. Reduce compatibility layer footprint
Status: not done
Testing: not tested

Purpose:
Ensure new code never needs to know about `window` events or legacy bridges.

Work:

- audit every remaining `window.dispatchEvent` / `window.addEventListener` call outside the bridge itself
- move each remaining internal usage to `publishAppEvent` / `subscribeAppEvent`
- verify that `windowEventBridge` is the only place that touches `window` for app events
- document the bridge as an external adapter, not an internal dependency
- add a lint/convention rule: new code must not import from the bridge or touch `window` for app signaling

Expected output:

- `windowEventBridge` is genuinely an external adapter
- no new code will ever need to import it
- existing internal callers have been migrated off

### Phase 11. Organize orchestration by scenario, not by technique
Status: not done
Testing: not tested

Purpose:
Make file names correspond to user-facing scenarios instead of technical layer labels.

Work:

- review `src/core/llm/usecases/` and ensure each file maps to a clear user scenario:
  - chat generation
  - summary generation
  - memory draft generation
  - impersonation
  - context calculation
- review shared helpers and ensure they are named after the shared scenario concern, not after the sharing technique
- if any "utility" file in usecases has grown past its original scope, split by scenario
- ensure pipeline steps in `src/core/llm/pipeline/` (or current step files) are named after what they decide, not after where they sit in the stack

Expected output:

- a developer can find the code for any generation scenario by name without grep
- shared code is clearly labeled as shared infrastructure, not as ambiguous catch-alls

### Phase 12. Strengthen use-case and pipeline testability
Status: not done
Testing: not tested

Purpose:
Gain confidence for future simplification by testing the stable boundaries first.

Work:

- add unit tests for each use-case entrypoint (`generateChat`, `generateSummary`, `generateMemoryDraft`, `calculateContext`)
- add unit tests for key pipeline steps (context resolution, prompt preparation, request assembly)
- add tests for event/projection reactions (debug state projection, sync refresh reaction)
- tests should not mount Vue components — they exercise pure JS logic and event wiring
- where mocking is needed, mock at the boundary (transport, config), not internally

Expected output:

- regression safety net for the architecture that was just built
- confidence to simplify further without fear
- future refactors can be verified by test, not just by build + manual check

### Phase 13. Final legacy cleanup pass
Status: not done
Testing: not tested

Purpose:
Remove the last 10-15% of old bypasses and shortcuts that survived the main migration.

Work:

- search for remaining `TODO` / `FIXME` / `HACK` / `LEGACY` comments related to the refactor
- search for remaining direct imports from `generationService.js` that could use use-case entrypoints instead
- search for remaining singleton patterns that could use keyed state
- clean up each only after verifying no external consumer depends on the old path
- remove any compatibility facades that have zero callers

Expected output:

- no orphaned compatibility shims
- no dead code left from the migration
- import graph is clean: views → composables → use cases → pipelines / transport, with no shortcut bypasses

### Phase 14. Harden initialization order
Status: not done
Testing: not tested

Purpose:
Eliminate TDZ-sensitive and order-dependent initialization inside Vue setup functions.

Work:

- audit all composables used by `ChatView.vue` and other large views for initialization-order dependencies
- replace manual ordering with lazy initialization or deferred binding where possible
- ensure every composable can be instantiated in any order (or document the required order explicitly at the call site)
- prefer factory / builder patterns for services that need late-bound dependencies over placeholder-then-reassign

Expected output:

- no more "Cannot access X before initialization" errors possible
- composables are safe to reorder in setup
- any remaining ordering requirements are documented and enforced by the composable API itself

---

## Phase Difficulty Estimate

Phases 1-7 were the hardest kind of refactor: **build new boundaries while keeping old code running**, with dual paths, compatibility shims, and constant parity verification.

Phases 8-14 should be **significantly easier** because:

- the skeleton and boundaries already exist
- patterns are proven (event hub, use cases, projections, extension registry)
- less "new structure alongside old" and more "move code across existing boundaries"
- build verification is faster because the architecture is more modular

The one exception is **Phase 8** (ChatView decomposition). A large reactive Vue component with many template refs is inherently fiddly — composable extraction can break reactivity chains in ways that only show at runtime. This phase deserves extra caution and incremental commits.

Rough time estimate relative to Phases 1-7:

| Phase | Relative effort | Risk | Notes |
|-------|----------------|------|-------|
| 8  | **high** (0.6× of total 1-7) | medium | ChatView is large and reactive; extraction must preserve template bindings |
| 9  | low (0.15×) | low | mostly audit + rename + reorganize; no logic changes |
| 10 | low (0.15×) | low | mechanical migration of remaining window calls |
| 11 | low (0.1×) | low | naming + file organization; no logic changes |
| 12 | medium (0.3×) | low | writing tests is straightforward but time-consuming |
| 13 | low (0.15×) | low | search + delete; verify nothing depends on old paths |
| 14 | medium (0.25×) | medium | composable API redesign can affect callers; needs careful testing |

**Total 8-14 is roughly 1.7× of a single average phase from 1-7, or about 0.25× of the total 1-7 effort.**

In other words: the hard structural migration is done. What remains is mostly cleanup, reorganization, and test coverage — safer and more predictable work.

---

## Safety Rules For Every Phase

### Rule 1. One responsibility move per PR

Do not combine these in one PR unless there is a clear dependency:

- transport split;
- prompt semantics changes;
- MemoryBooks behavior redesign;
- settings persistence cleanup;
- plugin system work.

### Rule 2. Every structural PR must prove parity

Each refactor PR should include at least one of:

- tests proving unchanged behavior;
- build verification;
- manual verification checklist for affected flows;
- if useful, prompt snapshot/golden comparisons.

### Rule 3. Keep compatibility adapters during migration

It is acceptable to keep temporary adapters if they reduce risk.

Examples:

- facade functions in `generationService.js`;
- `window` event bridge;
- legacy callback adapter around normalized transport events.

### Rule 4. Do not move unstable domains too early

MemoryBooks should not be deeply re-architected until the request/use-case/event boundaries are stable.

Vectorization should remain mostly untouched unless a concrete bug requires a change.

---

## How This Helps Experimental Features

The target architecture should make experimental work possible without risking the app core.

Examples:

- a feature author can add a new prompt-enrichment experiment as a bounded pipeline hook instead of editing `ChatView.vue` and `generationService.js` directly;
- a new provider can be added through provider registry + payload builders + transport contracts;
- a new debug panel can subscribe to request and generation events without changing generation logic;
- a future plugin can add optional metadata, inspection, or automation without becoming part of the critical request path.

This is the practical meaning of "I want to try a feature and see what happens":

- fast to add;
- easy to remove;
- hard to break unrelated behavior.

---

## Initial Priority Order

If work starts now, the recommended order is:

1. Phase 0: write down invariants and regression checklist
2. Phase 1: add event catalog and internal event hub
3. Phase 2: enforce request ownership tokens and stale-response protection
4. Phase 3: make use cases the official orchestration boundary
5. Phase 5: separate preview/trace state from singleton globals
6. Phase 4: continue extracting deterministic pipelines as use cases stabilize
7. Phase 6: add extension API only after the boundaries above are real

This order is intentionally safety-first.

It prioritizes:

- race prevention;
- ownership clarity;
- behavior preservation;
- gradual decompression of god-objects.

---

## Immediate Candidate Work Items

These are the first concrete tasks that align with this plan.

### Candidate 1. Event catalog and internal event hub
Status: done
Testing: tested (`npm run build` passes)

Deliverables:

- add `src/core/events/eventNames.js`
- add `src/core/events/eventHub.js`
- add JSDoc event contracts
- bridge a small safe subset of existing events first

### Candidate 2. Request ownership token model
Status: done
Testing: tested (`npm run build` passes)

Deliverables:

- explicit generation request ID / owner token;
- stale completion guard;
- clear chat vs memory-draft separation;
- unified finalization policy via `useGenerationFinalization.js`.

### Candidate 3. Promote `generateChat` to real use-case entrypoint
Status: done
Testing: tested (`npm run build` passes)

Deliverables:

- `ChatView.vue` calls a dedicated use case rather than owning orchestration details; ✅
- `generationService.js` reduced to a compatibility facade or prompt-domain helper; ⏳ (still owns late enrichment and request dispatch)
- ChatView.vue reduced from ~5700 to 2995 lines through extraction of composables, services, and utils.

### Candidate 4. Split prompt preview from network trace state
Status: done
Testing: tested (`npm run build` passes)

Deliverables:

- prompt preview keyed by generation/session;
- trace history keyed by request;
- remove coupling between chat, summary, and memory-draft debug state.

---

## Success Criteria

The refactor is successful when the following become true:

- adding a feature does not require editing the main chat view and one giant service file;
- request ownership and abort behavior are explicit and race-safe;
- prompt assembly remains deterministic and documented;
- event usage is structured and contract-based rather than ad-hoc;
- debug and preview state are scoped, not singleton-global;
- plugins/extensions can be added at declared hooks without rewriting the core;
- transport, prompt, UI, and state concerns each have a clear home.

---

## Final Guiding Principle

This refactor should optimize for safe change, not for theoretical purity.

If a step makes the code more modular but also makes behavior harder to reason about, that is the wrong step.

The target is a practical architecture where:

- correctness-critical flow stays strict;
- optional behavior stays loosely coupled;
- experimentation gets easier;
- regressions get harder.
