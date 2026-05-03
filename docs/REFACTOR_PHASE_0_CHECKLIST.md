# Refactor Phase 0 Checklist

## Purpose

This document defines the safety baseline for the architecture refactor.

Phase 0 exists to answer one question before moving code around:

**What must remain true so the refactor does not silently break the app?**

This file should be used before and during every structural refactor PR.

---

## Current Delivery Strategy

The current working strategy is:

1. fix urgent bugs first on a dedicated bugfix branch;
2. keep those fixes minimal and user-facing;
3. only after stabilization, create a dedicated refactor branch;
4. branch the refactor work from the stabilized bugfix branch if the refactor depends on those fixes.

This is intentional.

The project has repeatedly shown that request lifecycle bugs, mobile/runtime quirks, and MemoryBooks behavior can produce false signals during architecture work. If those remain unstable, refactor work becomes harder to verify.

---

## Branch Strategy

### Immediate branch policy

- `dev` stays clean and synced with `upstream/dev`
- urgent fixes go to a dedicated bugfix branch
- the architecture refactor gets its own branch later
- if the refactor depends on the bugfixes, branch the refactor from the bugfix branch

### Recommended sequence

1. Create bugfix branch from `origin/dev`
2. Land urgent lifecycle / persistence / runtime fixes there
3. Verify build and relevant tests
4. Keep commits narrow and grouped by bug cluster
5. Create refactor branch from the stabilized bugfix branch
6. Start Phase 1 only after the bugfix branch behavior is trusted

### Why this order matters

If urgent runtime bugs remain open while refactoring:

- it becomes unclear whether a regression is new or pre-existing;
- race-condition bugs look like architecture bugs;
- architecture cleanup may accidentally hide or reintroduce the original issue;
- prompt behavior becomes harder to compare.

---

## Refactor Invariants

These invariants must hold through all architecture phases unless a change is explicit, documented, and tested.

### A. Request Ownership Invariants

- A completed request must only be allowed to mutate the generation state it owns.
- An aborted or superseded request must not apply late results to a newer active generation.
- Chat generation and MemoryBooks draft generation must not share ambiguous request ownership.
- Starting a new chat generation must not leave the old request able to finalize the new UI state.
- Abort must have one clear owner and one clear effect path.

### B. Prompt Semantics Invariants

- Prompt block ordering must not change accidentally.
- Macro application order must not change accidentally.
- Regex application order must not change accidentally.
- Keyword lore scan semantics must remain equivalent unless explicitly changed.
- Vector enrichment must remain outside the worker unless intentionally redesigned.
- Memory injection timing and placement must not drift silently.
- Final provider payload meaning must stay equivalent even if payload assembly code moves.

### C. Transport Behavior Invariants

- Streaming and non-streaming paths must remain behaviorally equivalent at the user level.
- Native/mobile fallback for missing readable stream bodies must keep working.
- Timeout behavior must remain explicit and must not leave phantom active generations.
- User abort may preserve partial text only where that is already intended.
- Late provider completion must not outlive request ownership rules.

### D. UI State Invariants

- Active generation UI must reflect the real active request only.
- Placeholder lifecycle must remain consistent across success, error, abort, and restore.
- Settings toggles must not reset due to unrelated view or preset updates.
- Debug and preview UI must not affect generation success.
- `Force Mobile Layout` and battery-saver UI rules must not become re-coupled.

### E. Persistence Invariants

- Existing localStorage settings must continue to load correctly.
- API runtime config helpers must remain backward-compatible with current keys during migration.
- MemoryBooks settings must not be reset by reopen/save/default paths.
- Request debug storage must stay optional.
- Any new keyed debug store must not remove existing visibility before parity is proven.

### F. Domain Boundary Invariants

- `ChatView.vue` may get thinner, but chat behavior must remain equivalent.
- `generationService.js` may shrink, but request semantics must remain equivalent.
- `llmApi.js` may become a compatibility shell, but transport outcomes must remain equivalent.
- Event hubs and adapters must not become hidden orchestration layers.
- Reactive state modules must remain consumers of domain results, not a dumping ground for arbitrary cross-cutting behavior.

---

## Anti-Regression Rules

### Rule 1. No mixed-purpose refactor PRs

Do not combine architecture movement with unrelated behavior changes in the same PR.

Bad combinations:

- request ownership fix + provider feature
- event hub introduction + MemoryBooks automation redesign
- transport cleanup + prompt semantics tweak
- debug store cleanup + lore/vector behavior change

### Rule 2. Structural changes must preserve runtime truth

If code moves from one file to another, the new location must preserve:

- ownership;
- ordering;
- timing assumptions;
- fallback paths;
- error policy.

### Rule 3. Preserve compatibility shims until parity is proven

Allowed temporary shims:

- facade calls from old services into new use cases;
- callback adapters around normalized transport results;
- legacy config readers delegating to shared helpers.

### Rule 4. No silent prompt changes during structure-only work

If a PR claims to be architectural only, it should not change:

