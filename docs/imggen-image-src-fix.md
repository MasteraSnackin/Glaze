# Битые картинки в чате: причина и план фикса

Рабочая заметка. Состояние: причина найдена, фикс начат (не закончен, не проверен, не закоммичен).

## Причина

В тексте сообщения сохранён **резолвнутый loopback-URL**, а не путь к файлу:

```
[IMG:RESULT:*http://127.0.0.1:35621/__glaze_file__?path=%2Fdata%2Fuser%2F0%2F…%2Fgenerated%2Fimggen_…_13.jpg;;http://127.0.0.1:35621/__glaze_file__?path=…_0.jpg|{"style":…}]
```

Порт `35621` живёт только до перезапуска приложения (`_startChatWebViewLocalFileServer` биндится на порт 0).
Отсюда всё поведение: картинка битая навсегда, перезаход в чат и перезапуск приложения не помогают,
скачанный файл не открывается (сервер отдал не байты картинки), а свежесгенерированная картинка
работает — у неё в теге ещё сырой путь, пока его не перезапишут URL-ом.

**Как URL попадает в БД:** страница держит текст сообщения в `section.dataset.rawText` уже
резолвнутым (`ChatBridgeController.resolveImgResults` при `updateMessage`/`setMessages`).
`edit_controller.js` заполняет textarea из `dataset.rawText`, `onEditSave` отдаёт его в Dart, и
`chat_screen.dart` → `editMessage()` пишет это в БД как есть. Тот же путь у `_extractText(section)`
(`onMessageContext`, копирование).

## Что уже сделано (в рабочем дереве, не закоммичено)

- `chat_webview_environment.dart`
  - `chatWebViewLocalFilePathOf(source)` — достаёт `path` из `/__glaze_file__` URL;
  - `restoreChatWebViewLocalFilePath(source)` — URL → путь, остальное без изменений;
  - `chatWebViewResolveLocalFileUrl` сначала разворачивает такой URL и резолвит уже путь —
    **это лечит уже сломанные сообщения без миграции БД**.
- `chat_bridge_controller.dart`
  - `restoreImgResults(text)` — обратная к `resolveImgResults`, через `ImageTagMarkup.rewriteResultPaths`;
  - применена в `onEditSave` и `onMessageContext`.

## Что осталось

1. `onSelectionAction` (`chat_bridge_controller.dart:467`) — тоже прогнать текст через `restoreImgResults`.
2. Тесты: `chatWebViewLocalFilePathOf` / разворот URL при резолве; `restoreImgResults` на тексте с
   двумя вариантами; edit-save не сохраняет URL.
3. `flutter analyze` + `flutter test`, коммит, PR в `nightly`.

## Дальше: формат хранения (запрос пользователя)

Сейчас в сообщении виден `[IMG:RESULT:<абсолютный путь>|<instruction JSON>]`. Нужно как в
расширении для таверны (`0xl0cal/sillyimages`):

```html
<img data-iig-instruction='{"style":"…","prompt":"…"}' src="generated/imggen_123_0.jpg">
```

- `src` — **относительный** путь от корня данных Glaze (`resolveGlazeFilePath` уже умеет
  склеивать относительный путь с текущей базой, и это заодно чинит смену контейнера на iOS);
- варианты блока — в атрибутах (`data-iig-variants='generated/a.jpg;;generated/b.jpg'`,
  `data-iig-index='1'`), чтобы `src` оставался одним простым путём;
- `[IMG:RESULT:…]` продолжаем **читать** (старые сообщения), писать — только новую форму;
- затронуть: `ImgGenPatterns`, `ImageTagMarkup` (scan/replace/reset/варианты), `formatter.js`
  (рендер обеих форм), `_saveGeneratedImage` (возвращать относительный путь), `findImageOnDisk`,
  cloud-sync (`sync_image_stripper`, `sync_serialization`), тесты, `docs/INVARIANTS.md` (INV-IG8).
