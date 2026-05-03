# 🧪 Testing Checklist — Refactoring Phase

Branch: `feat/refactor-tokenizer-memorybooks`  
Date: 2026-04-17

## 📦 Changes Summary

**3 commits:**
1. `d215502` - Vector/Lorebook UX fixes + optional dual-channel
2. `b5857d0` - Tokenizer loading & performance
3. `78be7ed` - Memory Books UX & improved prompts

**Files changed:** 11 files, +425 lines, -90 lines

---

## ✅ Quick Verification Checklist (15 minutes)

### **1. Vector/Lorebook UX** (Commit d215502)

**Test: Keyword UI visibility**
- [ ] Open any lorebook entry
- [ ] Enable "Vector Search" checkbox
- [ ] **VERIFY**: Keyword fields (Primary Keys, Logic Mode, etc.) are still VISIBLE
- [ ] **VERIFY**: Message shows "Vector search supplements keyword matching (dual-channel retrieval)" in green

**Test: Retrieval badges**
- [ ] Generate a message that triggers lorebook entries
- [ ] Click the lorebook trigger badge on the message
- [ ] **VERIFY**: Entries show `[keyword]` badge (green) or `[vector]` badge (purple)

**Test: Optional keyword search**
- [ ] Open lorebook entry with Vector Search enabled
- [ ] **VERIFY**: New checkbox appears: "Also use keyword matching"
- [ ] **VERIFY**: Checkbox is checked by default
- [ ] Uncheck it, save entry
- [ ] Generate message
- [ ] **VERIFY**: Entry retrieved ONLY via vector (not keyword)

---

### **2. Tokenizer Performance** (Commit b5857d0)

**Test: No "not ready yet" error**
- [ ] Open a chat
- [ ] Immediately open Tokenizer (MagicDrawer → Tokenizer)
- [ ] **VERIFY**: Shows context breakdown (not "Context breakdown is not ready yet")
- [ ] If error still appears, wait 5 seconds and it should resolve

**Test: Fast repeated opens**
- [ ] Open Tokenizer
- [ ] Close it
- [ ] Open Tokenizer again immediately
- [ ] **VERIFY**: Opens quickly (< 1 second)
- [ ] No long delay or freezing

---

### **3. Memory Books - Pending Indicators** (Commit 78be7ed)

**Test: PENDING badge**
- [ ] Open a chat with Memory Books enabled
- [ ] Enable auto-create memory (interval: 5 messages for testing)
- [ ] Send 5+ messages (trigger automation)
- [ ] **VERIFY**: Messages show `PENDING` badge (gold, pulsing)
- [ ] Wait for draft generation to complete
- [ ] **VERIFY**: PENDING badge disappears after draft created

---

### **4. Memory Books - Draft Timer** (Commit 78be7ed)

**Test: Live timer updates**
- [ ] Open Memory Books (MagicDrawer → Memory Books)
- [ ] Generate a memory draft (select messages, create draft)
- [ ] **VERIFY**: Timer updates smoothly every ~100ms
- [ ] **VERIFY**: No flickering or sheet closing/reopening
- [ ] Note reads: "The timer will update automatically while generation is in progress"

---

### **5. Memory Books - Draft Preview** (Commit 78be7ed)

