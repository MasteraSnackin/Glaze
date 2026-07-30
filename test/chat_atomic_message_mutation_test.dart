import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  late AppDatabase db;
  late ChatRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ChatRepo(db);
  });
  tearDown(() async => db.close());

  test('message mutation preserves a concurrently persisted draft', () async {
    await repo.put(
      const ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        draft: 'old draft',
        messages: [ChatMessage(id: 'm1', role: 'user', content: 'before')],
      ),
    );
    await repo.updateDraftIfMessageCount(
      sessionId: 'session',
      draft: 'new draft',
      expectedMessageCount: 1,
    );

    final durable = await repo.mutateMessages(
      sessionId: 'session',
      updatedAt: 10,
      mutate: (messages) {
        messages[0] = messages[0].copyWith(content: 'after');
        return messages;
      },
    );

    expect(durable?.draft, 'new draft');
    expect(durable?.messages.single.content, 'after');
  });

  test('message mutation preserves a newer durable tail', () async {
    await repo.put(
      const ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        messages: [ChatMessage(id: 'm1', role: 'user', content: 'first')],
      ),
    );
    await repo.appendUserMessageAndClearDraft(
      sessionId: 'session',
      message: const ChatMessage(id: 'm2', role: 'user', content: 'tail'),
      updatedAt: 11,
    );

    final durable = await repo.mutateMessages(
      sessionId: 'session',
      updatedAt: 12,
      mutate: (messages) {
        final index = messages.indexWhere((message) => message.id == 'm1');
        messages[index] = messages[index].copyWith(isHidden: true);
        return messages;
      },
    );

    expect(durable?.messages.map((message) => message.id), ['m1', 'm2']);
    expect(durable?.messages.first.isHidden, isTrue);
    expect(durable?.messages.last.content, 'tail');
  });

  test('session var delta preserves concurrent keys', () {
    final merged = ChatRepo.applySessionVarDelta(
      {'unchanged': 'latest', 'concurrent': 'keep', 'removed': 'old'},
      {'unchanged': 'old', 'removed': 'old'},
      {'unchanged': 'generated', 'added': 'new'},
    );

    expect(merged, {
      'unchanged': 'generated',
      'concurrent': 'keep',
      'added': 'new',
    });
  });
}
