# Generation Lifecycle Rules

Mandatory rules for any code that participates in chat generation, summary, memory draft, or transport.

Full formal invariants with code references: `docs/INVARIANTS.md`

## Generation types and their scopes

| Type | Registry | Streaming | Abort | State isolation |
|------|----------|-----------|-------|-----------------|
| Chat | `generationStates` (genId) | Yes | Shared `AbortController` | Per charId |
| Summary | None | No | Caller-owned | No chat state mutation |
| Memory draft | Own `memoryDraftAbortControllers` | No | Per-draft controller | Per charId, separate from chat |

## Mutual exclusion

- Chat generation and memory draft CANNOT run simultaneously for the same charId (guards in BOTH directions)
- Summary is stateless and can run alongside anything
- Background operations (auto-sync, embedding indexing) must check `isGenerating` before starting

## genId ownership

Every chat generation gets a unique `genId`. All callbacks (`onUpdate`, `onComplete`, `onError`) MUST verify `genId` matches `generationStates[charId]` before mutating state. If mismatch — discard or route to stale cleanup.

`requestToken = "${scope}:${charId}:${sessionId}:${genId}"` — fully qualified ownership identifier.

## Abort signal chain

```
controller.abort()
  → AbortController.signal.aborted = true
  → completionsClient passes signal to fetch()
  → streamingSse checks throwIfAborted() per chunk
  → reader.cancel() closes TCP connection
  → handleAbortOutcome() routes with userAborted flag
  → onError(AbortError) fast-paths without error toast
```

**Never break this chain.** If `controller` doesn't reach `fetch()`, stop button only clears UI while TCP stays open.

## State cleanup on every exit path

For every `setGenerationState(charId, ...)` there MUST be a `clearGenerationState(charId, ...)` on:
- Completion
- Error
- Abort
- Component unmount

`clearGenerationState(charId, expectedGenId)` prevents double-cleanup from abort clearing a newer generation's state.

## Partial text on abort

- Streaming: preserve partial text as completed message
- Non-streaming: no partial text available (by design)
- This asymmetry is intentional

## Prompt ordering (do not reorder)

1. Keyword lorebook scan (in Worker)
2. Vector lorebook scan (after Worker, deduplicated against keyword results)
3. Memory injection (guarded by 35% token budget)
4. Context cutoff trims oldest first

## Stream vs non-stream parity

Both paths must produce identical `onComplete(text, reasoning)` for the same API response. Native HTTP (`CapacitorHttp`) and `fetch()` must normalize to the same output structure.

## PR verification checklist

Before merging any structural PR:
- [ ] Chat generation produces correct responses
- [ ] Stop preserves partial text when available
- [ ] Regenerate while generating is safely rejected
- [ ] Character switch during generation continues background generation
- [ ] Prompt block order matches preset definition
- [ ] Lorebook keyword + vector results correctly merged
- [ ] Memory injection respects token budget guard
- [ ] History cutoff trims oldest first
- [ ] Summary returns string without affecting chat state
- [ ] Memory draft doesn't affect generation registry
- [ ] Context limit exceeded caught and shown
- [ ] API not configured caught and shown
