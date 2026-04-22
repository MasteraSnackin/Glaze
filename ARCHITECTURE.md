# Architecture Audit — Tokenizer, Vectorization, MemoryBooks, Macros, Cloud Sync

## 0. Refactor Transition State

### Current Refactor Slice
- Branch: `feat/refactor-phase1-event-hub`
- Base: latest `dev` state plus refactor-only commits
- Status: Phase 1 skeleton plus first listener migration slice
- Testing: `npm run build` passed

### Before Refactor

The app was functional, but core ownership was still too concentrated.

- `src/views/ChatView.vue` owned too much chat-generation orchestration, UI coordination, and request lifecycle glue.
- `src/core/services/generationService.js` still mixed prompt construction, enrichment, payload assembly, preview state, and request dispatch.
- Many cross-feature reactions depended on ad-hoc `window.dispatchEvent(...)` usage with no internal catalog or explicit ownership boundary.

This made the app hard to extend safely because new behavior often had to pass through the same large files.

### Target Direction

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

### Phase 1 Event Layer Skeleton

Files added:
- `src/core/events/eventNames.js`
- `src/core/events/contracts.js`
- `src/core/events/eventHub.js`
- `src/core/events/bridges/windowEventBridge.js`

Current behavior:
- Internal canonical event names now exist for a small safe subset of events.
- `main.js` initializes a bridge from internal app events to the existing legacy `window` events.
- Existing legacy listeners still work because the bridge republishes the legacy browser events.
- A few existing emitters now publish canonical app events first:
  - generation started/ended
  - chat updated
  - sync data refreshed
  - API context settings changed
  - open API sheet
- A first listener subset now subscribes through `subscribeLegacyCompatibleEvent(...)` instead of raw `window.addEventListener(...)` for those same canonical events.

Current listener subset migrated:
- `App.vue`
  - open API sheet
  - sync data refreshed
- `ChatView.vue`
  - generation ended
  - API context settings changed
- `DialogList.vue`
  - sync data refreshed
  - chat updated
  - generation started
  - generation ended
- `LorebookSheet.vue`
  - sync data refreshed
- `CharacterList.vue`
  - sync data refreshed

What has **not** changed yet:
- Most listeners still subscribe to `window` events.
- `ChatView.vue` is still a large orchestration surface.
- `generationService.js` is still a large orchestration surface.
- Full request ownership separation is not finished yet.

### Phase 2 Request Ownership Safety Slice

Current behavior:
- Chat-generation state now carries explicit ownership metadata:
  - `ownerKey`
  - `requestToken`
  - `sessionId`
  - `type`
- Stream updates, completion handling, error handling, and abort cleanup now validate that they still belong to the active chat request before mutating state.
- This makes late completions less dangerous when request lifecycle overlaps occur around abort/regenerate/session changes.
- Impersonation keeps a separate ownership scope instead of sharing the normal chat-generation identity.

What this does **not** do yet:
- It does not move orchestration out of `ChatView.vue`.
- It does not yet introduce automated overlap tests for abort/regenerate races.
- It does not yet unify all generation-like flows under one final lifecycle contract.

### Initial Use-Case Entrypoint Layer

Files added:
- `src/core/llm/usecases/generateChat.js`
- `src/core/llm/usecases/calculateContext.js`
- `src/core/llm/usecases/generateSummary.js`
- `src/core/llm/usecases/generateMemoryDraft.js`

Current behavior:
- UI callers now depend on official use-case entrypoints instead of importing generation actions from `generationService.js` directly.
- `generateChat.js` is no longer only a passthrough wrapper: it now owns the chat execution shell after session context is resolved.
- Deterministic chat prompt-preparation now lives in `src/core/llm/usecases/chatPreparation.js` instead of being fully inlined inside `generationService.js`.
- Vue-owned state, UI callbacks, and persistence helpers are still injected from `ChatView.vue`, so behavior remains unchanged while the dependency boundary becomes real.
- `generationService.js` still owns late enrichment and final request execution, and acts as the compatibility layer under that use case.

Why this slice is safe:
- It adds a new internal boundary without removing the legacy one.
- Runtime behavior stays compatible because `window` remains the active compatibility surface.
- Migrated listeners still observe legacy browser events from non-migrated emitters and ignore bridged duplicates from migrated emitters.
- Later refactor slices can migrate listeners and side effects incrementally instead of forcing a one-shot rewrite.

What has **not** changed yet:
- `ChatView.vue` still prepares and injects a large dependency bundle into the chat use case.
- Late enrichment and final request assembly still live inside `generationService.js`.
- The next safe extraction step is to move those remaining deterministic stages under the use-case/pipeline layer without changing ordering.

## 1. Tokenizer

### Files
- `src/utils/tokenizer.js` — Token estimation using GPTTokenizer (cl100k_base compatible)
- `src/tokenizers/gp-tokenizer-9KQssiTx.js` — Bundled tokenizer implementation
- `src/views/ChatView.vue` — UI: `openContextSheet()`, context breakdown display
- `src/workers/generationWorker.js` — Token calculation in `calculateContext()`

### Structure

**Token Estimation (`tokenizer.js`):**
- `estimateTokens(text)` — Uses GPTTokenizer with base64 media stripping
- Stripping prevents embedded images from inflating token counts

**Context Calculation (`generationWorker.js`):**
- `calculateContext()` — Computes token breakdown by source:
  - `character` — Character card content
  - `preset` — Chat prompt/preset
  - `summary` — Summary sections (timeline, characterArcs, etc.)
  - `authorsNote` — Author's note
  - `lorebook` — Keyword lorebook entries
  - `vectorLore` — Vector search lorebook entries
  - `memory` — Memory book entries
  - `history` — Chat history (hidden + visible)

**UI Flow (`ChatView.vue`):**
1. User opens Tokenizer via MagicDrawer
2. `openContextSheet()` renders bottom sheet with context breakdown
3. Visual bar shows proportional segments by color
4. Reserve visualization: lorebooks displayed inside reserve zone

