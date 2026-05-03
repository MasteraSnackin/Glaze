# Database Rules

Rules for all code that reads from or writes to IndexedDB.

## patchChatData for read-mutate-write

NEVER:
```javascript
const data = await db.getChat(charId);
data.messages.push(newMsg);
await db.saveChat(charId, data);
```

ALWAYS:
```javascript
await patchChatData(charId, draft => {
  draft.messages.push(newMsg);
});
```

`patchChatData` serializes read-mutate-write via `queueDbWrite`. Two concurrent saves WILL corrupt data without it.

## Save before state cleanup

When finalizing a generation, persist data to DB BEFORE clearing reactive state. If you clear state first and the save fails, data is lost.

## Crash recovery buffer

`useSessionPersistence.js` writes a crash buffer to `localStorage` on `visibilitychange`, `pagehide`, and `beforeunload`. On `openChat()`, if crash buffer has more messages than stored session, buffer is restored to IndexedDB.

Key format: `gz_chat_recovery_{charId}_{sessionId}`

## Background persistence throttling

During active generation, stream text is persisted to DB at reduced frequency:
- Web: moderate throttle
- Native / battery-saver: aggressive throttle

This reduces IndexedDB churn while ensuring no data loss on crash.

## Embedding storage

Store: `embeddings`
Schema v8: `{ id, sourceType, sourceId, vectors[], textHash, retrievalHints, updatedAt }`

Legacy support: single `vector` field for pre-v8 entries.
