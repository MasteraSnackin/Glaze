import '../../application/session_deletion_store.dart';
import '../app_db.dart';
import 'session_deletion_queries.dart';

class SessionDeletionRepo implements SessionDeletionStore {
  final AppDatabase _db;

  SessionDeletionRepo(this._db);

  @override
  Future<void> deleteSession(String sessionId) => _db.transaction(
    () => SessionDeletionQueries(_db).deleteSessionRows(sessionId),
  );
}
