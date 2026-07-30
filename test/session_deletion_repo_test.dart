import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/session_deletion_repo.dart';

const _sessionTables = <(String, String)>[
  ('chat_sessions', 'session_id'),
  ('memory_book_rows', 'session_id'),
  ('memory_catalog_rows', 'chat_session_id'),
  ('memory_entity_rows', 'chat_session_id'),
  ('memory_salience_rows', 'chat_session_id'),
  ('memory_cadence_rows', 'chat_session_id'),
  ('memory_consolidation_rows', 'chat_session_id'),
  ('tracker_rows', 'session_id'),
  ('tracker_snapshots', 'session_id'),
  ('ledger_reconciliation_checkpoints', 'session_id'),
  ('ledger_reconciliation_cleanup_journals', 'session_id'),
  ('character_knowledge_fact_rows', 'chat_session_id'),
  ('character_session_baseline_rows', 'chat_session_id'),
  ('studio_config_rows', 'session_id'),
  ('chat_summaries', 'session_id'),
  ('info_blocks', 'session_id'),
];

void main() {
  late AppDatabase db;
  late SessionDeletionRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = SessionDeletionRepo(db);
  });

  tearDown(() => db.close());

  test(
    'deletes every session-owned row and preserves another session',
    () async {
      await _seedSession(db, 'target');
      await _seedSession(db, 'control');

      await repo.deleteSession('target');

      await _expectSessionCount(db, 'target', 0);
      await _expectSessionCount(db, 'control', 1);

      await repo.deleteSession('target');
      await _expectSessionCount(db, 'target', 0);
      await _expectSessionCount(db, 'control', 1);
    },
  );

  test('rolls back the complete cascade when a delete fails', () async {
    await _seedSession(db, 'target');
    await db.customStatement('''
      CREATE TRIGGER fail_session_delete
      BEFORE DELETE ON tracker_rows
      WHEN OLD.session_id = 'target'
      BEGIN
        SELECT RAISE(ABORT, 'test delete failure');
      END
    ''');

    await expectLater(repo.deleteSession('target'), throwsA(anything));

    await _expectSessionCount(db, 'target', 1);
  });
}

Future<void> _seedSession(AppDatabase db, String sessionId) async {
  final id = sessionId.replaceAll('-', '_');
  final statements = <String>[
    "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES ('$sessionId', 'char_$id', 0, '[]')",
    "INSERT INTO memory_book_rows (session_id) VALUES ('$sessionId')",
    "INSERT INTO memory_catalog_rows (id, chat_session_id, memory_entry_id) VALUES ('catalog_$id', '$sessionId', 'entry_$id')",
    "INSERT INTO memory_entity_rows (id, chat_session_id, memory_entry_id, name) VALUES ('entity_$id', '$sessionId', 'entry_$id', 'name')",
    "INSERT INTO memory_salience_rows (id, chat_session_id, memory_entry_id) VALUES ('salience_$id', '$sessionId', 'entry_$id')",
    "INSERT INTO memory_cadence_rows (chat_session_id) VALUES ('$sessionId')",
    "INSERT INTO memory_consolidation_rows (id, chat_session_id) VALUES ('consolidation_$id', '$sessionId')",
    "INSERT INTO tracker_rows (session_id, name) VALUES ('$sessionId', 'tracker')",
    "INSERT INTO tracker_snapshots (session_id, message_id) VALUES ('$sessionId', 'message')",
    "INSERT INTO ledger_reconciliation_checkpoints (session_id, start_message_id, end_message_id) VALUES ('$sessionId', 'start', 'end')",
    "INSERT INTO ledger_reconciliation_cleanup_journals (session_id, endpoint_message_id) VALUES ('$sessionId', 'end')",
    "INSERT INTO character_knowledge_fact_rows (id, chat_session_id, knower_key, subject_key, fact_class, predicate, object, epistemic_state) VALUES ('fact_$id', '$sessionId', 'knower', 'subject', 'fact', 'predicate', 'object', 'known')",
    "INSERT INTO character_session_baseline_rows (chat_session_id, character_id, baseline_card_json, baseline_hash) VALUES ('$sessionId', 'char_$id', '{}', 'hash')",
    "INSERT INTO studio_config_rows (session_id) VALUES ('$sessionId')",
    "INSERT INTO chat_summaries (session_id, content) VALUES ('$sessionId', 'summary')",
    "INSERT INTO info_blocks (id, session_id, message_id, block_id, block_name, block_type, content) VALUES ('block_$id', '$sessionId', 'message', 'block', 'Block', 'info', 'content')",
    "INSERT INTO embeddings (entry_id, source_type, source_id) VALUES ('embedding_$id', 'chat_message', '$sessionId')",
    "INSERT INTO embeddings (entry_id, source_type, source_id) VALUES ('lorebook_embedding_$id', 'lorebook_entry', 'lorebook_$id')",
    "INSERT INTO lorebooks (lorebook_id, name, activation_scope, activation_target_id, entries_json) VALUES ('lorebook_$id', 'Lorebook', 'chat', '$sessionId', '[]')",
  ];
  for (final statement in statements) {
    await db.customStatement(statement);
  }
}

Future<void> _expectSessionCount(
  AppDatabase db,
  String sessionId,
  int expected,
) async {
  for (final (table, column) in _sessionTables) {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS count FROM $table WHERE $column = ?',
          variables: [Variable.withString(sessionId)],
        )
        .getSingle();
    expect(row.read<int>('count'), expected, reason: table);
  }

  for (final (table, predicate) in [
    ('embeddings', "source_type = 'chat_message' AND source_id = ?"),
    ('lorebooks', "activation_scope = 'chat' AND activation_target_id = ?"),
  ]) {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS count FROM $table WHERE $predicate',
          variables: [Variable.withString(sessionId)],
        )
        .getSingle();
    expect(row.read<int>('count'), expected, reason: table);
  }

  final lorebookEmbedding = await db
      .customSelect(
        "SELECT COUNT(*) AS count FROM embeddings WHERE source_type = 'lorebook_entry' AND source_id = ?",
        variables: [
          Variable.withString('lorebook_${sessionId.replaceAll('-', '_')}'),
        ],
      )
      .getSingle();
  expect(
    lorebookEmbedding.read<int>('count'),
    expected,
    reason: 'lorebook embeddings',
  );
}