### Key State
- `contextCutoff` — Index marking where context window starts
- `lastContextUpdate` — Timestamp for cache invalidation
- `contextCache` — Cached calculation result

---

## 2. Vectorization

### Files
- `src/utils/vectorMath.js` — Vector math operations
- `src/core/services/embeddingService.js` — Embedding API calls
- `src/core/config/embeddingSettings.js` — Embedding connection config (endpoint, key, model)
- `src/core/states/lorebookState.js` — Vector indexing, search, and search settings
- `src/utils/db.js` — IndexedDB storage for embeddings
- `src/workers/generationWorker.js` — Dual-channel retrieval integration
- `src/core/services/generationService.js` — Vector search execution

### Structure

**Search Type System (`lorebookState.js`):**
- `searchType` — `'keys'` | `'vector'` | `'both'` (was `vectorSearchEnabled` + `keySearchEnabled`)
- `'keys'` — Keyword-only matching (default)
- `'vector'` — Vector-only semantic search
- `'both'` — Combined keyword + vector search
- Single `scanDepth` field with dynamic label based on search type
- Vector-specific settings: `vectorThreshold`, `vectorTopK`, `embeddingTarget`

**Embedding Settings (split across two locations):**
- **API Settings** (`embeddingSettings.js`): endpoint, API key, model, useSame, maxChunkTokens, enabled
- **Lorebook Settings** (`lorebookState.globalSettings`): searchType, scanDepth, vectorThreshold, vectorTopK, embeddingTarget
- No duplication — search params are owned by lorebook, connection params by API

**Vector Math (`vectorMath.js`):**
- `cosineSimilarity(a, b)` — Standard cosine similarity
- `findTopK(queryVector, candidates, k, threshold)` — Single-vector top-K search
- `findTopKMulti(queryChunks, candidates, k, threshold)` — MaxSim algorithm for multi-chunk entries

**Embedding Service (`embeddingService.js`):**
- `getEmbedding(text)` — Single text embedding (returns array of {text, vector} chunks)
- `getEmbeddings(texts[])` — Batch embedding with auto-chunking
- `testEmbeddingConnection()` — Connection test

**Auto-chunking:**
- Texts split at sentence/paragraph boundaries
- Default `maxChunkTokens: 512`
- Each chunk embedded separately

**IndexedDB Storage (`db.js`):**
- Store: `embeddings`
- Schema v8: `{ id, sourceType, sourceId, vectors[], textHash, retrievalHints, updatedAt }`
- Legacy support: single `vector` field

**Lorebook State (`lorebookState.js`):**
- `indexLorebookEntry(entry, lorebookId)` — Single entry indexing with hash check
- `indexLorebookEntries(lorebookId)` — Bulk indexing with progress
- `vectorSearchLorebooks(queryChunks, options)` — Dual-channel search (vector + keyword)
- `reindexMemoryEntry(entry, charId, sessionId)` — Memory entry reindexing
- Uses `embeddingTarget` from `lorebookState.globalSettings` (not from API config)

**Dual-Channel Retrieval:**
1. Worker scans entries with `scanLorebooksPure()` — keyword matching (skipped if `searchType === 'vector'`)
2. Generation service runs `vectorSearchLorebooks()` — semantic search (skipped if `searchType === 'keys'`)
3. Results merged, deduplicated by entry ID
4. Keyword matches prioritized over vector matches

**Retrieval Boosting:**
- `hybridBoost` — Based on `comment`/`keys` overlap with query
- `descriptorBoost` — Based on early `content` + `retrievalHints` overlap

---

## 3. MemoryBooks

### Files
- `src/views/ChatView.vue` — Primary implementation
- `src/core/services/generationService.js` — Memory injection during generation
- `src/core/states/lorebookState.js` — Vector search for memories
- `src/utils/db.js` — Chat persistence with memory books

### Structure

**Data Model:**
```javascript
memoryBooks: {
  [sessionId]: {
    entries: [MemoryEntry],
    pendingDrafts: [DraftEntry],
    settings: MemorySettings,
    automation: AutomationState,
    updatedAt: timestamp
  }
}

MemoryEntry: {
  id: string,
  content: string,
  keys: string[],
  glazeKeys: string[],
  vectorSearch: boolean,
  messageIds: string[],
  messageRange: { start: number, end: number },
  status: 'active' | 'needs_rebuild' | 'stale',
  source: 'manual' | 'auto' | 'import_bootstrap',
  createdAt: timestamp,
  updatedAt: timestamp
}

DraftEntry: {
  id: string,
  title: string,
  messageIds: string[],
  messageRange: { start: number, end: number },
  prompt: string,
  generationStatus: 'pending' | 'generating' | 'completed' | 'failed',
  createdAt: timestamp,
  generatedAt: timestamp | null,
  error: string | null
}

MemorySettings: {
  generationSource: 'current' | 'custom',
  generationEndpoint: string,
  generationModel: string,
  generationApiKey: string,
  generationTemperature: number | null,
  autoCreateInterval: number,
  batchSize: number,
  useDelayedAutomation: boolean,
  maxInjectedEntries: number,
  injectionTarget: 'summary_block' | 'summary_macro',
  vectorSearchEnabled: boolean,
  keyMatchMode: 'plain' | 'glaze' | 'both',
  promptPreset: string,
  customPrompts: CustomPrompt[]
}
```

**Generation Flow:**
1. `generateMemoryDraftForMessages()` — Creates draft from selected messages
2. `runBatchDraftGenerationFromIds()` — Parallel batch generation for pending drafts, capped by `settings.batchSize`
3. `generateMemoryDraft()` — API call with continuity context
4. Draft parsed into MemoryEntry-compatible shape, stores both parsed `content` and full `rawContent`, user approves or regenerates

**Pending Draft Behavior:**
- `Scan Chat` creates pending draft placeholders only; generation is explicit
- `Generate` starts one draft job for a specific `draftId`
- `Generate Remaining` starts up to `settings.batchSize` pending drafts that are not already running
- In-flight draft IDs are tracked separately in UI state so batch generation does not restart the same draft twice
- Each draft has its own timer/abort controller; `Stop` cancels only that draft
- Draft completion re-reads latest chat data before save so concurrent completions do not overwrite each other

