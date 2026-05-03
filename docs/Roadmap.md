# Roadmap

Active work and upcoming tasks. Historical items are removed once merged.

## Active Branch

`fix/inline-image-edit-bg-gen-db-crash-streaming` (linear chain from `fix/preset-token-discrepancy`)

## Bug Investigations (2026-05-03)

Status: `research complete`, implementation `not started`

### 1. Inline Image Edit During Generation

**Bug**: User edits a message while an inline image is generating — in-flight `processMessageImages` overwrites the edit with stale content.

**Root Cause**: No abort/cancel mechanism for `processMessageImages`. The `onUpdate` callback retains a closure over `msg` and directly mutates `msg.text` + calls `updateSessionMessage()`. When `saveEdit()` writes the edited text, the still-running `processMessageImages` overwrites it with old content + loading/result HTML.

**Key Files**:
- `src/core/services/imageGenService.js` — `processMessageImages()` (line 781), `fetchWithTimeout()` (line 54, 5-min timeout, no external abort)
- `src/composables/chat/useGenerationCompleteHandler.js` — `onUpdate` callback (line 233-250)
- `src/composables/chat/useMessageActions.js` — `saveEdit()` triggers second `processMessageImages` (line 419-432)
- `src/core/utils/messageEditHelpers.js` — `normalizeImgGenHtmlForEditing`, `prepareEditText`, `restoreEditText`

**Architecture Gap**: No centralized tracking of in-flight image generations. `generationStates` registry only tracks LLM text generation, not image generation. No way to check "is an image currently being generated for this message?" or cancel all image generation for a character.

**Identified Race Conditions**:
1. **Stale onUpdate overwrites edits** (HIGH) — in-flight `processMessageImages` overwrites `msg.text` saved by `saveEdit()`
2. **Double processMessageImages** (MEDIUM) — `saveEdit` + still-running original both modify `msg.text` concurrently
3. **handleImageRegenerate stale currentMessages** (MEDIUM) — reads `currentMessages.value[msgIndex]` snapshot that may be outdated after edit
4. **onVisibilityChange saves imggen-loading** (MEDIUM) — loading states persisted to DB; on reload, may cause duplicate generation

**Proposed Fix Direction**:
- Add abort signal to `processMessageImages` — pass `AbortController` from generation state
- Track in-flight image generations in a registry (similar to `generationStates`)
- On `enterEditMode`: abort any in-flight image generation for that message
- On `saveEdit`: cancel old generation before starting new `processMessageImages`
- On `handleImageRegenerate`: verify message ID before writing back

**Rules Compliance**:
- **generation.md**: Image gen is NOT in `generationStates` — fix must NOT add it there (violates INV-M1-style separation). Create separate `imageGenStates` registry. Abort signal chain must NOT be broken. Partial image on abort must NOT corrupt `msg.text`.
- **race-conditions.md**: Rule 1 — verify ownership after await in `processMessageImages`. Rule 2 — `onUpdate` MUST check ownership before mutating `msg.text` (currently no check = root cause). Rule 3 — concurrent writes from `saveEdit` + `processMessageImages` must use `patchChatData`. Rule 4 — new abort boundary needs stale guards.
- **database.md**: `saveEdit` + `processMessageImages` both write to DB concurrently — must serialize via `patchChatData`. Save before state cleanup.
- **INVARIANTS.md**: INV-C2 — image gen cleanup guaranteed on every exit path. INV-C6 — fix must not break background LLM generation.

### 2. Background Inline Image Generation

**Bug**: Inline image generation does NOT continue in background when user navigates away from ChatView.

**Root Cause**: `ChatView.onUnmounted()` aborts ALL active generations via `state.controller.abort()`. `processMessageImages` uses its own `fetchWithTimeout()` with a separate `AbortController` (timeout-based only). No connection between generation's `AbortController` and image generation's `fetchWithTimeout`.

**Key Files**:
- `src/views/ChatView.vue` — `onUnmounted()` (line 1466-1501) aborts all controllers
- `src/core/services/imageGenService.js` — `fetchWithTimeout()` (line 54-60)
- `src/composables/chat/useGenerationCompleteHandler.js` — background path (line 277-345)
- `src/composables/chat/useSessionPersistence.js` — `onVisibilityChange` (line 145-181)

**Proposed Fix Direction**:
- Separate image generation lifecycle from ChatView component lifecycle
- Image generation should continue after ChatView unmount — API calls are already independent (own `fetchWithTimeout`)
- The `handleGenerationComplete` background path already handles DB writes for non-visible characters
- Ensure `processMessageImages` is called in the background path even after ChatView unmount
- Move image generation orchestration to service-level module

