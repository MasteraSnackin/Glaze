# Race Condition Prevention Rules

Every new feature or fix that touches async boundaries, generation state, or IndexedDB must satisfy these rules before commit.

## Rule 1: Every `await` is a checkpoint

After any `await`, always verify you still own the state:

- Not aborted? `controller.signal.aborted`
- Same generation? `isGenerationStateCurrent(charId, genId)`
- Same session? `sessionId === expected`

Pattern:
```javascript
const result = await someAsyncWork();
if (controller?.signal?.aborted) return;
if (!isGenerationStateCurrent(charId, genId)) return;
```

## Rule 2: No state mutation without ownership

- `onComplete` / `onError` / `onUpdate` callbacks MUST check `genId` before mutating any reactive state
- New composables that participate in generation lifecycle MUST use `useGenerationRegistry` for ownership tokens
- Transient state (isGenerating, typing placeholder, pending swipe) is owned by a single generation token and auto-cleaned on finalization

## Rule 3: `patchChatData` for all read-mutate-write

- NEVER do `const data = await db.getChat(charId); /* mutate */; await db.saveChat(charId, data)` — this is a race
- ALWAYS use `patchChatData(charId, draft => { /* mutate draft */ })` — serializes read-mutate-write via `queueDbWrite`
- New composables that persist chat state must import `patchChatData` from `db.js`

## Rule 4: New async boundaries need stale guards

When adding a new composable or service function that:
- receives callbacks from transport/pipeline/use-case layer
- mutates Vue reactive state
- persists data to IndexedDB

...it MUST include a staleness/ownership check before the mutation. Without it, a late completion from an aborted generation WILL corrupt state.

## Rule 5: Mutual exclusion for concurrent operations

- Chat generation and memory draft generation are mutually exclusive (checked in both directions)
- If adding a new request type that runs alongside chat generation, add mutual exclusion guards in BOTH directions
- Background operations (auto-sync, embedding indexing) must check `isGenerating` before starting

## Why this matters

The hybrid architecture has more boundaries than the old flat structure. Each boundary is a potential race surface. The old code had the same races — they were just invisible because everything mutated shared state in one call stack. The new architecture makes races visible, and these rules make them preventable.

## Known race classes and their fixes

| Race | Cause | Fix |
|------|-------|-----|
| Stale completion mutates new typing state | Callback didn't check genId | `expectedGenId` in finalize/restore/complete |
| Abort didn't reach fetch() | controller not in requestConfig | Signal chain through `createImmutableChatRequestEnvelope` |
| Read-mutate-write in IndexedDB | `saveChat` without serialization | `patchChatData` with `queueDbWrite` |
| Registry leak after unmount | `clearGenerationState` not called | Fix in `onUnmounted` |
| Memory draft + chat generation simultaneously | No mutual exclusion | Block in both directions |