**Injection Rules:**
- `buildMemoryInjection()` now uses `cutoffOriginalIndex` from worker output
- Memory entries are injected only if all linked `messageIds` are already outside the active prompt context
- This avoids injecting memories for message ranges that are still present in the current prompt window

**Message Badges (ChatMessage.vue):**
- `MEM` — Message covered by approved memory entry
- `DRAFT` — Message covered by pending draft
- `PENDING` — Message awaiting auto-generation trigger
- `STALE` — Memory entry needs rebuild

---

## 4. Macro Engine

### Files
- `src/utils/macroEngine.js` — Macro replacement engine

### Supported Macros

**Character/User:**
- `{{char}}` — Character name
- `{{description}}` — Character description
- `{{scenario}}` — Character scenario
- `{{personality}}` — Character personality
- `{{mesExamples}}` — Message examples
- `{{user}}` — User name
- `{{persona}}` — User persona prompt

**Variables (SillyTavern-compatible):**
- `{{setvar::name::value}}` — Set session variable (per char+session, stored in localStorage `gz_vars_{charId}_{sessionId}`)
- `{{getvar::name}}` — Get session variable
- `{{setglobalvar::name::value}}` — Set global variable (cross-session, stored in localStorage `gz_global_vars`)
- `{{getglobalvar::name}}` — Get global variable

**Lucid Loom / LumiverseHelper macros:**
- `{{lumiaDef}}`, `{{lumiaOOC}}`, `{{lumiaOOCErotic}}`, `{{lumiaOOCEroticBleed}}`, `{{lumiaPersonality}}`
- `{{loomRetrofits}}`, `{{loomStyle}}`, `{{loomSummary}}`, `{{loomUtils}}`
- `{{sim_tracker}}`, `{{suggest}}`
- These read from global variables set via `setglobalvar`. Return original macro if not found.

**Utility:**
- `{{random::a::b::c}}` — Random choice
- `{{pick::a::b::c}}` — Deterministic pick (hash-based, stable per session)
- `{{roll::1d20}}` — Dice roll (e.g. `2d6`)
- `{{trim}}` — Trim whitespace
- `{{date}}` — Current date
- `{{time}}` — Current time
- `{{weekday}}` — Day of week

**Reasoning:**
- `{{reasoningPrefix}}` — Reasoning start tag (from preset or localStorage `gz_api_reasoning_start`)
- `{{reasoningSuffix}}` — Reasoning end tag (from preset or localStorage `gz_api_reasoning_end`)

**Comments:**
- `{{// comment}}` — Single-line comment (removed)
- `{{ // }}...{{ /// }}` — Multi-line scoped comment (removed)

**Escaping:**
- `\{\{` → `{{` and `\}\}` → `}}`

---

## 5. Reasoning System

### Files
- `src/core/services/llmApi.js` — Reasoning extraction from API response
- `src/core/services/generationService.js` — Reasoning settings resolution
- `src/views/ApiView.vue` — User-facing reasoning toggle
- `src/views/PresetView.vue` — Preset reasoning settings

### Logic

**Settings Resolution:**
1. User enables "Show Native Reasoning" in API settings → `requestReasoning = true`
2. Preset can override ONLY to enable (`reasoningEnabled: true`)
3. Preset `reasoningEnabled: false` does NOT disable user's choice
4. `reasoningEffort` — `'auto'` | `'low'` | `'medium'` | `'high'` (auto = not sent to API)

**Extraction (llmApi.js):**
1. `reasoning_content` field from API response → `finalReasoning`
2. Inline tags (`reasoningStart`...`reasoningEnd`) in content → `inlineReasoning`
3. Both combined and displayed to user
4. `hasInlineTags = !!tagStart && !!tagEnd` — requires non-empty tag config
5. Native/mobile fallback: if `response.body.getReader()` is unavailable, stream requests fall back to one-shot response parsing instead of failing

---

## 6. Network / LLM Requests

### Files
- `src/components/chat/ChatInput.vue` — Starts user send flow and exposes request preview sheet entry points
- `src/components/chat/MagicDrawer.vue` — Secondary request preview entry point
- `src/components/sheets/RequestPreviewSheet.vue` — Displays the last built prompt and optional captured network trace
- `src/views/ChatView.vue` — Chat session orchestration, open/load paths, and integration of extracted generation composables
- `src/views/ApiView.vue` — API settings UI, model discovery, preset CRUD, and connection test UX
- `src/core/config/APISettings.js` — Runtime API config reads, endpoint normalization, provider blacklist checks, and `/models` discovery
- `src/core/services/generationService.js` — Prompt orchestration, late enrichment, request assembly, and direct `executeRequest()` callers
- `src/workers/generationWorker.js` — Prompt assembly, macro/regex application, keyword lore scan, and token accounting
- `src/core/services/llmApi.js` — Thin request entrypoint that wires transport modules together
- `src/core/llm/transport/chatCompletionsClient.js` — Fetch-based `/chat/completions` execution
- `src/core/llm/transport/requestLifecycle.js` — Timeouts, abort guards, request headers, trace start
- `src/core/llm/transport/requestExecution.js` — Native non-stream vs fetch execution split
- `src/core/llm/transport/streamingSse.js` — SSE stream consumption and delta dispatch
- `src/core/llm/transport/responseHandling.js` — One-shot/native response shaping
- `src/core/llm/transport/requestOutcome.js` — Abort/timeout/failure completion policy
- `src/core/llm/transport/requestRuntimePolicy.js` — Wake lock / foreground-runtime behavior
- `src/core/llm/transport/streamAccumulator.js` — Shared text/reasoning accumulation across transport paths
- `src/core/services/networkDebugService.js` — Stores the last captured request/response trace for on-device inspection with debounced persistence
- `src/composables/chat/useGenerationPreparation.js` — Placeholder/session context preparation
- `src/composables/chat/useGenerationStateSetup.js` — Generation state registration and stream UI setup
- `src/composables/chat/useGenerationStreamUpdate.js` — Background persistence throttling for streaming updates
- `src/composables/chat/useGenerationPromptReady.js` — Prompt metadata assignment on ready
- `src/composables/chat/useGenerationCompleteHandler.js` — Completion/finalization path
- `src/composables/chat/useGenerationErrorHandler.js` — Error path and user-visible failure handling
- `src/composables/chat/useGenerationStateRestore.js` — Abort/rollback restore path
- `src/composables/chat/usePromptMetadataSnapshots.js` — Prompt metadata rollback snapshots
- `src/composables/chat/useTypingStateCleanup.js` — Stale typing cleanup helpers

