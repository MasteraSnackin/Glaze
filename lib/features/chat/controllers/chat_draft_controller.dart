import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/db_provider.dart';
import '../chat_session_service.dart';
import '../chat_state.dart';

class ChatDraftController {
  final Ref _ref;
  final void Function(AsyncValue<ChatState>) _setState;
  final AsyncValue<ChatState> Function() _getState;

  int _saveEpoch = 0;

  ChatDraftController({
    required this._ref,
    required this._setState,
    required this._getState,
  });

  Future<void> saveDraft(String draftText) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    if (current.session!.draft == draftText) return;

    final sessionId = current.session!.id;
    final expectedMessageCount = current.session!.messages.length;
    final epoch = ++_saveEpoch;
    final updatedSession = await _ref
        .read(chatRepoProvider)
        .updateDraftIfMessageCount(
          sessionId: sessionId,
          draft: draftText,
          expectedMessageCount: expectedMessageCount,
        );
    if (!_ref.mounted) return;
    if (epoch != _saveEpoch) return;
    if (updatedSession == null) return;
    final latest = _getState().value;
    // A draft completion belongs only to the exact session snapshot that
    // started it. Never let a delayed debounce switch the UI back to an old
    // session or replace a newer optimistic/durable message list.
    if (latest?.session?.id != sessionId ||
        latest!.session!.messages.length != expectedMessageCount) {
      return;
    }
    final sessionWithDraft = latest.session!.copyWith(
      draft: updatedSession.draft,
    );
    ChatSessionService.updateCache(sessionWithDraft);
    _setState(AsyncData(latest.copyWith(session: sessionWithDraft)));
  }
}