**Rules Compliance**:
- **generation.md**: INV-C6 violated for image gen. Image gen lifecycle must be decoupled from component lifecycle.
- **race-conditions.md**: Rule 1 — after `await fetchWithTimeout()`, check mount/message state before UI update. Rule 2 — background DB writes must verify ownership. Rule 5 — image gen and LLM gen are NOT mutually exclusive, do NOT add mutual exclusion.
- **vue-components.md**: Moving orchestration to `imageGenService.js` is correct — keeps lifecycle independent of component mount.
- **database.md**: Background persistence via `patchChatData`. Crash recovery buffer must capture in-progress image gen state.

### 3. Database Crash After RegexSheet Operations

**Bug**: App's database may crash after operations in RegexSheet.

**Investigation Findings**: No direct crash-to-corruption path found, but several vectors:

**HIGH Risk**:
1. **`trimOut` used as raw regex without escaping** (`regexService.js:96-103`) — User input like `[`, `(` causes `SyntaxError` in `new RegExp()`. Caught by try/catch but silently fails.
2. **Cloud sync overwrites global `regex_scripts` with no merge** (`syncEngine.js:468`) — Data loss on sync.
3. **Cloud sync regex merge is ID-based only** (`syncEngine.js:457-459`) — Modified local regexes with same ID overwritten.

**MEDIUM Risk**:
4. **`scripts.value` loaded once, never refreshed** (`RegexSheet.vue:51-61`) — Stale data after external modification.
5. **DragDropOverlay preset import doesn't publish `regexScriptsChanged`** (`DragDropOverlay.vue:121-134`)
6. **TavoBackupReader uses wrong field name** (`tavoBackupReader.js:389`) — `substituteRegex` instead of `macroRules`.
7. **DragDropOverlay `trimStrings.join('\\n')` double-escapes newline** (`DragDropOverlay.vue:106`)
8. **`Date.now().toString()` as ID can collide** (`RegexSheet.vue:126`)

**Proposed Fix Direction**:
- Escape `trimOut` tokens before using as regex, or use string replacement
- Add regex merge for `regex_scripts` in syncEngine
- Reload `scripts.value` on `regexScriptsChanged` event
- Fix DragDropOverlay to publish event for preset regex imports
- Fix tavoBackupReader field name mapping
- Use `Date.now().toString(36) + Math.random().toString(36).slice(2)` for IDs

**Rules Compliance**:
- **race-conditions.md**: Rule 3 — sync engine overwrite is read-mutate-write race, must use merge. Rule 4 — RegexSheet stale data needs stale guard on sync event. Rule 5 — sync + user edit concurrent, need merge resolution.
- **vue-components.md**: Reload on `regexScriptsChanged` via `subscribeAppEvent`, NOT `window.dispatchEvent`.
- **database.md**: Regex scripts in `localStorage` but sync treats as syncable entity — fix must handle both backends.
- **INVARIANTS.md**: INV-PS7 — regex application order must stay deterministic after `trimOut` fix.

### 4. Streaming Lost When Leaving ChatView

**Bug**: Streaming is lost when user navigates away from ChatView during active generation.

**Root Cause**: `ChatView.onUnmounted()` **immediately aborts every active generation** by calling `state.controller.abort()`. This kills the HTTP fetch connection. Background infrastructure exists but is bypassed.

Additionally:
- `onUnmounted()` does NOT set `state.userAborted = true` — abort is misrouted
- `clearGenerationState(charId)` runs synchronously, deleting registry entry before abort propagates asynchronously
- `closeChat()` runs before `onUnmounted()`, clearing `currentMessages` and `activeChatChar`

**Key Files**:
- `src/views/ChatView.vue` — `onUnmounted()` (line 1466-1501), `closeChat()` (line 1086-1110)
- `src/core/states/generationState.js` — global generation registry
- `src/composables/chat/useGenerationStreamUpdate.js` — background DB update path (line 27-64)
- `src/composables/chat/useGenerationCompleteHandler.js` — background completion path (line 277-346)
- `src/composables/chat/useGenerationAbort.js` — proper abort with `userAborted` flag (line 23-26)
- `src/core/llm/transport/requestOutcome.js` — `handleAbortOutcome` (line 120)
- `docs/rules/generation.md:89` — explicitly states "Character switch during generation continues background generation"

**The Intended Design vs Reality**:
- **Design** (per `docs/rules/generation.md:89`): "Character switch during generation continues background generation"
- **Reality**: `onUnmounted()` aborts all generations, making background path unreachable
- Background infrastructure EXISTS: `useGenerationStreamUpdate` writes to DB when `onUIUpdate` is null; `handleGenerationComplete` has full background path with DB save + notification + unread marker

