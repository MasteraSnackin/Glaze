# Generation Invariants

This document records the runtime behavior that must not change during the refactor.
Every structural PR must preserve these invariants or explicitly document a deviation.

---

## 1. Chat Generation Invariants

### INV-C1: One active chat generation per character

At most one chat-type generation may be active for a given `charId` at any time.
`startGeneration` enforces this via `getGenerationState(charId)` — if a non-impersonation
state exists, the call is silently rejected (`ChatView.vue:2221-2227`).

### INV-C2: Generation state is always eventually cleaned up

For every `setGenerationState(charId, ...)`, there must be a matching
`clearGenerationState(charId, ...)` on every exit path: completion, error, abort, or unmount.

**Abort path:** `useGenerationAbort` delegates cleanup to `handleGenerationError → finalizeGenerationState`
instead of calling `clearGenerationState` directly, to avoid double-cleanup and stale guard conflicts.
This satisfies the invariant — `clearGenerationState` is still called, just from the error handler.

**Previously violated (fixed in Phase 2):**
- ~~Stale completion path (`useGenerationCompleteHandler.js:136-141`) calls `ensureStaleCleanup` but does NOT call `clearGenerationState`.~~ **Fixed:** `ensureStaleCleanup` now uses `finalizeGenerationState` which always calls `clearGenerationState`.
- ~~`onUnmounted` (`ChatView.vue:3428-3455`) aborts controllers and clears timers but does NOT call `clearGenerationState`.~~ **Fixed:** `onUnmounted` now calls `clearGenerationState(charId)` after cleanup.

### INV-C3: Partial text is preserved on abort

When a user aborts mid-stream and partial text exists, the partial response is saved
as a completed message — not discarded. This is handled by `handleAbortOutcome`
in `requestOutcome.js:55-77`.

### INV-C4: isGenerating is consistent with registry state

`isGenerating.value` must be `true` iff `hasGenerationState(activeChatChar.id)` is true
for the currently active character. On `openChat`, `isGenerating` is restored from
registry state (`ChatView.vue:1717`).

### INV-C5: Prompt metadata snapshots are restored on abort/error

`createPromptMetadataSnapshots()` is called before generation starts.
`restoreState()` must be called on every non-happy exit to roll back
any session variable mutations that occurred during prompt preparation.

### INV-C6: Background generation continues independently

When a generation is running for character A and the user switches to character B,
generation for A continues in the background. Stream deltas are persisted to DB
via background persistence (`useGenerationStreamUpdate.js:42-63`).

### INV-C7: Stale completions are silently discarded

If a late `onComplete` fires for a `genId` that no longer matches the current
`generationStates[charId]`, the stale result is discarded and only cleanup is performed
(`useGenerationCompleteHandler.js:136-141`).

---

## 2. Summary Generation Invariants

### INV-S1: Summary is always non-streaming

Summary requests never use SSE streaming. The response is returned as a single
string from `executeSummaryRequest` (`summaryRequest.js:1-53`).

### INV-S2: Summary does not create registry entries

Summary generation does not use `generationStates` at all. It has no `genId`,
no `requestToken`, and no UI state management beyond the caller's responsibility.

### INV-S3: Summary does not mutate chat state

Summary generation must not modify `isGenerating`, chat messages, or
generation registry state. It only reads history and returns a string.

---

## 3. Memory Draft Generation Invariants

### INV-M1: Memory draft does not use generation registry

Memory drafts use their own abort infrastructure (`memoryDraftAbortControllers` Map
in `useMemoryBooks.js`) and their own progress tracking (`memoryDraftProgressEntries` Map).
They never interact with `generationStates`.

### INV-M2: Memory draft is always non-streaming

Memory draft requests use `stream: false` unconditionally
(`memoryDraftRequest.js:69`).

### INV-M3: Memory draft cannot start while chat generation is active

`useMemoryAutomation.js:210-213` checks `getGenerationState(activeChatChar.id)`
and blocks if a non-impersonation generation is running.

### INV-M4: Chat generation cannot start while memory draft is active

