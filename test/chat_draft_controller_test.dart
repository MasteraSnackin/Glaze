import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/controllers/chat_draft_controller.dart';

class _DelayedDraftRepo extends ChatRepo {
  final Completer<void> started = Completer<void>();
  final Completer<ChatSession?> completion = Completer<ChatSession?>();

  _DelayedDraftRepo(super.db);

  @override
  Future<ChatSession?> updateDraftIfMessageCount({
    required String sessionId,
    required String draft,
    required int expectedMessageCount,
  }) {
    if (!started.isCompleted) started.complete();
    return completion.future;
  }
}

void main() {
  late AppDatabase db;
  late _DelayedDraftRepo repo;
  late ProviderContainer container;

  const message = ChatMessage(
    id: 'm1',
    role: 'assistant',
    content: 'hello',
    timestamp: 1,
  );
  const sessionA = ChatSession(
    id: 'a',
    characterId: 'c1',
    sessionIndex: 0,
    messages: [message],
  );
  const sessionB = ChatSession(
    id: 'b',
    characterId: 'c1',
    sessionIndex: 1,
    messages: [message],
  );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = _DelayedDraftRepo(db);
    container = ProviderContainer(
      overrides: [chatRepoProvider.overrideWithValue(repo)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test(
    'delayed draft completion cannot switch the active session back',
    () async {
      AsyncValue<ChatState> state = const AsyncData(
        ChatState(session: sessionA),
      );
      final controller = ChatDraftController(
        ref: container.read(Provider((ref) => ref)),
        setState: (next) => state = next,
        getState: () => state,
      );

      final pending = controller.saveDraft('draft A');
      await repo.started.future;
      state = const AsyncData(ChatState(session: sessionB));
      repo.completion.complete(sessionA.copyWith(draft: 'draft A'));
      await pending;

      expect(state.value!.session!.id, 'b');
    },
  );

  test('delayed draft completion cannot remove a newer message', () async {
    AsyncValue<ChatState> state = const AsyncData(ChatState(session: sessionA));
    final controller = ChatDraftController(
      ref: container.read(Provider((ref) => ref)),
      setState: (next) => state = next,
      getState: () => state,
    );

    final pending = controller.saveDraft('draft A');
    await repo.started.future;
    state = AsyncData(
      ChatState(
        session: sessionA.copyWith(
          messages: [
            message,
            const ChatMessage(
              id: 'u1',
              role: 'user',
              content: 'new',
              timestamp: 2,
            ),
          ],
        ),
      ),
    );
    repo.completion.complete(sessionA.copyWith(draft: 'draft A'));
    await pending;

    expect(state.value!.messages.map((item) => item.id), ['m1', 'u1']);
  });
}