### Request Types
- `chat` — Main character response generation from `ChatView.vue` via `generateChatResponse()`
- `summary` — Preset/summary generation via `generateSummary()`
- `memory_draft` — MemoryBook draft generation via `generateMemoryDraft()`
- `model_discovery` — `/models` fetch from `ApiView.vue` via `fetchRemoteModels()`

### Current End-to-End Flow

**Chat Generation:**
1. `ChatInput.vue` emits send-related events and `ChatView.vue` receives them.
2. `ChatView.vue:startGeneration()` performs top-level UI/session orchestration:
   - checks basic API config availability
   - creates `AbortController`
   - creates or reuses the typing placeholder message
   - resolves session context and authors note
   - delegates placeholder/setup/restore/error/complete work to extracted chat composables
3. `generationService.js:generateChatResponse()` resolves the effective request inputs:
   - loads API config from `APISettings.js`
   - resolves active preset and reasoning tag settings
   - collects session vars, persona, regexes, and prompt options
   - sends prompt building to `generationWorker.js`
4. After the worker returns, `generationService.js` performs late enrichment:
   - vector lore retrieval
   - memory injection
   - late vector-lore budget limiting via `maxInjectedEntries`
   - context breakdown assembly
   - request-body creation and sanitization
   - `lastPrompt` snapshot for request preview UI
5. `generationService.js` calls `llmApi.js:executeRequest()` with transport config, reasoning config, request type, abort controller, and callbacks.
6. `llmApi.js` builds a transport stack from `requestLifecycle`, `requestExecution`, `chatCompletionsClient`, `streamingSse`, `responseHandling`, and `requestOutcome`.
7. The transport executes `/chat/completions` using either:
   - `CapacitorHttp.post()` for native non-stream local HTTP requests
   - `fetch()` for web and streaming requests
8. The transport parses either:
   - one-shot JSON response
   - SSE stream via `response.body.getReader()`
   - one-shot fallback when a stream request has no readable body on the current runtime
9. Shared normalizers extract assistant text plus reasoning from:
   - native `reasoning_content`
   - inline reasoning tags in `content`
10. Callback flow returns to `ChatView.vue` composables:
   - `onUpdate()` applies streaming text/reasoning to the placeholder message
   - `onComplete()` finalizes the message, stores metadata, and clears generation state
   - `onError()` restores UI/DB state and writes formatted error output

**Summary + Memory Draft Requests:**
1. `PresetView.vue` or `ChatView.vue` call `generateSummary()` / `generateMemoryDraft()`.
2. `generationService.js` builds a simpler single-message request body.
3. Both still reuse `llmApi.js:executeRequest()`.
4. Request preview and network trace are still global, so these requests can overwrite the last visible chat debug payload.

**Model Discovery:**
1. `ApiView.vue` normalizes the endpoint and calls `fetchRemoteModels()`.
2. `APISettings.js` requests `/models` using `fetch()` on web or `CapacitorHttp.get()` on native.
3. Returned model IDs feed the API settings selector UI.

### Current Responsibility Split

**UI / Session Lifecycle:**
- `ChatView.vue` still owns chat-level orchestration, but detailed generation lifecycle logic is split across focused chat composables.
- `useGenerationPreparation.js`, `useGenerationStateSetup.js`, `useGenerationStreamUpdate.js`, `useGenerationPromptReady.js`, `useGenerationCompleteHandler.js`, `useGenerationErrorHandler.js`, and `useGenerationStateRestore.js` now own the detailed generation subpaths.
- `RequestPreviewSheet.vue` owns display of the last built prompt and the last stored network trace.
- `ApiView.vue` owns API settings editing, preset CRUD, and `/models` connectivity UX.

**Prompt Pipeline:**
- `generationWorker.js` builds prompt blocks, applies macros and regexes, scans keyword lore, and returns prompt/context metadata.
- `generationService.js` enriches worker output with vector lore and MemoryBook injection, computes final request payloads, and exposes generation entry points.

**Transport / Runtime:**
- `llmApi.js` is now the compatibility entrypoint, not the full transport implementation.
- `requestLifecycle.js`, `requestExecution.js`, `chatCompletionsClient.js`, `streamingSse.js`, `responseHandling.js`, and `requestOutcome.js` own the concrete transport flow.
- `requestRuntimePolicy.js` owns wake-lock / foreground-runtime behavior.
- `networkDebugService.js` owns the persisted "last trace" singleton.

**Config / Storage:**
- `APISettings.js` reads runtime API values from `localStorage` and API presets from IndexedDB.
- `ApiView.vue` writes many of those values directly back to `localStorage`, and also mutates the active API preset record.
- `ChatView.vue` still performs some direct localStorage reads for preflight config checks.

### Transport Behavior Today
- Request endpoint is always `${apiUrl}/chat/completions` for generation and `${apiUrl}/models` for model discovery.
- `CONNECT_TIMEOUT` and `STREAM_TIMEOUT` are read from `localStorage` through `requestLifecycle.js`.
- Streaming requests use SSE parsing with `data: ...` lines and `[DONE]` termination.
- If a streaming response body is unavailable on the current runtime, the transport falls back to one-shot JSON parsing instead of hard-failing.
- Abort handling is dual-purpose:
  - user abort may still preserve partial text
  - timeout-triggered abort is treated as an error and may preserve partial text with `partialError`
