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
**Status:** not fixed  
**Symptom:** Tokenizer cutoff line appears at wrong position when hidden messages exist.  
**Root cause:** `cutoffIndex` is calculated against a filtered list (`!m.isHidden`) but `displayMessages` inserts the cutoff marker while iterating the full unfiltered `currentMessages`. The index doesn't map correctly.  
**Fix:** In `displayMessages`, track the visible-message index separately from the raw index, and compare the visible index against `cutoffIndex.value`. Or: include hidden messages in the cutoff index calculation but mark them accordingly.

**Files:** `src/views/ChatView.vue`

---

### BUG-5: Memory tokens not factored into cutoff calculation
**Status:** not fixed  
**Symptom:** Context breakdown may report more remaining space than actually available when memory injection is active.  
**Root cause:** `updateContextCutoff` calculates cutoff before memory is injected. The post-hoc `buildMergedContextBreakdown` only adjusts `remaining` retroactively, but `cutoffIndex` and `availableForHistory` were already set by the worker without knowing about memory overhead.  
**Fix:** Reserve memory budget upfront in the worker payload (pass estimated memory tokens as a `reservedContext` parameter) so the worker's cutoff accounts for memory space before calculating the history window.

**Files:** `src/core/llm/usecases/chatContextCalculation.js`, `src/workers/generationWorker.js`, `src/core/services/generationService.js`

---

### BUG-6: `updateSessionMessage` uses `data.currentId` instead of actual sessionId
**Status:** not fixed  
**Symptom:** Message updates may be written to wrong session after session switch.  
**Root cause:** `updateSessionMessage` reads `data.currentId` from DB, but if user navigated to a different session, `currentId` may not match `activeChatChar.sessionId`.  
**Fix:** Pass the actual `activeChatChar.sessionId` explicitly to `updateSessionMessage` instead of relying on `data.currentId`.

**Files:** `src/views/ChatView.vue`

---

## Done

### BUG-0: Memory selection buttons clutter in selection mode
**Status:** fixed  
**Fix:** Hidden 4 memory-related selection buttons (config, draft, create, remove) in ChatInput.vue. Will be re-added after UX polish.