`startGeneration` now checks `memoryDraftState.value?.active` and blocks if a
memory draft is in progress for the same character, showing a toast message.
This was a known gap that was fixed in Phase 2.

---

## 4. Request Ownership Invariants

### INV-O1: Every generation has a unique genId

`genId` is a monotonically increasing integer from `generationIdCounter`
(`useGenerationRegistry.js:35-37`). It uniquely identifies a generation attempt.

### INV-O2: requestToken is composed from ownerKey + genId

`requestToken = "${ownerKey}:${genId}"` where `ownerKey = "${scope}:${charId}:${sessionId}"`
(`useGenerationRegistry.js:8-10`). This provides a fully qualified identifier for a
specific generation attempt within a specific session scope.

### INV-O3: Stale responses are rejected by genId check

All callbacks (`onUpdate`, `onComplete`, `onError`) verify `genId` matches the current
`generationStates[charId]` before applying mutations. If `genId` doesn't match,
the callback is either discarded or routed to a stale cleanup path.

### INV-O4: clearGenerationState with expected genId prevents double-cleanup

When `clearGenerationState(charId, expectedGenId)` is called with a `genId` argument,
it only deletes the entry if the current `genId` matches. This prevents an abort
from clearing the state of a subsequently started generation.

---

## 5. Stream vs Non-Stream Parity

### INV-P1: Final output is identical regardless of transport mode

Both streaming and non-streaming paths must produce the same final `onComplete(text, reasoning)`
result for the same API response. Streaming accumulates incrementally; non-streaming
extracts from the complete JSON — but the final normalized output must be equivalent.

### INV-P2: Reasoning extraction is equivalent

- Streaming: inline reasoning tags extracted incrementally by `streamAccumulator`
- Non-streaming: inline tags stripped by `normalizeReasoningOutput`, model reasoning
  field merged by `responseNormalizer.js:12-36`

Both must produce the same `reasoning` output for the same raw content.

### INV-P3: Abort behavior differs by design

- Streaming: partial text can be preserved on abort (incremental accumulation)
- Non-streaming: no partial text is available on abort (single response)

This asymmetry is intentional and correct.

### INV-P4: Non-streaming fallback preserves semantics

When a server returns a non-SSE response to a streaming request, the app falls back
to `completeJsonResponse()` (`chatCompletionsClient.js:53-76`). The final result
must be identical to what streaming would have produced.

### INV-P5: Native HTTP and fetch produce identical results

On native platforms with `http:` URLs, `CapacitorHttp.post` is used instead of `fetch`.
Both paths must normalize to the same output structure.

---

## 6. Prompt Semantics Invariants

### INV-PS1: Prompt block order is determined by preset blocks array

The order of blocks in the prompt is fully determined by the preset's `blocks` array
as processed in `generationWorker.js:649-764`. The preset is the sole controller
of prompt topology. Character fields only appear when a matching preset block ID exists.

### INV-PS2: Keyword scan always precedes vector scan

Keyword lorebook scanning happens inside the Web Worker (`generationWorker.js:150-323`).
Vector scanning happens on the main thread after the worker completes
(`chatPostPromptPipeline.js:52-53`). Vector results are deduplicated against
keyword results and capped by `maxInjectedEntries - keywordCount`.

### INV-PS3: History cutoff is newest-first

When context overflows, history is always trimmed from the **oldest** end.
The cutoff walk proceeds from `historyMessages.length - 1` toward 0
(`generationWorker.js:880-889`). Newer messages are always retained preferentially.

### INV-PS4: Context limit is enforced twice

1. Worker-side: initial cutoff during prompt building (`generationWorker.js:871-905`)
2. Late-enrichment: re-cutoff after vector lore + memory injection
   (`chatLateEnrichment.js:199-233`)
3. Final guard: if static tokens still exceed `safeContext`, generation aborts
   (`chatPostPromptPipeline.js:95-108`)

### INV-PS5: Memory injection position is deterministic

- `summary_macro` target: memory is appended to the summary message content
  (`chatLateEnrichment.js:55-85`)