- prompt content meaning;
- injection ordering;
- block placement semantics;
- request options behavior.

If it does, that must be called out explicitly as behavior change.

### Rule 5. Always protect against stale completion

Any refactor that touches generation lifecycle must re-check:

- abort path;
- regenerate path;
- long request path;
- multiple request overlap;
- chat vs memory-draft concurrency.

---

## Smoke Test Matrix

This matrix is the minimum manual verification baseline after structural changes in generation architecture.

### 1. Chat Generation

- Start normal streaming chat generation
- Stop generation manually
- Regenerate immediately after abort
- Let a long request run to completion
- Trigger an error path and verify cleanup
- Verify no phantom typing or stuck active generation remains

### 2. Streaming Fallback / Mobile Risk Paths

- Verify generation still completes when stream body is unavailable
- Verify UI remains coherent in one-shot fallback mode
- Verify native/mobile request still succeeds on the fallback path
- Verify long request does not silently outlive UI ownership

### 3. Memory Draft Separation

- Start chat generation and verify MemoryBooks draft flow does not steal ownership
- Run memory draft generation and verify it does not interrupt chat state incorrectly
- Verify memory draft error is surfaced clearly
- Verify active-draft cleanup does not remain stuck

### 4. Settings Persistence

- Verify `show reasoning` persists after reopen/navigation
- Verify MemoryBooks auto-generation persists
- Verify MemoryBooks prompt settings persist
- Verify MemoryBooks injection target persists
- Verify no preset apply path silently overwrites user runtime toggle state

### 5. Lore / Memory Injection

- Verify lorebook `Max Injected Entries` still caps final prompt injection
- Verify `scan depth` behavior is unchanged unless intentionally modified
- Verify `{{lorebooks}}` target scoping still behaves correctly
- Verify memory injection still respects `summary_block` vs `summary_macro`
- Verify triggered memories/lore remain inspectable in UI where expected

### 6. Debug / Preview Safety

- Verify request preview still shows the built payload
- Verify debug trace capture remains optional
- Verify disabling trace capture does not alter generation success
- Verify summary or memory-draft diagnostics do not corrupt chat debug visibility unexpectedly

### 7. Desktop / Mobile Layout Guardrails

- Desktop with `Battery Saver UI = OFF`
- Desktop with `Battery Saver UI = ON`
- Desktop with `Force Mobile Layout = ON`, `Battery Saver UI = OFF`
- Desktop with `Force Mobile Layout = ON`, `Battery Saver UI = ON`
- Verify timer/render guardrails follow battery-saver rules, not layout-only rules

---

## Suggested Verification Levels By PR Type

### For bugfix PRs touching lifecycle or generation

Minimum:

- `npm test -- --run`
- `npm run build`
- manual chat generation smoke check
- manual abort/regenerate smoke check

### For structural refactor PRs touching use cases or transport

Minimum:

- `npm test -- --run`
- `npm run build`
- manual chat generation smoke check
- manual abort/regenerate smoke check
- manual fallback/mobile risk-path check if relevant code changed
- request preview/debug sanity check if relevant code changed

### For structural PRs touching MemoryBooks or injection paths

Minimum:

- `npm test -- --run`
- `npm run build`
- manual chat generation smoke check
- manual memory draft separation check
- manual lore/memory injection check
- manual persistence check for changed settings

---

## First Refactor Targets After Bugfixes

Once urgent bugs are stabilized, the recommended first refactor targets are:

1. request ownership token model
2. explicit `generateChat` use-case boundary
3. internal event hub plus event catalog
4. separation of prompt preview from network trace singleton state

This order is deliberate.

It addresses:

- correctness first;
- ownership second;
- architecture boundaries third;
- extensibility after that.

---

## Files To Watch Closely During Refactor

High-risk files:

- `src/views/ChatView.vue`
- `src/core/services/generationService.js`
- `src/core/services/llmApi.js`
- `src/composables/chat/useGenerationStateSetup.js`
- `src/composables/chat/useGenerationCompleteHandler.js`
- `src/composables/chat/useGenerationStateRestore.js`
- `src/composables/chat/useGenerationErrorHandler.js`
- `src/views/ApiView.vue`
- `src/views/PresetView.vue`

High-risk domains:

- request ownership and stale completion
- abort semantics
- stream/fallback parity
- MemoryBooks draft overlap with chat generation
- persistence ownership for runtime settings
- debug state leakage across request types

---

## Definition Of "Safe To Start Phase 1"

The project is ready to start Phase 1 refactor work when all of the following are true:

- urgent user-facing lifecycle bugs have been triaged or fixed on the bugfix branch;
- the current branch behavior is trusted enough to serve as a comparison baseline;
- build passes;
- core automated tests pass;
- the invariants in this document are understood and accepted as migration guardrails;
- the next refactor step is small enough to review as structure-first work.

---

## Final Rule

If a proposed cleanup makes the code look nicer but makes ownership, ordering, or failure handling harder to reason about, it is not safe enough yet.

Correctness and recoverability come before architectural neatness.