**Proposed Fix Direction**:
- On ChatView unmount / character switch: do NOT abort generation — disconnect UI callbacks, let generation continue in background
- Set `state.onUIUpdate = null` to route stream updates through background DB path
- Keep `generationStates` entry alive so completion handler can find it
- Only abort on explicit user action (stop button) or app background (visibilitychange)
- Set `state.userAborted` flag properly on explicit abort only
- Ensure `backgroundUpdateTimer` is cleaned up when generation completes in background

**Rules Compliance**:
- **generation.md**: Line 88 — primary invariant being restored. Abort signal chain — must NOT abort controller on unmount. genId ownership — background path must verify genId before DB writes. State cleanup — `clearGenerationState` must NOT run on unmount if generation active. Abort path delegation — `onUnmounted` must NOT call `clearGenerationState` directly for background path.
- **race-conditions.md**: Rule 1 — background `handleGenerationComplete` after await must check genId. Rule 2 — `onUIUpdate = null` means no reactive mutation. Rule 3 — background DB writes via `patchChatData`. Rule 4 — new async boundary after unmount requires stale guards.
- **database.md**: Background persistence via `useGenerationStreamUpdate` throttled writes — must be active when `onUIUpdate = null`. Crash recovery buffer must capture streaming state. Save before state cleanup.
- **INVARIANTS.md**: INV-C2 — background gen MUST still call `clearGenerationState` on eventual completion (fix changes WHEN, not WHETHER). INV-C4 — `isGenerating` must stay `true` until background completion. INV-C6 — invariant being RESTORED. INV-C7 — background completion must check genId. INV-A1 — explicit abort still propagates through all layers; component unmount must NOT send signal. INV-A4 — abort restore only on explicit user abort, not background transition.

### Implementation Priority

1. **Streaming lost on leave** — highest impact, restores INV-C6 invariant already documented in rules
2. **Inline image edit during generation** — data loss risk (edits overwritten), needs new `imageGenStates` registry
3. **Background inline image gen** — UX improvement, depends on fix #1 architecture
4. **RegexSheet DB crash** — multiple medium-severity issues, no single catastrophic bug found

## Sync Setup Guide — For Developers

### Maintainer Goal

- **Status:** done
- **Testing:** not tested
- After merge, the maintainer should only need to add OAuth app keys to `.env`.
- End users still authenticate into their **own** Dropbox or Google Drive accounts. Glaze does not sync everyone into one shared maintainer-owned cloud.
- Provider buttons are only shown when the corresponding OAuth env key is present in the build.

### Shortest Setup Path

1. Copy `.env.example` to `.env` if needed.
2. Add `VITE_DROPBOX_APP_KEY=...`.
3. Register the Dropbox redirect URIs listed below.
4. Build and ship.

That is the shortest maintainer path. Google Drive remains available, but it needs its own OAuth client configuration and is not required for cloud sync to work.

### Platform Status

- **Windows (Electron):** done / not tested
- **Linux (Electron):** done / not tested
- **Android (Capacitor):** done / not tested
- **iPhone (Capacitor iOS):** done / not tested

Meaning: the repo now contains callback plumbing for desktop loopback OAuth and mobile deep-link OAuth, but provider sign-in still needs manual verification against real Dropbox / Google OAuth apps.

### How Cloud Sync Works

Glaze syncs data to cloud storage (Dropbox or Google Drive) using an incremental manifest-based approach:
1. **Manifest** (`manifest.json`) tracks every entity with `{type, id, path, updatedAt, hash, deleted}`
2. **Push**: Compare local manifest vs cloud manifest → upload only changed entities
3. **Pull**: Compare cloud manifest vs local manifest → download only newer entities
4. **Conflicts**: If local is newer AND cloud is newer → surface conflict for manual resolution

### Auth Model

1. Maintainer configures the app-level OAuth client IDs/keys in `.env`.
2. User taps a provider in the Sync sheet.
3. The provider OAuth flow returns tokens for **that specific user account**.
4. Tokens are stored locally on the device.
5. Sync uploads into that user's own cloud storage under `/Glaze`.

This means maintainer credentials only identify the Glaze OAuth app. They do not decide where user data is stored.

### Platform Setup

#### 1. Dropbox

**Create a Dropbox App:**
1. Go to https://www.dropbox.com/developers/apps
2. Click "Create app" → choose "Scoped access" → "Full Dropbox" (or "App folder" if preferred)
3. Note your **App key**