**Test: Regenerate button**
- [ ] Open Memory Books
- [ ] Click on a pending draft to preview
- [ ] **VERIFY**: Shows "Regenerate" button
- [ ] **VERIFY**: Shows "Back" button (not "Close")
- [ ] Click "Back"
- [ ] **VERIFY**: Returns to Memory Books sheet (doesn't close completely)

**Test: Regenerate functionality**
- [ ] Open a pending draft
- [ ] Click "Regenerate"
- [ ] **VERIFY**: Starts regeneration, closes preview
- [ ] **VERIFY**: Returns to Memory Books after completion
- [ ] **VERIFY**: New draft replaces old one

**Test: Approved entry preview**
- [ ] Approve a draft
- [ ] Click on the approved entry
- [ ] **VERIFY**: Shows "Edit", "Reindex", "Delete" buttons (NOT "Regenerate")
- [ ] **VERIFY**: Shows "Close" button (not "Back")
- [ ] Click "Close"
- [ ] **VERIFY**: Closes preview (no return to Memory Books)

---

### **6. Memory Books - Improved Prompts** (Commit 78be7ed)

**Test: New prompt presets**
- [ ] Open Memory Books → Generation Settings → Rules
- [ ] **VERIFY**: Shows 4 presets:
  - "Detailed beats (recommended)" — selected by default
  - "Concise narrative"
  - "Structured (markdown)"
  - "Minimal (1-2 sentences)"

**Test: Generated memory quality**
- [ ] Generate a draft with "Detailed beats" preset
- [ ] **VERIFY**: Content includes structured sections (Timeline, Story Beats, Key Interactions, etc.)
- [ ] **VERIFY**: Keywords are concrete (locations, objects, proper nouns) — NOT abstract themes
- [ ] **VERIFY**: 15-30 keywords generated
- [ ] **VERIFY**: Content excludes [OOC] conversation

**Test: Backward compatibility**
- [ ] Load existing chat with old memories created with old prompts
- [ ] **VERIFY**: Old memories still display correctly
- [ ] Generate new draft
- [ ] **VERIFY**: New draft uses new prompt format

---

## 🔍 Detailed Verification (30+ minutes)

### **Vector/Lorebook Deep Testing**

**Dual-channel retrieval**
- [ ] Create lorebook entry with both keys and vector search enabled
- [ ] Index the entry (click "Index Entry")
- [ ] Enable "Also use keyword matching" (should be default)
- [ ] Generate message matching BOTH keyword and vector
- [ ] **VERIFY**: Entry retrieved (shows in triggered lorebooks)
- [ ] **VERIFY**: Badge shows `[keyword]` (keyword has priority)

**Vector-only mode**
- [ ] Disable "Also use keyword matching"
- [ ] Generate message matching keyword (but not vector)
- [ ] **VERIFY**: Entry NOT retrieved (keyword scan skipped)
- [ ] Generate message matching vector
- [ ] **VERIFY**: Entry retrieved, shows `[vector]` badge

**Constant entry behavior**
- [ ] Enable "Constant" on an entry
- [ ] **VERIFY**: "Vector Search" checkbox becomes disabled
- [ ] **VERIFY**: vectorSearch flag set to false, embedding deleted

---

### **Tokenizer Deep Testing**

**Debounced recalculation**
- [ ] Open chat with many messages
- [ ] Delete 10 messages rapidly
- [ ] **VERIFY**: Context recalculation happens ONCE (not 10 times)
- [ ] Open Tokenizer
- [ ] **VERIFY**: Shows correct context breakdown

**Timeout handling**
- [ ] Configure API with invalid endpoint
- [ ] Open Tokenizer
- [ ] **VERIFY**: After 5-6 seconds shows error: "Context calculation is taking longer than expected. Please check that your API settings are configured correctly"

---

### **Memory Books Deep Testing**

**Pending trigger lifecycle**
- [ ] Enable auto-create (interval: 5, delayed mode ON)
- [ ] Send 5 messages (user → char → user → char → user)
- [ ] **VERIFY**: Messages 1-5 show PENDING badge
- [ ] Send char reply
- [ ] **VERIFY**: Still PENDING (waiting for delayed trigger)
- [ ] Send user message + char reply
- [ ] **VERIFY**: Draft created, PENDING badges removed

**Navigation stack**
- [ ] Open Memory Books → pending draft → preview
- [ ] Click "Back"
- [ ] **VERIFY**: Returns to Memory Books sheet
- [ ] Open approved entry → preview
- [ ] Click "Close"
- [ ] **VERIFY**: Closes preview (no return)

**Regenerate edge cases**
- [ ] Create draft from messages 10-20
- [ ] Delete message 15
- [ ] Open draft preview, click "Regenerate"
- [ ] **VERIFY**: Shows error "Cannot regenerate: messages not found" OR regenerates with remaining messages

**Prompt quality comparison**
- [ ] Generate draft with old chat (if available)
- [ ] Compare old vs new draft quality
- [ ] **VERIFY**: New drafts have:
  - More detailed structure (Timeline, Story Beats, etc.)
  - 15-30 concrete keywords (not abstract)
  - No [OOC] content
  - Better narrative flow

---

## 🚨 Known Limitations

**Not Fixed (Deferred):**
- ❌ Memory menu settings sync (main ↔ in-chat)
- ❌ Separate menus for injection types
- ❌ Universal "return to previous screen" navigation
- ❌ Memory Books temporary bottom-sheet UI (should be dedicated component)

**Intentional Design:**
- ✅ Constant + vectorSearch remain mutually exclusive
- ✅ Vector search checkbox disabled when constant=true

---

## 📊 Expected Results

**What should work:**
1. ✅ Keyword UI always visible (even with vectorSearch=true)
2. ✅ Retrieval badges show keyword/vector source
3. ✅ Optional keyword search flag works
4. ✅ Tokenizer opens quickly without errors
5. ✅ PENDING badges show messages awaiting auto-generation
6. ✅ Draft timer updates smoothly in real-time
7. ✅ Regenerate button works for drafts
8. ✅ Back navigation works for draft previews
9. ✅ Improved prompts generate better memories

**What might need adjustment:**
- Pending badge visibility on small screens
- Timer update performance on very slow devices
- Prompt quality for non-English content
- Keyword quality for very short scenes

---

## 🐛 If Something Breaks

**Tokenizer shows error:**
- Check API settings are configured
- Wait 5-6 seconds for timeout
- Check console for detailed errors

**PENDING badges don't appear:**
- Verify auto-create is enabled
- Check interval setting (must be > 0)
- Verify delayed mode setting
- Check console for automation errors

**Draft timer doesn't update:**
- Check if watch is triggering (console.log in watch)
- Verify element ID 'memory-draft-timer' exists in DOM
- Check browser console for errors

**Regenerate fails:**
- Verify messages still exist
- Check API settings
- Check console for generation errors

**Retrieval badges don't show:**
- Verify lorebook entries have `_source` property
- Check console for generationService errors
- Verify ChatMessage.vue received updated props

---

## ✅ Completion Criteria

**Minimum for merge:**
- [ ] All 6 Quick Verification tests pass
- [ ] No console errors during normal usage
- [ ] Build passes without errors
- [ ] Backward compatibility (old chats load correctly)

**Recommended before merge:**
- [ ] At least 2 Deep Testing sections completed
- [ ] Tested on both mobile and desktop layouts
- [ ] Generated at least 3 memory drafts with new prompts
- [ ] Verified dual-channel lorebook retrieval works

---

**Status**: Ready for testing  
**Time estimate**: 15-45 minutes depending on depth