- The transport contract is callback-based rather than event-object-based:
  - `onUpdate(chunk, reasoningChunk, effectiveText, effectiveReasoning, textDelta)`
  - `onComplete(text, reasoning, meta?)`
  - `onError(error)`

### Temporary Network Trace Debugging

**Files:**
- `src/core/services/networkDebugService.js` — Stores the last captured request/response trace in localStorage
- `src/core/services/llmApi.js` — Starts/updates/completes capture during chat + memory draft requests
- `src/core/services/generationService.js` — Tags captures by request type and exposes the last request body for preview
- `src/components/sheets/RequestPreviewSheet.vue` — On-device viewer/toggle for the last captured trace

**Purpose:**
- Debug mobile/provider-specific failures without a dev console
- Confirm whether providers return native `reasoning_content`, inline reasoning tags, or neither
- Inspect exact memory draft request payloads and raw responses when summaries appear truncated

**Stored Trace Shape:**
- Request metadata: `requestType`, `apiUrl`, `stream`, timestamps, duration
- Request payload: masked request headers + JSON body
- Response metadata: HTTP status + response headers
- Parsed output: final `text`, `reasoning`, and `error`
- Stream-only diagnostics: bounded buffer of raw SSE `data:` lines

**Operational Notes:**
- Capture is gated by localStorage toggle `gz_debug_network_capture`
- Last trace persists in localStorage key `gz_last_network_trace`
- Trace persistence is debounced so streaming diagnostics do not write `localStorage` on every SSE chunk
- Request preview stays usable even when trace capture is disabled; the trace section is optional diagnostics only

### Current Mobile Power / Renderer Guardrails

These are compatibility-first runtime optimizations added after the network refactor to reduce battery/renderer churn when the shared battery-saver UI mode is enabled.

- Battery-saver UI mode is controlled only by the shared `Battery Saver UI` toggle. `Force Mobile Layout` changes layout only and does not imply lighter renderer behavior.
- Generation UI updates are batched instead of repainting every single stream delta immediately.
- `genTime` display updates once per second during generation instead of every 100ms.
- Battery-saver chat messages use a static typing suffix, plain `genTime` text, and a no-op transition path for swipe/token micro-animations instead of the more animated desktop-oriented presentation. This keeps Vue's transition lifecycle intact while removing the renderer cost of those animations.
- `smartScroll()` during active generation is throttled instead of firing on every stream update.
- Background persistence for in-flight stream text is slower on native and moderately slower in desktop battery-saver mode (`useGenerationStreamUpdate.js`) to reduce IndexedDB churn.
- `requestRuntimePolicy.js` delays foreground/background runtime activation for short requests and enables it immediately when the app is backgrounded mid-generation.
- Native auto-sync is skipped while generation is active or the app is backgrounded, and it now has a cooldown between runs.
- `useVirtualScroll.js` skips its extra per-scroll visibility health check and schedules heavy scroll work through `requestAnimationFrame` while battery-saver UI mode is active.

Battery-saver UI scope:
- The shared toggle enables the lighter UI/rendering guardrails: reduced animation, batched stream painting, slower stream persistence, and lighter virtual-scroll behavior, regardless of whether the user is in desktop or forced-mobile layout.

Native-only scope retained:
- `requestRuntimePolicy.js`, wake-lock/background-mode activation, notification-backed foreground runtime behavior, and generation auto-sync cooldown/background guards remain native-only runtime behavior and are not controlled by the battery-saver UI toggle.

**Current Limitation:**
- Trace storage is global and single-entry. A summary or memory draft request can overwrite the last chat trace.

**Safe Removal Path:**
- Remove `networkDebugService.js`
- Remove its imports/calls from `llmApi.js`
- Remove trace UI/toggle from `RequestPreviewSheet.vue`
- Keep `generationService.js:getLastPrompt()` and prompt preview JSON unless request preview itself is being removed
- Keep trace capture non-blocking; generation success must never depend on diagnostics state

### Current Design Problems
- `ChatView.vue` still owns too much of the chat lifecycle overall, but the detailed generation lifecycle is no longer fully inline.
- `generationService.js` mixes use-case orchestration, prompt enrichment, config resolution, debug preview state, and transport dispatch.
- `llmApi.js` is much thinner now, but transport side effects are still callback-driven and spread across multiple helpers rather than an explicit event contract.
- Runtime config has multiple owners: `localStorage`, IndexedDB API presets, reactive `ApiView.vue` state, onboarding writes, and direct reads in feature views.
- Debug state is global singleton state (`lastPrompt`, `lastNetworkTrace`) rather than per-generation or per-message state.
- Request types are implicit instead of modeled as separate use cases with a shared transport contract.
- Worker/service boundaries are not documented clearly: keyword lore lives in the worker, vector retrieval and memory injection happen later in the service layer.
- Callback signatures are flexible but brittle across chat, summary, and memory-draft flows.

### Better Target Structure

**Current Foundation Added In This Branch:**
- `src/core/llm/contracts/providerContracts.js` introduces provider IDs, request kinds, and baseline capability flags
- `src/core/llm/providers/providerRegistry.js` introduces a registry boundary instead of hard-coding all provider behavior into settings/transport files
- `src/core/llm/providers/openaiCompatibleProvider.js` wraps the current OpenAI-like endpoint normalization, auth header strategy, `/models` discovery, and chat completion URL building as the first adapter

This is intentionally small and compatibility-first: the current request flow still behaves as before, but provider-specific behavior now has an explicit place to live. At this stage, model discovery and chat transport setup already route through the provider boundary, while parsing and response normalization still live in `llmApi.js`.

**Additional Progress Already Landed On The Refactor Branch:**
- `APISettings.js` now owns a shared runtime-config boundary via `getApiRuntimeStorage()`, `saveApiRuntimeSetting()`, `applyApiRuntimeConfig()`, and `getApiReasoningTags()`
- `ApiView.vue`, `OnboardingView.vue`, `ToolsView.vue`, `ChatView.vue`, `generationService.js`, `macroEngine.js`, and `ChatMessage.vue` have started moving off ad-hoc raw runtime config reads/writes toward those helpers
- the refactor branch has also re-applied the merged regression safeguards from the bugfix chain, so late vector lore limits and prompt-metadata rollback still hold while refactor work continues

