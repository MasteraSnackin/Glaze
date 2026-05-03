# Glaze

Mobile-first LLM frontend for AI roleplay. SillyTavern alternative as a native mobile app.
**Stack:** Vue 3.5 + Vite 7 + Capacitor 8 (iOS/Android). **Language:** JavaScript only. **License:** AGPL-3.0.

Full architecture audit: `ARCHITECTURE.md`. Refactor plan: `docs/REFACTOR_PLAN.md`. Roadmap: `docs/Roadmap.md`.

## Git Workflow

- **All PRs target `upstream/dev`, never `main`.**
- When creating a PR with `gh pr create`, always use `--base dev`.
- See `AGENTS.md` for detailed branch hygiene rules.

## Commands

```bash
npm run dev          # Dev server
npm run build        # Production build
npm test             # Vitest unit tests
npm run test:ui      # Tests with UI

# Mobile
npm run build && npx cap sync android && npx cap open android
npm run build && npx cap sync ios && npx cap open ios
```

## Code Conventions

### Vue Components
- **Composition API with `<script setup>` only** — no Options API anywhere
- **JavaScript only** — no TypeScript
- Props via `defineProps()`, emits via `defineEmits()`
- Heavy views loaded with `defineAsyncComponent()` to reduce initial bundle

### State Management
- **No Pinia, no Vuex** — custom reactive state modules in `src/core/states/`
- Each module exports `ref()`, `reactive()`, `computed()` values and mutation functions
- State modules are imported directly where needed (no global store instance)

### Services
- **Functional** — exported async functions, no classes
- Located in `src/core/services/`

### Navigation
- **No Vue Router** — custom view switching via `currentView` ref in App.vue
- Cross-component communication uses `publishAppEvent()` / `subscribeAppEvent()` from `src/core/events/eventHub.js`

### File Naming
| Type | Convention | Example |
|------|-----------|---------|
| Components/Views | PascalCase | `ChatView.vue`, `AppHeader.vue` |
| Services | camelCase | `generationService.js`, `llmApi.js` |
| States | camelCase + State | `presetState.js`, `lorebookState.js` |
| Composables | use + PascalCase | `useVirtualScroll.js`, `useViewer.js` |
| Utils | camelCase | `db.js`, `macroEngine.js` |

### CSS
- Scoped `<style>` blocks (no CSS modules, no preprocessor)
- CSS custom properties for theming (`--header-height`, `--vk-blue`, `--element-opacity`, etc.)
- Light/dark themes via `body.dark-theme` class

## Storage

| Data | Backend | Key Pattern |
|------|---------|-------------|
| Characters | IndexedDB `characters` store | by `id` |
| Personas | IndexedDB `personas` store | by `id` |
| Chats | IndexedDB `keyvalue` store | `gz_chat_{charId}` |
| Lorebooks | IndexedDB `keyvalue` store | `gz_lorebooks` |
| Presets | localStorage | `silly_cradle_presets` |
| API config | localStorage | `api-*`, `gz_api_*` |
| Regex scripts | localStorage | `regex_scripts` |
| App settings | localStorage | `gz_*` |
| Session vars | localStorage | `gz_vars_{charId}_{sessionId}` |

## Context-Sensitive Rules

When editing files matching a pattern below, READ the corresponding rule file FIRST and apply those rules:

| When editing... | Read this |
|----------------|-----------|
| Generation, transport, streaming, abort, use-cases | `docs/rules/generation.md` |
| Any async boundary, callbacks from transport, DB writes | `docs/rules/race-conditions.md` |
| Vue components, composables, state modules | `docs/rules/vue-components.md` |
| IndexedDB reads/writes, `db.js`, `patchChatData` | `docs/rules/database.md` |
| Architecture details, directory structure, full flow | `ARCHITECTURE.md` |
| Formal invariants with code references | `docs/INVARIANTS.md` |

## Do NOT

- Add TypeScript
- Add Pinia or Vuex
- Add Vue Router
- Use Options API
- Use classes for services or state modules
- Commit `.env` files, API keys, or user data
- Import heavy dependencies without lazy loading
- Use WebSocket for LLM streaming (SSE only)
- Break SillyTavern V2 format compatibility for character cards
- Use `window.dispatchEvent` / `window.addEventListener` for app events — use `publishAppEvent` / `subscribeAppEvent` instead
- **Read, display, or output contents of `.env` file** — it contains secrets