**Configure OAuth redirect URIs:**
- In the Dropbox App Console → Settings → OAuth 2 → Redirect URIs
- Add ALL redirect URIs you will use:
  - **Native (Android/iOS)**: `com.hydall.glaze://oauth/dropbox`
  - **Web (production)**: `https://yourdomain.com/oauth/dropbox/redirect.html`
  - **Web (dev)**: `http://localhost:5173/oauth/dropbox/redirect.html`
  - **Electron (desktop)**: `http://127.0.0.1:PORT/oauth/callback` (loopback)

**Environment variables (`.env`):**
```
VITE_DROPBOX_APP_KEY=your_app_key_here
# Optional overrides (defaults shown):
# VITE_DROPBOX_REDIRECT_NATIVE=com.hydall.glaze://oauth/dropbox
# VITE_DROPBOX_REDIRECT_WEB=https://yourdomain.com/oauth/dropbox/redirect.html
```

**Android/iOS config:**
- Ensure `capacitor.config.json` has `"appId": "com.hydall.glaze"` (must match redirect URI scheme)
- For Android: `android/app/src/main/AndroidManifest.xml` now contains a `VIEW` / `BROWSABLE` intent-filter for `com.hydall.glaze://`
- For iOS: `ios/App/App/Info.plist` now registers `CFBundleURLTypes` for `com.hydall.glaze`, and `ios/App/App/AppDelegate.swift` forwards the callback to Capacitor

#### 2. Google Drive

**Create a Google Cloud project:**
1. Go to https://console.cloud.google.com
2. Create a project → Enable Google Drive API
3. Go to "Credentials" → "Create OAuth client ID" → "Web application"
4. Note your **Client ID**

**Configure redirect URIs:**
- In Google Cloud Console → Credentials → your OAuth client → "Authorized redirect URIs"
- Add ALL redirect URIs:
  - **Native (Android/iOS)**: `com.hydall.glaze://oauth/gdrive`
  - **Web (production)**: `https://yourdomain.com/oauth/gdrive/redirect.html`
  - **Web (dev)**: `http://localhost:5173/oauth/gdrive/redirect.html`
  - **Electron (desktop)**: `http://127.0.0.1:PORT/oauth/callback` (loopback)

**Environment variables (`.env`):**
```
VITE_GDRIVE_CLIENT_ID=your_client_id_here
# Optional overrides:
# VITE_GDRIVE_REDIRECT_NATIVE=com.hydall.glaze://oauth/gdrive
# VITE_GDRIVE_REDIRECT_WEB=https://yourdomain.com/oauth/gdrive/redirect.html
```

Glaze uses OAuth PKCE in the client, so `VITE_GDRIVE_CLIENT_SECRET` is intentionally not used.

### Error 400 Troubleshooting

**Error 400 on OAuth token exchange** = `redirect_uri` mismatch.

The `redirect_uri` sent in the OAuth authorize request must **exactly match** the `redirect_uri` sent in the token exchange request AND must be registered in the provider's OAuth console.

Common causes:
1. **Hardcoded localhost in production**: Old code used `http://localhost:5173/...` — this only works in dev. Fixed: now uses `window.location.origin` as default.
2. **Missing redirect URI in OAuth console**: The URI you deploy with must be added to the app's redirect URI list in Dropbox/Google console.
3. **Platform mismatch**: Native builds use `com.hydall.glaze://...` scheme. Web builds use `https://...`. Each platform needs its own redirect URI registered.
4. **Port mismatch for Electron**: Electron uses loopback `http://127.0.0.1:PORT/oauth/callback` with a random port. The OAuth provider must allow loopback redirects (Google does by default for "Desktop app" client type; Dropbox requires adding it explicitly).

### Error 401/403 Troubleshooting

- **401**: Access token expired → auto-refresh via `refresh_token`. If refresh also fails → user must reconnect.
- **403**: App permissions revoked or API quota exceeded. User must reconnect.

### Encryption (Optional)

Encryption uses AES-256-GCM via Web Crypto API, key derived from a 12-word BIP39 mnemonic.
- **Without encryption**: Data stored as plain JSON in cloud. Simple, portable, debuggable.
- **With encryption**: Each entity encrypted before upload. Recovery phrase required to decrypt on other devices.
- **Migration**: If cloud has `.enc` files and encryption is disabled, the system attempts to read both `.enc` and `.json` variants.
- **Key files**: `src/core/services/crypto/syncCrypto.js` (AES-GCM), `src/core/services/crypto/keyManager.js` (BIP39, storage)