**Config Layer:**
- `src/core/llm/config/apiConfigStore.js` — read/write active runtime config without raw localStorage access in views
- `src/core/llm/config/apiPresetStore.js` — preset CRUD only
- `src/core/llm/config/endpointUtils.js` — endpoint normalization and blacklist helpers

**Transport Layer:**
- `src/core/llm/transport/chatCompletionsClient.js` — POST `/chat/completions`
- `src/core/llm/transport/modelDiscoveryClient.js` — GET `/models`
- `src/core/llm/transport/sseParser.js` — SSE line parsing only
- `src/core/llm/transport/responseNormalizer.js` — unify streaming and non-stream outputs into one shape
- `src/core/llm/transport/runtimePolicy.js` — wake lock, background mode, and native/web branching rules

**Transport Extraction Landed In This Branch:**
- `src/core/llm/transport/requestLifecycle.js` owns timeout setup, abort guards, request headers, and trace start
- `src/core/llm/transport/requestExecution.js` owns native non-stream vs fetch execution branching
- `src/core/llm/transport/chatCompletionsClient.js` owns fetch-based `/chat/completions` execution
- `src/core/llm/transport/streamingSse.js` owns SSE stream consumption and delta fanout
- `src/core/llm/transport/responseHandling.js` owns one-shot/native completion shaping
- `src/core/llm/transport/requestOutcome.js` owns abort/timeout/failure completion policy
- `src/core/llm/transport/responseNormalizer.js` owns shared final-response extraction for OpenAI-like one-shot/native/fallback responses
- `llmApi.js` is now primarily an entrypoint that wires those modules together

**Prompt Layer:**
- `src/core/llm/prompt/promptBuilderService.js` — wraps `generationWorker.js`
- `src/core/llm/prompt/promptEnrichmentService.js` — vector lore + memory injection + rebudgeting
- `src/core/llm/prompt/promptPreviewStore.js` — preview payloads separate from raw network traces

**Assembler Layer Started In This Branch:**
- `src/core/llm/assemblers/requestIntents.js` defines app-level request intents for `chat`, `summary`, and `memory_draft`
- `src/core/llm/assemblers/payloadBuilderRegistry.js` is the first explicit boundary for provider-specific payload builders
- `src/core/llm/assemblers/requestAssemblers.js` now bridges use cases to provider payload builders without keeping payload-shape details inline in `generationService.js`
- `generationService.js` still decides what semantic request should be sent, but the OpenAI-like payload assembly no longer lives inline in every use case
- this is the bridge toward future provider-specific payload builders without changing current prompt semantics

**Use Cases:**
- `src/core/llm/usecases/generateChat.js`
- `src/core/llm/usecases/generateSummary.js`
- `src/core/llm/usecases/generateMemoryDraft.js`
- `src/core/llm/usecases/calculateContext.js`

**UI Session Layer Landed In This Branch:**
- `src/composables/chat/useGenerationPreparation.js`
- `src/composables/chat/useGenerationStateSetup.js`
- `src/composables/chat/useGenerationStreamUpdate.js`
- `src/composables/chat/useGenerationPromptReady.js`
- `src/composables/chat/useGenerationCompleteHandler.js`
- `src/composables/chat/useGenerationErrorHandler.js`
- `src/composables/chat/useGenerationStateRestore.js`
- `src/composables/chat/usePromptMetadataSnapshots.js`
- `src/composables/chat/useTypingStateCleanup.js`

These composables now cover placeholder setup, stream UI application, prompt metadata rollback, background persistence throttling, abort/error restore, and completion finalization.

**Debug / Observability:**
- `src/core/llm/debug/requestTraceStore.js` — raw request/response traces keyed by generation
- `src/core/llm/debug/requestHistoryStore.js` — last N traces instead of a single global trace
- `src/core/llm/debug/previewAssembler.js` — joins prompt preview with request traces for the UI

### Recommended Refactor Sequence
1. Centralize runtime API config reads/writes so feature views stop reading localStorage keys directly.
   Status: partially done in this branch via `APISettings.js` helpers; remaining callers should be migrated incrementally.
2. Split `llmApi.js` into smaller transport-focused modules without changing external behavior.
   Status: mostly done; transport execution, lifecycle, SSE parsing, one-shot handling, and abort/failure outcomes are extracted. `llmApi.js` remains as the compatibility entrypoint.
3. Extract chat/session lifecycle code out of `ChatView.vue` into a dedicated generation-session composable.
   Status: largely done through multiple focused composables instead of one monolithic generation-session composable.
4. Separate prompt preview state from transport trace state, then store traces per generation/message instead of globally.
   Status: not done. Trace state is still singleton/global.
5. Promote explicit request use cases (`chat`, `summary`, `memory_draft`, `model_discovery`) with a shared normalized transport result shape.
   Status: partially done through request intents, payload builder registry, and normalized transport helpers.
6. Document the worker/service split so future prompt and retrieval changes have a stable boundary.
   Status: partially done in this document; should be kept current as retrieval/prompt work continues.

### Migration Guardrails
- Keep streaming and non-streaming behavior functionally identical while splitting modules.
- Preserve the native/mobile fallback where stream bodies are unavailable.
- Preserve partial-response recovery on abort/timeout until a new event contract fully replaces callbacks.
- Keep network trace capture optional and removable.
- Avoid changing prompt semantics during the initial transport/config refactor.
- Keep the embedding/vectorization stack out of this refactor until the chat/provider architecture stabilizes.
- Keep `MemoryBooks -> generateMemoryDraft(apiConfigOverride)` behavior compatible until a later step adds explicit provider selection for custom memory generation.

---

## 7. Cloud Sync

