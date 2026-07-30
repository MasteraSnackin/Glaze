import 'package:drift/drift.dart';

import '../../application/session_deletion_store.dart';
import '../app_db.dart';

class SessionDeletionRepo implements SessionDeletionStore {
  final AppDatabase _db;

  SessionDeletionRepo(this._db);

  @override
  Future<void> deleteSession(String sessionId) => _db.transaction(() async {
    final chatLorebookIds =
        await (_db.selectOnly(_db.lorebooks)
              ..addColumns([_db.lorebooks.lorebookId])
              ..where(
                _db.lorebooks.activationScope.equals('chat') &
                    _db.lorebooks.activationTargetId.equals(sessionId),
              ))
            .map((row) => row.read(_db.lorebooks.lorebookId)!)
            .get();

    await (_db.delete(
      _db.memoryBookRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memoryCatalogRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memoryEntityRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memorySalienceRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memoryCadenceRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memoryConsolidationRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.trackerRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.trackerSnapshots,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.ledgerReconciliationCheckpoints,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.ledgerReconciliationCleanupJournals,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.characterKnowledgeFactRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.characterSessionBaselineRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.studioConfigRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.chatSummaries,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.infoBlocks,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(_db.embeddings)..where(
          (row) =>
              row.sourceType.equals('chat_message') &
              row.sourceId.equals(sessionId),
        ))
        .go();
    if (chatLorebookIds.isNotEmpty) {
      await (_db.delete(_db.embeddings)..where(
            (row) =>
                row.sourceType.equals('lorebook_entry') &
                row.sourceId.isIn(chatLorebookIds),
          ))
          .go();
    }
    await (_db.delete(_db.lorebooks)..where(
          (row) =>
              row.activationScope.equals('chat') &
              row.activationTargetId.equals(sessionId),
        ))
        .go();
    await (_db.delete(
      _db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).go();
  });
}