- `summary_block` target (default): memory is inserted before the first history message
  (`chatLateEnrichment.js:122-130`)

Given the same inputs, the injection position is always the same.

### INV-PS6: Memory injection is guarded by token budget

If memory tokens >= 35% of `safeContext` OR memory tokens <= 0, injection is **aborted**
(`memoryBookContext.js:285-293`). This prevents memory from starving the context.

### INV-PS7: Regex application order is deterministic

Preset regex scripts run first, then global regex scripts
(`generationWorker.js:373-374`). Within each group, scripts are applied in array order.
Each script runs `trimOut` before `regex` (`generationWorker.js:96-105,136`).

### INV-PS8: Preset overrides character settings, not merges

The preset's `blocks` array fully controls what appears in the prompt. Character data
(description, personality, scenario, mes_example) is only included when a preset block
with the corresponding `id` resolves it (`generationWorker.js:538-552`). If a preset
block is disabled or stashed, that character field is omitted.

### INV-PS9: Macro resolution order is fixed

Within a single `replaceMacros` call (`macroEngine.js:5-118`), macros are resolved
in this order:
1. Comment stripping
2. Static character macros (`{{char}}`, `{{user}}`, etc.)
3. Trim macro
4. Session variable macros (`{{setvar::}}`, `{{getvar::}}`)
5. Custom named macros
6. Random/Pick macros
7. Dice macros
8. Date/Time macros
9. Reasoning tag macros
10. Escape handling

### INV-PS10: Recursive lorebook scan is bounded

Recursive keyword scanning is limited to `maxIterations = 5` (or 1 if
`recursiveScan !== false`) (`generationWorker.js:196`). This prevents infinite loops
from circular lorebook references.

---

## 7. Abort and Regenerate Invariants

### INV-A1: Abort propagates through all layers

When `controller.abort()` is called:
- `AbortController.signal.aborted` becomes `true`
- The streaming SSE loop checks `throwIfAborted()` every iteration (`streamingSse.js:30`)
- `chatPreparedPromptExecution.js:63-65` checks before running the worker
- `chatRequestExecution.js:47-49` checks before dispatching the request
- Pipeline loop breaks and calls `onError(AbortError)` with `userAborted` from controller (`postPromptOrchestrator.js:80-90`)
- All early abort checks propagate `userAborted` from controller (`steps.js:128-132`, `chatRequestAssembly.js:124-128`, `chatPreparedPromptExecution.js:63-67`)

### INV-A2: Regenerate during active generation is silently rejected

If `startGeneration` is called while a non-impersonation generation is active,
the call is silently rejected (`ChatView.vue:2221-2227`). The user gets no feedback.
This is a UX gap but prevents overlap.

### INV-A3: Impersonation bypasses the overlap guard

Impersonation (`type === 'impersonation'`) is allowed to start even when another
generation is active. This is intentional — impersonation overwrites the existing state.

### INV-A4: Abort restores pre-generation state

`restoreState()` rolls back: pending swipe, placeholder message, isTyping flag,
and prompt metadata snapshots. The chat must return to the state it was in before
the generation started.

`handleGenerationError` treats ALL `AbortError` (regardless of `userAborted` flag)
as silent cleanup — no error toast, no error message in chat. Empty placeholder
messages are removed; partial text is preserved via `rollbackPendingSwipe`.

---

## Refactor PR Checklist

Before merging any structural PR, verify:

- [ ] Chat generation still produces correct responses
- [ ] Stop generation preserves partial text when available
- [ ] Regenerate while generating is safely rejected
- [ ] Switching characters during generation continues background generation
- [ ] Prompt block order matches the preset definition
- [ ] Lorebook keyword + vector results are correctly merged
- [ ] Memory injection respects token budget guard
- [ ] History cutoff trims oldest messages first
- [ ] Summary generation returns a string without affecting chat state
- [ ] Memory draft generation doesn't affect chat generation registry
- [ ] Context limit exceeded is caught and shown to the user
- [ ] API not configured is caught and shown to the user