### Files
- `src/components/sheets/SyncSheet.vue` — UI for provider auth, encryption setup, push/pull, and conflict entry points
- `src/core/services/syncService.js` — high-level sync orchestration and readiness checks
- `src/core/services/syncEngine.js` — manifest diffing, entity serialization, encryption-aware upload/download
- `src/core/services/adapters/dropboxAdapter.js` — Dropbox OAuth + file operations
- `src/core/services/adapters/gdriveAdapter.js` — Google Drive OAuth + file operations
- `src/core/services/crypto/syncCrypto.js` — AES-GCM payload encryption
- `src/core/services/crypto/keyManager.js` — recovery phrase generation/restoration and key persistence
- `src/core/states/syncState.js` — provider, tokens, progress, auto-sync, conflict state
- `src/core/config/syncConfig.js` — build-time provider availability based on env keys
- `public/oauth/dropbox/redirect.html` — web popup callback bridge for Dropbox OAuth
- `public/oauth/gdrive/redirect.html` — web popup callback bridge for Google Drive OAuth

### Structure

**Ownership Model:**
- Maintainer configures OAuth app credentials in `.env`
- End users authenticate into their own Dropbox / Google Drive accounts
- Synced files are stored inside the authenticated user's own cloud under `/Glaze`
- The app never routes all users into one shared maintainer-owned storage account

**Provider Availability:**
- `syncConfig.js` exposes whether Dropbox or Google Drive auth can be started in the current build
- SyncSheet only shows provider buttons that have the required env key configured
- Existing sync state remains local; provider availability only controls whether a new OAuth sign-in can be initiated

**OAuth Flow:**
1. User taps Dropbox or Google Drive in `SyncSheet.vue`
2. Adapter builds provider-specific OAuth URL with PKCE + `state`
3. Browser/popup returns `code` to redirect HTML, Electron loopback callback, or native deep link
4. Adapter exchanges `code` for tokens and stores them in IndexedDB via `SYNC_TOKENS_KEY`
5. Future API calls reuse the stored access token and refresh when supported by the provider

**Platform Callback Paths:**
- Web: provider redirects to `public/oauth/*/redirect.html`, which posts the auth code back to the opener window
- Electron (Windows/Linux desktop): provider redirects to `http://127.0.0.1:PORT/oauth/callback`; `electron-main.cjs` captures the code through a temporary local server
- Android: provider redirects to `com.hydall.glaze://...`; `AndroidManifest.xml` declares a `VIEW` / `BROWSABLE` intent-filter so Capacitor `appUrlOpen` can receive it
- iPhone: provider redirects to `com.hydall.glaze://...`; `Info.plist` registers the URL scheme and `AppDelegate.swift` forwards it to Capacitor

**Data Flow:**
1. `syncService.js` picks adapter from `syncProvider`
2. `detectEncryptionState()` checks whether a local sync key exists
3. `pushEntities()` / `pullEntities()` compare local vs cloud manifest
4. Entity payloads are serialized per type, optionally encrypted, then uploaded to cloud paths under `/Glaze`
5. Pull emits conflicts when both local and remote changed since the previous sync baseline

**Encryption Model:**
- Encryption is optional and local-first
- Recovery phrase derives the AES-GCM key through `keyManager.js`
- Cloud never stores the recovery phrase or decrypted key material
- Without encryption, cloud payloads are plain JSON for easier debugging and portability

**Storage Boundaries:**
- OAuth tokens: IndexedDB `keyvalue` store via `SYNC_TOKENS_KEY`
- Sync settings and selected provider: `localStorage` (`gz_sync_settings`)
- Encryption key material: IndexedDB via `keyManager.js`
- Device identity and sync metadata: local storage + IndexedDB manifest state

**Synced Singleton Coverage:**
- Characters, personas, chats: full IndexedDB stores
- Lorebooks: single IndexedDB blob (`gz_lorebooks`)
- API connection presets: single IndexedDB blob (`gz_api_connection_presets`)
- Theme presets: single IndexedDB blob (`gz_theme_presets`)
- Theme active preset: single IndexedDB blob (`gz_theme_active_preset`) via `theme_state` entity
- App / API runtime settings: selected `localStorage` keys bundled under the `local_storage` entity
  - Includes: prompt presets, active preset IDs, persona connections, regex scripts, language, theme/layout toggles, battery saver, API provider/endpoint/model, temperature, stream, reasoning settings, timeouts
  - Also includes API key and model key (users should be aware credentials travel with this bundle)
- Not synced: active generation state, temporary UI state, push-notification tokens, debug network traces, embedding vectors

**Wipe Semantics:**
- `wipeCloudData()` deletes every file found under `/Glaze` via the provider adapter (`listAllFiles` + `deleteFile`).
- `resetSyncIdentityAfterWipe()` clears the local sync encryption key, manifest, deleted-entries registry, and device ID.
- After a wipe the cloud is effectively empty; the next `push` creates a fresh manifest and repopulates `/Glaze`.

---

## Key Integration Points

### Tokenizer ↔ Vectorization
- `generationWorker.js:sourceKeys` includes `vectorLore`
- `generationService.js` runs vector search for tokenizer display
- Tokenizer shows vector lorebook tokens inside reserve zone

### Vectorization ↔ MemoryBooks
- Memory entries use same `sourceType: 'memory_entry'` in embeddings
- `lorebookState.js` handles both lorebook and memory vector operations
- Reindex shared via `reindexMemoryEntry()`

### MemoryBooks ↔ Generation
- `generationService.js` calls `retrieveMemoryEntries()`
- Memory injected as separate context block
- Triggered memories tracked in `msg.triggeredMemories[]`

### Hidden Messages ↔ Context
- `ChatView.vue` supports bulk restore via `unhideAllMessages()`
- Hidden/unhidden messages trigger `updateContextCutoff()` so tokenizer and prompt window stay in sync

### Cloud Sync ↔ Local Data
- `syncEngine.js` serializes characters, personas, chats, presets, and selected local storage state
- Pull dispatches `sync-data-refreshed` so live UI can reload synced entities

