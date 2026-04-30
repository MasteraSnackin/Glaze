# Known Gaps & Deferred Items

Current architectural problems and intentionally deferred refactoring items.

## Current Design Problems

### ChatView.vue is a large composable-wiring surface

~1390 script lines. Known exception to the 400-line guard rail. Further extraction would cause prop-drilling (30+ shared dependencies). `openChat()` (~400 lines) remains due to high dependency count. This is accepted as permanent tech debt.

### Runtime config has multiple owners

`localStorage`, IndexedDB API presets, reactive `ApiView.vue` state, onboarding writes, and direct reads in feature views all mutate API config. No single boundary controls reads/writes.

### Worker/service boundary not clearly documented

Keyword lore lives in the worker, vector retrieval and memory injection happen later in the service layer. The boundary is functional but not documented as a contract.

### Callback signatures flexible but brittle

Chat, summary, and memory-draft flows share callback shapes (`onUpdate`, `onComplete`, `onError`) but each flow adds subtle differences. This makes adding new request types error-prone.

## Deferred Refactoring Items

### `ChatView.vue` — `openChat()` extraction (~400 lines inline)

- **Status:** Deferred
- **Reason:** ~30+ dependency injections. Extracting would create massive parameter list with no architectural gain. ChatView is already a composable-wiring shell.
- **Revisit if:** A new feature requires testing `openChat()` in isolation, or the function grows significantly.

### `themeState.js` (639 lines) — State ≠ service violation

- **Status:** Deferred (next refactor pass)
- **Problem:** Violates Guard Rail #3. Mixes reactive state + setters (~300 lines, correct) with preset CRUD orchestration (~340 lines, should be a service).
- **Proposed fix:** Extract preset orchestration into `themePresetService.js`. `themeState.js` retains only reactive + setter functions (~300 lines).
- **Risk:** Low — preset functions already delegate to `themePersistence.js`, `themeMigration.js`, `themeRenderer.js`.

### `useMemorySheetUI.js` (844 lines) — imperative DOM anti-pattern

- **Status:** Do not refactor
- **Reason:** ~600 of 844 lines are `document.createElement` + `innerHTML` + `querySelector` + `addEventListener`. This is a fundamental DOM approach problem, not a concern-mixing problem. Splitting would scatter imperative DOM code across more files. The only meaningful refactoring would be rewriting innerHTML sheets as Vue components — large UI rewrite with zero architectural payoff.
- **Revisit if:** A decision is made to rewrite the memory sheet UI as proper Vue template components.

## Dead Code

### Dead event subscriptions (5 events with listeners but no dispatches)

- `header-setup-generation` — AppHeader + App subscribe, no source dispatches
- `header-update-session` — AppHeader subscribes, no source dispatches
- `change-generation-tab` — AppHeader subscribes, no source dispatches
- `open-item-editor` — App subscribes, no source dispatches
- `open-holocards` — HoloCardViewer subscribes, no source dispatches

Not removed to avoid breaking changes if dispatches are added dynamically. Should be cleaned up in a future pass.

## UI Leak Sites Remaining (from Phase 11)

- `generationService.js` imports `translations`/`currentLang` (i18n) and `showBottomSheet`/`closeBottomSheet` (UI state) — these should become callback-style dep injection or event-driven.
- `pipeline/steps.js` `stepContextLimitGuard` receives `showBottomSheet`/`closeBottomSheet` as deps — UI notification from pipeline step.
