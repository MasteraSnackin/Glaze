# Refactor Plan

Planned refactoring tasks. Completed items are moved to `docs/refactor-history.md`.

## 2026-05-03 — Async Operation Lifecycle & Cloud Sync

### Rationale

Four bugs (streaming lost on leave, inline image edit race, regex DB crash, background image gen) all share the same root cause: components treat async operation lifecycle as their own, aborting operations on unmount instead of disconnecting UI subscriptions. Additionally, cloud sync (`syncEngine.js` ~955 lines) is a monolith mixing merge logic, conflict resolution, transport, and UI state.

### Task 1: `AsyncOperationScope` utility

**Status:** not started  
**Priority:** high  
**Scope:** new file `src/core/utils/asyncOperationScope.js`

Create a reusable utility that formalizes the "subscribe ≠ abort" pattern:

```
createAsyncScope() → {
  subscribe(opId, onUpdate)     — component subscribes to operation results
  unsubscribe(opId)            — component disconnects (onUnmounted calls THIS)
  register(opId, controller)   — service registers a running operation
  complete(opId)               — service marks operation done, runs cleanup
  abort(opId)                  — explicit user abort only (stop button)
  isActive(opId)               — check if operation is running
}
```

Key invariant: `unsubscribe` never calls `.abort()`. `abort` is only callable by service-layer code.

### Task 2: Refactor `generationState.js` + `imageGenState.js` to use `AsyncOperationScope`

**Status:** not started  
**Priority:** high  
**Depends on:** Task 1  
**Scope:**
- `src/core/states/generationState.js` — replace manual `controller.abort()` orchestration with `AsyncOperationScope`
- `src/core/states/imageGenState.js` — same
- `src/views/ChatView.vue` — `onUnmounted` uses `scope.unsubscribe()` instead of direct controller manipulation
- `src/composables/chat/useGenerationAbort.js` — `abortGeneration` uses `scope.abort()`
- Verify all 4 previous bug fixes still work after refactor

**Risk:** Medium — touches hot path (generation lifecycle). Must be tested with:
- Generation during character switch
- Background generation completion
- Explicit user abort
- Image gen + edit race condition

### Task 3: Cloud sync refactor

**Status:** not started  
**Priority:** medium  
**Scope:** `src/core/services/syncEngine.js` (~955 lines)

Current problems:
- **Monolith:** merge logic, conflict resolution, cloud transport, progress reporting, and UI state all in one file
- **Merge logic scattered:** `silly_cradle_presets` merge at line 445, `regex_scripts` merge at line 467, all other keys get blind overwrite — no consistent merge strategy
- **No merge strategy registry:** each localStorage key needs its own merge rules (array-by-ID, deep-merge, last-write-wins), but there's no declarative way to express this
- **955 lines with mixed concerns:** should be split into 3-4 modules

Proposed split:
```
src/core/services/sync/
  syncEngine.js          — orchestration, push/pull cycle (~200 lines)
  syncMerge.js           — merge strategies per entity type (~150 lines)
  syncTransport.js       — cloud API calls, upload/download (~200 lines)
  syncConflict.js        — conflict detection & resolution UI (~150 lines)
  syncManifest.js        — manifest CRUD, diff logic (~100 lines)
```

Merge strategy registry pattern:
```js
const MERGE_STRATEGIES = {
  'silly_cradle_presets': mergePresetObjects,
  'regex_scripts': mergeArrayById,
  'gz_lang': lastWriteWins,
  // ... declarative, no more if/else chains
};
```

### Task 4: `visibilitychange` state preservation audit

**Status:** not started  
**Priority:** low  
**Depends on:** Task 2  
**Scope:**
- Audit all `visibilitychange` handlers for unsafe concurrent writes
- Ensure `asyncSave` in `onVisibilityChange` does not overwrite in-progress async operation results
- Add intermediate state serialization for suspended operations (mobile background)
- Document which operations are safe to suspend vs must be restarted

### Testing requirements

All tasks require manual verification on:
- [ ] Desktop (Electron): generation + character switch + return
- [ ] Mobile (Android): generation + app minimize + return
- [ ] Cloud sync: push + pull with concurrent local changes
- [ ] Image gen: edit during generation, regenerate after abort