### Cloud Sync ↔ Encryption
- `syncService.js` decides whether to request a sync key based on `detectEncryptionState()`
- `syncEngine.js` switches file extension and payload format between `.json` and `.enc`

### Cloud Sync ↔ Build Config
- `syncConfig.js` turns env keys into feature availability for provider sign-in
- Maintainer setup affects which provider buttons are visible, not which user cloud account is used after login

### Cloud Sync ↔ Platform Shells
- `electron-main.cjs` handles desktop OAuth loopback callback transport
- `AndroidManifest.xml` and iOS `Info.plist` define the app-owned deep link scheme expected by the native adapters

### Macros ↔ Generation
- `generationService.js` calls `replaceMacros()` on all prompt parts
- Session vars loaded from `localStorage` and saved back if changed
- Global vars persist across all chats

### API Settings ↔ Network Requests
- `ApiView.vue` edits runtime request settings and connection presets
- `APISettings.js` normalizes endpoints and serves as the current read boundary for generation requests
- `ChatView.vue`, `generationService.js`, and `llmApi.js` still depend on those settings directly or indirectly during request setup

### Prompt Preview ↔ Network Trace
- `generationService.js:getLastPrompt()` stores the last built request body before transport sanitization is sent
- `networkDebugService.js` stores the last raw request/response trace after transport begins
- `RequestPreviewSheet.vue` combines both views, which is useful for debugging but currently couples unrelated request types through shared singleton state

---

## Settings Ownership

| Setting | Owner | Location |
|---------|-------|----------|
| Embedding endpoint/key/model | API | `embeddingSettings.js` → localStorage |
| Embedding enabled toggle | API | `embeddingSettings.js` → localStorage |
| Max chunk tokens | API | `embeddingSettings.js` → localStorage |
| Search type (keys/vector/both) | Lorebook | `lorebookState.globalSettings` |
| Scan depth | Lorebook | `lorebookState.globalSettings` |
| Vector threshold | Lorebook | `lorebookState.globalSettings` |
| Vector top K | Lorebook | `lorebookState.globalSettings` |
| Embedding target (content/keys) | Lorebook | `lorebookState.globalSettings` |
| Memory search type | MemoryBook session | `memoryBook.settings.vectorSearchEnabled` + `keyMatchMode` |
| Dropbox OAuth app key | Build config | `.env` → `syncConfig.js` |
| Google Drive OAuth client ID | Build config | `.env` → `syncConfig.js` |
| Connected sync provider | Sync state | `syncState.js` → localStorage |
| Sync OAuth tokens | Sync state | IndexedDB via `SYNC_TOKENS_KEY` |
| Recovery phrase-derived key | Crypto | IndexedDB via `keyManager.js` |
| API endpoint/key/model | API runtime config | `APISettings.js` ↔ localStorage |
| API stream/temp/topP/max tokens/context | API runtime config | `APISettings.js` ↔ localStorage |
| Reasoning toggle/tags/effort | API runtime + preset override | `APISettings.js`, `PresetView.vue`, localStorage |
| API connection presets | API presets | IndexedDB `gz_api_connection_presets` |
| Last built prompt preview | Generation debug state | `generationService.js` singleton memory |
| Last network trace | Network debug state | `networkDebugService.js` ↔ localStorage |

---

## Testing Checklist

### Tokenizer
- [ ] Context breakdown shows correct proportions
- [ ] Reserve zone contains lorebook entries
- [ ] Token count updates on message hide/delete

### Vectorization
- [ ] Entries index successfully with progress display
- [ ] Vector search returns relevant results
- [ ] Dual-channel: keyword + vector results merged (searchType='both')
- [ ] Vector-only mode works (searchType='vector')
- [ ] Keys-only mode works without vector overhead (searchType='keys')
- [ ] Force reindex rebuilds legacy single-vector entries

### MemoryBooks
- [ ] Scan Chat creates planned segments
- [ ] Batch Generate creates drafts sequentially
- [ ] Approved memories show MEM badge
- [ ] Auto-creation respects delayed mode
- [ ] Delete/branch marks entries stale
- [ ] Memory injection skips entries whose message range is still inside current prompt context
- [ ] Memory search type dropdown updates retrieval mode correctly

### Macros
- [ ] SillyTavern variables (setvar/getvar) persist per session
- [ ] Global variables (setglobalvar/getglobalvar) persist across sessions
- [ ] Lucid Loom macros resolve from global vars
- [ ] Datetime macros return current values
- [ ] Comments are stripped from output

### Reasoning
- [ ] User reasoning toggle works regardless of preset
- [ ] Inline reasoning tags extracted from content
- [ ] Native reasoning_content field displayed
- [ ] Both sources combined without duplication
- [ ] Mobile/native stream fallback returns a full response instead of hard-failing when streaming body is unavailable

### Network / LLM Requests
- [ ] Chat requests succeed in both streaming and non-streaming modes
- [ ] Native non-stream requests still work through `CapacitorHttp`
- [ ] Missing stream reader fallback still produces a complete response
- [ ] User abort preserves partial text when expected
- [ ] Timeout abort reports an error and does not leave phantom typing state
- [ ] Summary and memory-draft requests do not regress while chat transport is refactored
- [ ] Request preview still shows the final built payload after prompt assembly
- [ ] Network trace capture remains optional and does not affect generation success
- [ ] Native/mobile generation remains responsive on lower-end devices during long streaming responses
- [ ] Native auto-sync does not start while active generation is still running
- [ ] Prompt metadata rollback still works after abort/error paths
- [ ] Late vector lore still respects `maxInjectedEntries` after transport/refactor changes

### Cloud Sync
- [ ] Provider buttons only appear when their env keys are configured
- [ ] Dropbox auth signs user into that user's own Dropbox account
- [ ] Google Drive auth signs user into that user's own Google Drive account
- [ ] Push works with encryption disabled (`.json` payloads)
- [ ] Push/Pull works with encryption enabled (`.enc` payloads)
- [ ] Conflicts surface in `SyncSheet.vue` and can be resolved without data loss
