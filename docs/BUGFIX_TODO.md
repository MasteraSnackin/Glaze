# Bug Fix Todo

## Critical

### BUG-1: DB read-modify-write race — settings lost on close
**Status:** fixed  
**Symptom:** Memory book custom prompts, model settings, generation config disappear after closing/opening app.  
**Root cause:** `asyncSaveCurrentSessionState` and `onBeforeUnmount` both do `getChatData()` → modify → `db.saveChat()` as fire-and-forget. If the memory sheet saved settings between the read and the write-back, the stale chatData overwrites the new settings.  
**Fix applied:**
1. `db.saveChat` now uses `queueDbWrite` (serialized writes, no concurrent overwrites)
2. Added `db.patchChatData(charId, patchFn)` — reads fresh DB state, applies only the patch, saves atomically
3. `asyncSaveCurrentSessionState` and `onBeforeUnmount` switched to `patchChatData` (no stale overwrites)

**Files:** `src/utils/db.js`, `src/views/ChatView.vue`

---

### BUG-2: No save on app background — DB reverts to last launch on crash
**Status:** fixed  
**Symptom:** App freeze during memory draft → kill → chat reverts hours back (to last app launch).  
**Root cause:**
- No `visibilitychange` or Capacitor `appStateChange` handler saves chat state when going to background
- `onBeforeUnmount` is fire-and-forget, only saves scrollAnchor + draft (NOT currentMessages)
- `db.set` resolves on `req.onsuccess` (not `tx.oncomplete`) — data may not be durable when process is killed

**Fix applied:**
1. `onVisibilityChange` now saves `currentMessages` + draft + authorsNote + summary via `patchChatData` when `visibilityState === 'hidden'`
2. Added Capacitor `App.addListener('appStateChange')` that saves messages + draft on `isActive === false`
3. `db.set` and `db.delete` now resolve on `tx.oncomplete` instead of `req.onsuccess` (durable writes)
4. `onBeforeUnmount` now saves `currentMessages` + draft + authorsNote + summary via `patchChatData`
5. `db.saveChat` now uses `queueDbWrite` (serialized writes)

**Files:** `src/views/ChatView.vue`, `src/utils/db.js`

---

### BUG-3: App freeze on memory draft generation
**Status:** not fixed  
**Symptom:** App hangs during memory draft, no recovery except kill.  
**Likely cause:**
- Memory draft generation may block the main thread (worker communication issue, unhandled promise, or infinite loop in draft parsing)
- Possible memory leak: closures may hold references to old reactive state after component updates
- `isGeneratingDraft` flag may get stuck if the generation abort path doesn't clear it

**Investigation needed:**
1. Check if `generateMemoryDraft` has proper abort/cleanup on error
2. Check if draft parsing (`parseMemoryDraftResponse`) can hang on malformed model output
3. Profile for memory leaks — check if reactive refs hold stale references
4. Verify `stopMemoryDraftProgress` is called on all error paths

**Files:** `src/views/ChatView.vue`, `src/core/services/memoryBooksService.js`

---

## Medium

### BUG-4: Tokenizer cutoff index mismatch with hidden messages
**Status:** fixed  
**Symptom:** Tokenizer cutoff line appears at wrong position when hidden messages exist.  
**Root cause:** `cutoffIndex` is calculated against a filtered list (`!m.isHidden`) but `displayMessages` was comparing raw index `i` against it.  
**Fix applied:** `displayMessages` now tracks a separate `visibleIndex` counter that increments only for non-hidden messages, and compares `visibleIndex` against `cutoffIndex.value`.

**Files:** `src/views/ChatView.vue`

---

### BUG-5: Memory tokens not factored into cutoff calculation
**Status:** fixed  
**Symptom:** Context breakdown may report more remaining space than actually available when memory injection is active.  
**Root cause:** `calculateContext` ran the worker first, then added memory tokens post-hoc. The worker's `availableForHistory` and `cutoffIndex` didn't account for memory overhead.  
**Fix applied:**
1. Added `getMemoryReserveEstimate()` — reads active memory entries from DB, estimates token cost, caps at 35% of safeContext
2. Memory reserve passed to `buildPromptWorkerPayload` as `memoryReserve`
3. Worker adds `memoryReserve` to `fixedTotal` alongside `lorebookReserve`, reducing `availableForHistory` upfront
4. `buildMergedContextBreakdown` and `buildContextCalculationResult` include `memoryReserve` in breakdown
5. Both `calculateContext` and `generateChatResponse` compute memory reserve before calling worker

**Files:** `src/core/services/generationService.js`, `src/workers/generationWorker.js`

---

### BUG-6: `updateSessionMessage` uses `data.currentId` instead of actual sessionId
**Status:** fixed  
**Symptom:** Message updates may be written to wrong session after session switch.  
**Root cause:** `updateSessionMessage` reads `data.currentId` from DB, but if user navigated to a different session, `currentId` may not match `activeChatChar.sessionId`.  
**Fix applied:** Uses `char.sessionId || data.currentId` — prefers the actual active session.

**Files:** `src/views/ChatView.vue`

---

## Done

### BUG-0: Memory selection buttons clutter in selection mode
**Status:** fixed  
**Fix:** Hidden 4 memory-related selection buttons (config, draft, create, remove) in ChatInput.vue. Will be re-added after UX polish.
