# Непротестированные задачи (Untested Tasks)

Документ сгенерирован: 2026-04-17

Всего задач с `not tested`: **188**

## Категории

### 1. Memory Books (Меморибуки) — 76 задач

#### Реализовано, но не протестировано (`done | not tested`):

**Data Model & Persistence (Модель данных)**
- Cloud sync integration exists (PR #20) — интеграция с облачной синхронизацией
- Dedicated memory book container per chat/session — отдельный контейнер памяти для каждого чата
- Memory entry schema with message ownership metadata — схема записей с привязкой к сообщениям
- Deterministic IDs for imports/sync merges — стабильные ID для импорта/синхронизации
- Stable message IDs + timestamps — стабильные ID сообщений + временные метки
- DB migration/persistence support — миграция БД и сохранение данных

**Lifecycle Maintenance (Управление жизненным циклом)**
- Message deletion detection → mark/rebuild stale memories — обнаружение удаления сообщений
- Chat branching reconciliation — согласование при ветвлении чата
- Copy only fully preserved memory ranges on branch — копирование только полных диапазонов
- Partial survival → mark as `needs_rebuild` — частичное сохранение → пометить для перестроения
- Orphaned entries removal on branch — удаление осиротевших записей

**Retrieval & Injection (Поиск и инжект)**
- Vector indexing/search via `sourceType: 'memory_entry'` — векторный поиск для памяти
- Support vectors, keys, Glaze keys activation — поддержка векторов, ключей, Glaze ключей
- Separate memory activation limits from lorebooks — отдельные лимиты активации от лорбуков
- Inject into summary block path (not lorebook path) — инжект в summary block (не в lorebook)
- Separate memory context accounting in generation metadata — отдельный учёт контекста памяти
- Lightweight top-k selection pass — легковесный top-k отбор
- Session setting: `maxInjectedEntries` cap — настройка: лимит количества инжектируемых записей
- Memory injection target selection UI — выбор места инжекта в UI

**UI & Visualization (UI и визуализация)**
- Per-message memory coverage markers — маркеры покрытия сообщений памятью
- Inspect memory entry → message range mapping — просмотр связи запись↔сообщения
- Dedicated Memory Books window/sheet in magic drawer — отдельное окно Memory Books
- Tokenizer: memory usage as summary-like context — токенизатор: память как summary context
- Message trigger UI: distinct memory-triggered entries — триггеры памяти отдельно от лорбуков

**Features Implemented (Реализованные фичи)**
- Messages store `contextRefs` + `memoryCoverage` metadata — метаданные покрытия в сообщениях
- Manual memory creation/removal from selected messages — ручное создание/удаление из выбранных сообщений
- Provider selection: current API vs custom — выбор провайдера: текущий API или кастомный
- Model override support (current provider) — переопределение модели
- Memory Generation: own rules/prompt presets, temperature override — свои пресеты промптов и температура
- Prompt preview + edit from manager — предпросмотр и редактирование промптов
- Navigation: closing prompt preview returns to memory sheet — возврат из превью в меню памяти
- Draft generation: continuity from nearby approved memories — черновик включает соседние память
- Draft generation: includes lore-trigger candidates + summary excerpt — черновик включает триггеры лорбука + саммари
- Normal generation: injects memory entries as separate block — обычная генерация инжектит память отдельно
- Dialog export: Glaze full-fidelity format preserves memory books — экспорт сохраняет память
- ST import/export: preserves Glaze IDs, refs, coverage in `extra` — ST экспорт сохраняет Glaze метаданные
- Memory entries persist retrieval fields: keys, glazeKeys, vectorSearch — записи сохраняют поля поиска
- Approved entries can be edited: title/content/keys, vectorSearch toggle, manual Reindex — редактирование одобренных записей
- Session-level vector-search toggle + key match mode selector — переключатель векторного поиска и режим ключей
- Session-level retrieved-entry cap (`maxInjectedEntries`) — лимит количества инжектируемых записей
- Memory prompts ask for text + optional keys (not JSON-only) — промпты просят текст + ключи (не только JSON)
- Draft parsing: vector-first usage, auto-generates fallback keys — парсинг черновиков: автогенерация ключей
- Session setting: auto-create interval ("раз в сколько сообщений") — настройка интервала автосоздания
- Session setting: memory injection target selection — настройка места инжекта
- Lorebook: global default injection position + per-entry `Match Global` / `{{lorebooks}}` — глобальная позиция инжекта лорбука
- Lorebook ST round-trip: preserves Glaze injection targets via `glazeMetadata` — ST экспорт сохраняет Glaze метаданные
- Chat import: initial segmentation/bootstrap flow for first-pass memory drafts — автосегментация при импорте
- Export: deterministic memory book state in backup data — детерминированный экспорт памяти
- ST export: Glaze-to-Glaze preserves memory books, refs, coverage — полный Glaze экспорт памяти
- Delayed automation: "работать с отставанием" toggle — отложенная автоматизация
- Delayed automation engine: tracks pending triggers, evaluates after stable reply — движок отложенной автоматизации
- Segmentation policy: N-message interval, prefers assistant-reply boundaries — политика сегментации
- Deduplication: blocks exact-duplicate and high-overlap segments — дедупликация
- Maintenance pass: reconcile coverage, clear orphaned drafts, remove orphaned approved, reindex — проход обслуживания
- Lifecycle state UI: status badges, summary counters (active/drafts/needs-rebuild/stale) — UI статуса жизненного цикла
- Memory generation rules manager: built-in presets, user prompts, preview, independent selection — менеджер правил генерации
- Temperature override independent from main preset — переопределение температуры
- Current provider: model override while reusing endpoint/key — переопределение модели при сохранении endpoint/key
- Prompt preview close returns to memory settings/manager — возврат из превью промпта
- Extraction context: nearby approved memories (1-3 max) — контекст извлечения: соседние одобренные записи
- Extraction context: lightweight retrieval on segment for top lore candidates — легковесный поиск лорбука для сегмента
- Extraction context: compact summary excerpt + minimal setting context — компактный отрывок саммари
- Stable message IDs + compact per-message trigger references — стабильные ID сообщений + компактные ссылки на триггеры
- Top-k compression for extraction context — top-k сжатие контекста извлечения
- Summary-path injection + tokenizer visualization — инжект в summary + визуализация в токенизаторе
- Backup/sync-safe persistence integration — интеграция с backup/sync

#### Не реализовано и не протестировано (`not done | not tested`):

**Critical Missing Features (Критические недостающие фичи)**
- ❌ **First memory creation is too manual** — первая память создаётся только вручную
- ❌ **No clear per-message marker** showing which messages are covered — нет явных маркеров покрытия сообщений
- ❌ **Orphaned/stale memories** after message deletion/branching — осиротевшие/устаревшие записи после удаления/ветвления
- ❌ **No autonomous segmentation** for imported chats — нет автосегментации для импортированных чатов
- ❌ **Memory retrieval doesn't inject into summary block path** — память не инжектится в summary block (?)
- ❌ **No dedicated memory container** for chat-level data — нет выделенного контейнера памяти (?)
- ❌ **No maintenance pass** to recompute coverage and clean orphaned entries — нет прохода обслуживания для пересчёта покрытия
- ❌ **Stale/orphaned state not surfaced in UI** — устаревший статус не показывается в UI
- ❌ **Temporary bottom-sheet UI instead of dedicated polished component** — временный bottom-sheet вместо polished компонента
- ❌ **Automation rules and quality tuning** — правила автоматизации и настройка качества
- ❌ **Cloud sync alignment** with PR #20 data model — выравнивание с моделью данных cloud sync
- ❌ **Embeddings export rules** not defined — правила экспорта эмбеддингов не определены
- ❌ **Cloud sync merge logic** for memory books — логика слияния cloud sync для памяти
- ❌ **Cloud sync extension** to include memory-book records — расширение cloud sync для записей памяти

**Extraction Context Algorithm (Алгоритм контекста извлечения)**
- ❌ Don't reconstruct from current live lorebook inject — не реконструировать из текущего лорбука
- ❌ Don't send full set of triggered lore entries from all messages — не отправлять все триггеры лорбука
- ❌ Store only compact trigger references per message — хранить только компактные ссылки на триггеры
- ❌ Two-stage candidate collection/compression — двухэтапный сбор/сжатие кандидатов
- ❌ Weighted ranking formula (trigger frequency, recency, entity overlap, retrieval score) — взвешенная формула ранжирования
- ❌ Deduplicate by entry ID before scoring — дедупликация по entry ID перед оценкой
- ❌ Hard-capped top-k lore set (3-5 entries max) — жёсткий лимит top-k лорбука
- ❌ Hard-capped top-k memory continuity set (1-3 entries max) — жёсткий лимит top-k памяти
- ❌ Drop low-value context aggressively — агрессивно отбрасывать низкоценный контекст
- ❌ Payload limits: one segment, 1-3 memory entries, 3-5 lore entries, one summary excerpt — лимиты payload

#### Manual Verification Required (Требуется ручная проверка):

**Critical Tests (Критические тесты)**
- ❌ Message deletion → memories marked stale/removed
- ❌ Chat branching → no active memories for non-existent messages
- ❌ Partial memory entries → downgraded to `needs_rebuild`
- ❌ Imported chats → bootstrap first memories without manual seed
- ❌ Current provider → override model, keep endpoint/key unchanged
- ❌ Prompt preview close → returns to Memory Generation or manager
- ❌ Memory injections → count separately from lorebook injections
- ❌ Tokenizer → shows memory usage with summary-style accounting
- ❌ Edit approved memory → updates content/keys, doesn't break coverage metadata
- ❌ Disable `vectorSearch` → deletes memory-entry embedding
- ❌ Re-enable `vectorSearch` or manual Reindex → rebuilds embedding
- ❌ Memory Books key match mode (plain/glaze/both) → changes retrieval as expected
- ❌ Auto-create interval → respects delayed mode correctly
- ❌ Disable delayed automation → switches to immediate threshold behavior
- ❌ Lorebook entries (Match Global, @worldInfoBefore, @worldInfoAfter, {{lorebooks}}) → inject at expected locations
- ❌ Lorebook/memory entries aggregate into single blocks, macro injection edge case
- ❌ Glaze lorebook export/import → preserves Match Global and {{lorebooks}}
- ❌ Backup export/import → preserves memory books, rebuilds vectors safely
- ❌ Cloud-sync serialization → round-trips memory books without duplication/orphans
- ❌ Glaze-to-Glaze export/import → preserves memory books, markers, settings without loss

---

### 2. Summary Block (Саммари) — 4 задачи

#### Не реализовано и не протестировано:
- ❌ **Simple mode prompts need proper defaults and editability** — промпты Simple mode нужны дефолтные и редактируемые
  - Two distinct default prompts: fresh summary vs update
  - UI to edit prompts without clutter (inline textarea or link)
  - Support macros: `{{char}}`, `{{user}}`, `{{history}}`
  - Store globally in localStorage or in preset
- ❌ **Grouped section updates** (e.g. two sections at a time) — групповые обновления секций
  - Infrastructure ready, not wired in UI
- ❌ **Summary UI polish** — полировка UI саммари
  - Deferred until model is battle-tested

---

### 3. Vectorization (Векторизация) — 3 задачи

#### Известные проблемы:
- ⚠️ **Vector ranking is too scene-biased** for character retrieval — ранжирование слишком смещено к сценам
  - Real test case: opening about `Forum`/`Sina` + blue-haired catgirl request → ranks locations/NPCs above character `Asei`
  - Pipeline works technically, but ranking needs stronger entity/appearance bias
  - Weaker fallback influence needed

---

### 4. Sync Infrastructure (Синхронизация) — 7 задач

#### Manual Verification Required:
- ❌ Dropbox connect/disconnect on native (Android/iOS) with `com.hydall.glaze://oauth/dropbox`
- ❌ Google Drive connect/disconnect on native
- ❌ Push/Pull works WITHOUT encryption key (plain JSON)
- ❌ Push/Pull works WITH encryption key (encrypted `.enc`)
- ❌ Fallback: pull from cloud with old `.enc` files when encryption disabled
- ❌ Error 400 fixed after setting correct redirect URI in OAuth console
- ❌ Electron OAuth flow works on Windows/Linux desktop builds

---

### 5. Tokenizer (Токенизатор) — 3 задачи

#### Manual Verification Needed:
- ❌ Memory usage displays as summary-like context (not lorebook context)
- ❌ Test with various lorebook configurations
- ❌ Validate reserve visualization with mixed keyword/vector entries

---

## Приоритеты тестирования

### 🔴 КРИТИЧЕСКИЕ (нужно протестировать срочно):
1. **Memory lifecycle** (deletion, branching) — жизненный цикл памяти
2. **Memory settings persistence** — сохранение настроек памяти
3. **Tokenizer memory accounting** — учёт памяти в токенизаторе
4. **Vector ranking for character retrieval** — ранжирование векторов для персонажей

### 🟡 ВЫСОКИЙ ПРИОРИТЕТ:
1. **Memory automation triggers** — триггеры автоматизации памяти
2. **Draft generation and approval** — генерация и одобрение черновиков
3. **Summary simple mode prompts** — промпты Simple mode саммари
4. **Cloud sync with memory books** — синхронизация с памятью

### 🟢 СРЕДНИЙ/НИЗКИЙ ПРИОРИТЕТ:
1. **Lorebook injection targets** — цели инжекта лорбука
2. **Glaze export/import round-trip** — экспорт/импорт Glaze
3. **Sync encryption optional modes** — опциональное шифрование синхронизации

---

## Статистика

- **Всего "not tested"**: 188 записей
- **Memory Books**: ~76 задач
- **Summary**: ~4 задачи
- **Vectorization**: ~3 задачи
- **Sync**: ~7 задач
- **Tokenizer**: ~3 задачи
- **Manual Verification**: ~30 чек-листов

---

## Рекомендации

1. **Начать с критических тестов** — memory lifecycle, settings persistence
2. **Создать automated test suite** для memory lifecycle (deletion, branching, automation)
3. **Manual testing checklist** для каждой категории
4. **Постепенно переводить** `not tested` → `tested` по мере проверки
