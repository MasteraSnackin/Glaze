import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/js_backup_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

class _TestImageStorage extends ImageStorageService {
  _TestImageStorage()
    : super(Directory.systemTemp.createTempSync('glaze_test_img_').path);

  @override
  Future<String> saveAvatar(String characterId, Uint8List imageBytes) async {
    return '/fake/avatars/$characterId.png';
  }

  @override
  Future<String?> saveThumbnail(
    String characterId,
    Uint8List imageBytes,
  ) async {
    return '/fake/thumbnails/$characterId.jpg';
  }
}

void main() {
  group('Backup importer schema safety', () {
    late AppDatabase db;
    late ImageStorageService imageStorage;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = _testDb();
      imageStorage = _TestImageStorage();
    });

    tearDown(() async {
      await db.close();
    });

    test('calling import() twice does not crash on duplicate column', () async {
      final importer = JsBackupImporter(db, imageStorage);
      final data = _minimalBackup();

      await importer.import(data, onProgress: (_) {});

      await importer.import(data, onProgress: (_) {});
    });

    test('created_at column exists after import', () async {
      final importer = JsBackupImporter(db, imageStorage);
      await importer.import(_minimalBackup(), onProgress: (_) {});

      final cols = await db
          .customSelect("PRAGMA table_info('characters')")
          .get();
      final names = cols.map((c) => c.read<String>('name')).toSet();

      expect(names, contains('created_at'));
      expect(names, contains('macro_name'));
      expect(names, contains('picks_hash'));
    });

    test('current schema version after import', () async {
      final importer = JsBackupImporter(db, imageStorage);
      await importer.import(_minimalBackup(), onProgress: (_) {});

      final result = await db.customSelect('PRAGMA user_version').get();
      final version = result.first.read<int>('user_version');

      // user_version matches the Drift schema version (app_db.dart schemaVersion).
      // Update this constant whenever a new migration step is added.
      expect(version, 85);
    });

    test(
      'upgrade from v15 with macro_name already present does not crash',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_test_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });

        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement('PRAGMA user_version = 15');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        // Ensure the db handle is released even if an expectation below
        // fails — otherwise Windows cannot delete the temp file in tearDown.
        addTearDown(() async => upgraded.close());
        await upgraded.customSelect('SELECT 1').get();

        final cols = await upgraded
            .customSelect("PRAGMA table_info('characters')")
            .get();
        final names = cols.map((c) => c.read<String>('name')).toSet();
        expect(names, contains('macro_name'));

        final version = await upgraded
            .customSelect('PRAGMA user_version')
            .get();
        expect(version.first.read<int>('user_version'), 85);
        expect(names, contains('variant_group_id'));
        expect(names, contains('hidden'));
      },
    );

    test('v67 upgrade tolerates a v66 schema without studio_preset_id', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_studio_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement('PRAGMA user_version = 66');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 85);
    });

    test('current schema includes atomic character fact tables', () async {
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 85);

      final factColumns = await db
          .customSelect("PRAGMA table_info('character_knowledge_fact_rows')")
          .get();
      final factNames = factColumns
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(
        factNames,
        containsAll(<String>{
          'id',
          'chat_session_id',
          'knower_key',
          'subject_key',
          'fact_class',
          'scope_key',
          'predicate',
          'object',
          'epistemic_state',
          'source_message_id',
          'source_swipe_id',
          'source_agent_swipe_id',
          'supersedes_id',
          'lifecycle',
        }),
      );

      final baselineColumns = await db
          .customSelect("PRAGMA table_info('character_session_baseline_rows')")
          .get();
      final baselineNames = baselineColumns
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(
        baselineNames,
        containsAll(<String>{
          'chat_session_id',
          'character_id',
          'baseline_card_json',
          'baseline_hash',
          'source_hash_last_seen',
          'card_update_policy',
        }),
      );
    });

    test(
      'current API config schema includes extra request parameters',
      () async {
        final columns = await db
            .customSelect("PRAGMA table_info('api_configs')")
            .get();
        final names = columns.map((row) => row.read<String>('name')).toSet();

        expect(
          names,
          containsAll([
            'extra_request_parameters_json',
            'include_last_reasoning',
            'show_native_reasoning',
            'omit_top_k',
            'omit_frequency_penalty',
            'omit_presence_penalty',
            'use_responses_api',
          ]),
        );
      },
    );

    test('v77 adds reversible reconciliation cleanup journal', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_reconcile_journal_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        'DROP TABLE ledger_reconciliation_cleanup_journals',
      );
      await seeded.customStatement('PRAGMA user_version = 76');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final columns = await upgraded
          .customSelect(
            "PRAGMA table_info('ledger_reconciliation_cleanup_journals')",
          )
          .get();

      expect(
        columns.map((row) => row.read<String>('name')),
        containsAll([
          'id',
          'session_id',
          'endpoint_message_id',
          'message_ids_json',
          'before_images_json',
          'created_at',
        ]),
      );
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 85);
    });

    test(
      'v76 preserves native reasoning visibility from omit_reasoning',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_reasoning_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });

        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          "INSERT INTO api_configs (config_id, name, omit_reasoning) "
          "VALUES ('shown', 'Shown', 0)",
        );
        await seeded.customStatement(
          "INSERT INTO api_configs (config_id, name, omit_reasoning) "
          "VALUES ('hidden', 'Hidden', 1)",
        );
        await seeded.customStatement(
          'ALTER TABLE api_configs DROP COLUMN show_native_reasoning',
        );
        await seeded.customStatement(
          'ALTER TABLE api_configs DROP COLUMN omit_top_k',
        );
        await seeded.customStatement(
          'ALTER TABLE api_configs DROP COLUMN omit_frequency_penalty',
        );
        await seeded.customStatement(
          'ALTER TABLE api_configs DROP COLUMN omit_presence_penalty',
        );
        await seeded.customStatement('PRAGMA user_version = 75');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        final rows = await upgraded
            .customSelect(
              'SELECT config_id, show_native_reasoning, omit_top_k, '
              'omit_frequency_penalty, omit_presence_penalty '
              'FROM api_configs ORDER BY config_id',
            )
            .get();

        expect(rows[0].read<String>('config_id'), 'hidden');
        expect(rows[0].read<bool>('show_native_reasoning'), isFalse);
        expect(rows[1].read<String>('config_id'), 'shown');
        expect(rows[1].read<bool>('show_native_reasoning'), isTrue);
        for (final row in rows) {
          expect(row.read<bool>('omit_top_k'), isFalse);
          expect(row.read<bool>('omit_frequency_penalty'), isFalse);
          expect(row.read<bool>('omit_presence_penalty'), isFalse);
        }
      },
    );

    test('v79 migrates the reasoning history toggle to a count', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_reasoning_count_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        'INSERT INTO api_configs '
        '(config_id, name, include_last_reasoning) VALUES (?, ?, ?)',
        ['disabled', 'Disabled', 0],
      );
      await seeded.customStatement(
        'INSERT INTO api_configs '
        '(config_id, name, include_last_reasoning) VALUES (?, ?, ?)',
        ['enabled', 'Enabled', 1],
      );
      await seeded.customStatement(
        'ALTER TABLE api_configs DROP COLUMN reasoning_history_count',
      );
      await seeded.customStatement('PRAGMA user_version = 77');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final rows = await upgraded
          .customSelect(
            'SELECT config_id, reasoning_history_count '
            'FROM api_configs ORDER BY config_id',
          )
          .get();

      expect(rows[0].read<String>('config_id'), 'disabled');
      expect(rows[0].read<int>('reasoning_history_count'), 0);
      expect(rows[1].read<String>('config_id'), 'enabled');
      expect(rows[1].read<int>('reasoning_history_count'), 1);
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 85);
    });

    test('v80 adds Responses API toggle defaulting to off', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_responses_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        'INSERT INTO api_configs (config_id, name) VALUES (?, ?)',
        ['existing', 'Existing'],
      );
      await seeded.customStatement(
        'ALTER TABLE api_configs DROP COLUMN use_responses_api',
      );
      await seeded.customStatement('PRAGMA user_version = 79');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final row = await upgraded
          .customSelect(
            'SELECT use_responses_api FROM api_configs WHERE config_id = ?',
            variables: [Variable.withString('existing')],
          )
          .getSingle();

      expect(row.read<bool>('use_responses_api'), isFalse);
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 85);
    });

    test('v81 adds composite embedding source index', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_embedding_index_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement('DROP INDEX idx_embeddings_source_type_id');
      await seeded.customStatement('PRAGMA user_version = 80');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final indexes = await upgraded
          .customSelect("PRAGMA index_list('embeddings')")
          .get();

      expect(
        indexes.map((row) => row.read<String>('name')),
        contains('idx_embeddings_source_type_id'),
      );
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 85);
    });

    test('v82 creates rewrite persistence schema and provenance columns', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_rewrite_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      for (final table in [
        'character_revision_rows',
        'applied_canon_transition_rows',
        'rewrite_jobs',
        'rewrite_operations',
        'rewrite_operation_revisions',
        'rewrite_evidence_rows',
        'canon_transition_fact_refs',
      ]) {
        await seeded.customStatement('DROP TABLE $table');
      }
      await seeded.customStatement(
        'ALTER TABLE character_knowledge_fact_rows DROP COLUMN basis_revision',
      );
      await seeded.customStatement(
        'ALTER TABLE character_knowledge_fact_rows DROP COLUMN basis_revision_hash',
      );
      await seeded.customStatement(
        'ALTER TABLE tracker_rows DROP COLUMN basis_revision',
      );
      await seeded.customStatement(
        'ALTER TABLE tracker_rows DROP COLUMN basis_revision_hash',
      );
      await seeded.customStatement('PRAGMA user_version = 81');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();

      for (final table in [
        'character_revision_rows',
        'applied_canon_transition_rows',
        'rewrite_jobs',
        'rewrite_operations',
        'rewrite_operation_revisions',
        'rewrite_evidence_rows',
        'canon_transition_fact_refs',
      ]) {
        final columns = await upgraded
            .customSelect("PRAGMA table_info('$table')")
            .get();
        expect(columns, isNotEmpty, reason: table);
      }
      for (final table in ['character_knowledge_fact_rows', 'tracker_rows']) {
        final columns = await upgraded
            .customSelect("PRAGMA table_info('$table')")
            .get();
        expect(
          columns.map((row) => row.read<String>('name')),
          containsAll(['basis_revision', 'basis_revision_hash']),
          reason: table,
        );
      }
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 85);
    });

    test('v83 rebuilds interim text revision columns without losing rows', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_revision_types_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });
      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      const tables = [
        'tracker_rows',
        'character_knowledge_fact_rows',
        'character_revision_rows',
        'applied_canon_transition_rows',
        'rewrite_jobs',
        'rewrite_operation_revisions',
      ];
      final schemas = <String, String>{};
      for (final table in tables) {
        final row = await seeded
            .customSelect(
              "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
              variables: [Variable.withString(table)],
            )
            .getSingle();
        schemas[table] = row.read<String>('sql');
        await seeded.customStatement('DROP TABLE $table');
      }
      for (final schema in schemas.values) {
        await seeded.customStatement(
          schema
              .replaceAll('basis_revision INTEGER', 'basis_revision TEXT')
              .replaceAll('revision INTEGER', 'revision TEXT'),
        );
      }
      await seeded.customStatement(
        "INSERT INTO tracker_rows (session_id, name, basis_revision) VALUES ('s', 't', '7')",
      );
      await seeded.customStatement(
        "INSERT INTO character_knowledge_fact_rows (id, chat_session_id, knower_key, subject_key, fact_class, predicate, object, epistemic_state, basis_revision) VALUES ('f', 's', 'k', 'subject', 'fact', 'p', 'o', 'known', '7')",
      );
      await seeded.customStatement(
        "INSERT INTO character_revision_rows (character_id, revision, revision_hash, snapshot_json) VALUES ('c', '7', 'hash', '{}')",
      );
      await seeded.customStatement(
        "INSERT INTO applied_canon_transition_rows (id, chat_session_id, character_id, transition_json, basis_revision) VALUES ('t', 's', 'c', '{}', '7')",
      );
      await seeded.customStatement(
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, basis_revision) VALUES ('j', 's', 'c', '7')",
      );
      await seeded.customStatement(
        "INSERT INTO rewrite_operation_revisions (rewrite_operation_id, revision, snapshot_json) VALUES ('o', '7', '{}')",
      );
      await seeded.customStatement('PRAGMA user_version = 82');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();
      for (final (table, column) in const [
        ('tracker_rows', 'basis_revision'),
        ('character_knowledge_fact_rows', 'basis_revision'),
        ('character_revision_rows', 'revision'),
        ('applied_canon_transition_rows', 'basis_revision'),
        ('rewrite_jobs', 'basis_revision'),
        ('rewrite_operation_revisions', 'revision'),
      ]) {
        final info = await upgraded
            .customSelect("PRAGMA table_info('$table')")
            .get();
        final type = info
            .singleWhere((row) => row.read<String>('name') == column)
            .read<String>('type');
        expect(type.toUpperCase(), 'INTEGER', reason: '$table.$column');
      }
      expect(
        await upgraded
            .customSelect('SELECT basis_revision FROM tracker_rows')
            .getSingle(),
        isNotNull,
      );
      final values = await upgraded.customSelect('''
        SELECT (SELECT basis_revision FROM tracker_rows) AS tracker,
               (SELECT basis_revision FROM character_knowledge_fact_rows) AS fact,
               (SELECT revision FROM character_revision_rows) AS character_revision,
               (SELECT basis_revision FROM applied_canon_transition_rows) AS transition,
               (SELECT basis_revision FROM rewrite_jobs) AS job,
               (SELECT revision FROM rewrite_operation_revisions) AS operation_revision
      ''').getSingle();
      for (final name in [
        'tracker',
        'fact',
        'character_revision',
        'transition',
        'job',
        'operation_revision',
      ]) {
        expect(values.read<int>(name), 7, reason: name);
      }
    });

    test(
      'v84 transition schema has queryable columns and lineage constraints',
      () async {
        final transitionColumns = await db
            .customSelect("PRAGMA table_info('applied_canon_transition_rows')")
            .get();
        final byName = {
          for (final row in transitionColumns) row.read<String>('name'): row,
        };
        expect(
          byName.keys,
          containsAll([
            'character_id',
            'chat_session_id',
            'rewrite_operation_id',
            'revision',
            'revision_hash',
            'semantic_scope_key',
            'canonical_claim',
            'promotion_destination',
            'affected_tracker_keys_json',
          ]),
        );
        expect(byName['chat_session_id']!.read<int>('notnull'), 0);
        expect(
          byName['revision']!.read<String>('type').toUpperCase(),
          'INTEGER',
        );
        final indexes = await db
            .customSelect("PRAGMA index_list('applied_canon_transition_rows')")
            .get();
        expect(
          indexes.map((row) => row.read<String>('name')),
          containsAll([
            'idx_applied_canon_transition_session',
            'idx_applied_canon_transition_character',
            'idx_applied_canon_transition_operation',
          ]),
        );

        final revisions = await db
            .customSelect("PRAGMA table_info('character_revision_rows')")
            .get();
        expect(
          revisions.map((row) => row.read<String>('name')),
          contains('parent_revision_hash'),
        );
        final revisionIndexes = await db
            .customSelect("PRAGMA index_list('character_revision_rows')")
            .get();
        expect(
          revisionIndexes.any((row) => row.read<int>('unique') == 1),
          isTrue,
        );
      },
    );

    test('v85 exposes durable rewrite CAS and apply columns', () async {
      final jobs = await db
          .customSelect("PRAGMA table_info('rewrite_jobs')")
          .get();
      final operations = await db
          .customSelect("PRAGMA table_info('rewrite_operations')")
          .get();
      expect(
        jobs.map((row) => row.read<String>('name')),
        containsAll([
          'version',
          'applied_character_revision',
          'applied_character_revision_hash',
        ]),
      );
      expect(
        operations.map((row) => row.read<String>('name')),
        containsAll([
          'current_revision',
          'decision',
          'validation_status',
          'decision_revision',
          'applied_character_revision',
          'applied_character_revision_hash',
        ]),
      );
      final indexes = await db
          .customSelect("PRAGMA index_list('rewrite_operations')")
          .get();
      expect(
        indexes.map((row) => row.read<String>('name')),
        contains('idx_rewrite_operation_apply_cas'),
      );

      for (final statement in [
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, decision) "
            "VALUES ('invalid-decision', 'j', 's', 'unknown')",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, validation_status) "
            "VALUES ('invalid-validation', 'j', 's', 'unknown')",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, current_revision) "
            "VALUES ('invalid-current-revision', 'j', 's', 0)",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, decision_revision) "
            "VALUES ('invalid-decision-revision', 'j', 's', -1)",
      ]) {
        await expectLater(db.customStatement(statement), throwsA(anything));
      }
    });

    test(
      'v85 rebuilds v84 rewrite operations with constraints and CAS index',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_rewrite_cas_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });
        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          'DROP INDEX idx_rewrite_operation_apply_cas',
        );
        await seeded.customStatement('DROP TABLE rewrite_operations');
        await seeded.customStatement('DROP TABLE rewrite_jobs');
        await seeded.customStatement('''
        CREATE TABLE rewrite_jobs (
          id TEXT NOT NULL PRIMARY KEY, chat_session_id TEXT NOT NULL,
          character_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
          request_json TEXT NOT NULL DEFAULT '{}', basis_revision INTEGER NOT NULL DEFAULT 0,
          basis_revision_hash TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT 0)
      ''');
        await seeded.customStatement('''
        CREATE TABLE rewrite_operations (
          id TEXT NOT NULL PRIMARY KEY, rewrite_job_id TEXT NOT NULL,
          chat_session_id TEXT NOT NULL, operation_json TEXT NOT NULL DEFAULT '{}',
          status TEXT NOT NULL DEFAULT 'pending', created_at INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT 0)
      ''');
        await seeded.customStatement(
          "INSERT INTO rewrite_jobs (id, chat_session_id, character_id) VALUES ('j', 's', 'c')",
        );
        await seeded.customStatement(
          "INSERT INTO rewrite_operations "
          "(id, rewrite_job_id, chat_session_id, operation_json, status, created_at, updated_at) "
          "VALUES ('o', 'j', 's', '{\"preserved\":true}', 'complete', 12, 34)",
        );
        await seeded.customStatement('PRAGMA user_version = 84');
        await seeded.close();
        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() => upgraded.close());
        final row = await upgraded.customSelect('''
        SELECT (SELECT version FROM rewrite_jobs WHERE id = 'j') AS job_version,
          (SELECT operation_json FROM rewrite_operations WHERE id = 'o') AS operation_json,
          (SELECT status FROM rewrite_operations WHERE id = 'o') AS status,
          (SELECT created_at FROM rewrite_operations WHERE id = 'o') AS created_at,
          (SELECT updated_at FROM rewrite_operations WHERE id = 'o') AS updated_at,
          (SELECT decision FROM rewrite_operations WHERE id = 'o') AS decision,
          (SELECT validation_status FROM rewrite_operations WHERE id = 'o') AS validation_status,
          (SELECT current_revision FROM rewrite_operations WHERE id = 'o') AS current_revision
      ''').getSingle();
        expect(row.read<int>('job_version'), 1);
        expect(row.read<String>('operation_json'), '{"preserved":true}');
        expect(row.read<String>('status'), 'complete');
        expect(row.read<int>('created_at'), 12);
        expect(row.read<int>('updated_at'), 34);
        expect(row.read<String>('decision'), 'pending');
        expect(row.read<String>('validation_status'), 'pending');
        expect(row.read<int>('current_revision'), 1);
        final indexes = await upgraded
            .customSelect("PRAGMA index_list('rewrite_operations')")
            .get();
        expect(
          indexes.map((index) => index.read<String>('name')),
          contains('idx_rewrite_operation_apply_cas'),
        );
        for (final statement in [
          "UPDATE rewrite_operations SET decision = 'unknown' WHERE id = 'o'",
          "UPDATE rewrite_operations SET validation_status = 'unknown' WHERE id = 'o'",
          "UPDATE rewrite_operations SET current_revision = 0 WHERE id = 'o'",
          "UPDATE rewrite_operations SET decision_revision = -1 WHERE id = 'o'",
        ]) {
          await expectLater(
            upgraded.customStatement(statement),
            throwsA(anything),
          );
        }
      },
    );

    test(
      'v84 upgrades a v83 transition row with defaults and preserved payload',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_transition_v84_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });
        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          'DROP TABLE applied_canon_transition_rows',
        );
        await seeded.customStatement('''
        CREATE TABLE applied_canon_transition_rows (
          id TEXT NOT NULL PRIMARY KEY,
          chat_session_id TEXT NOT NULL,
          character_id TEXT NOT NULL,
          transition_json TEXT NOT NULL,
          basis_revision INTEGER NOT NULL DEFAULT 0,
          basis_revision_hash TEXT NOT NULL DEFAULT '',
          applied_at INTEGER NOT NULL DEFAULT 0
        )
      ''');
        await seeded.customStatement('''
        INSERT INTO applied_canon_transition_rows
        (id, chat_session_id, character_id, transition_json, basis_revision,
         basis_revision_hash, applied_at)
        VALUES ('legacy-transition', 'legacy-session', 'legacy-character',
                '{"legacy":true}', 4, 'basis-hash', 5)
      ''');
        await seeded.customStatement('PRAGMA user_version = 83');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        final row = await upgraded.customSelect('''
        SELECT chat_session_id, character_id, transition_json, basis_revision,
               basis_revision_hash, rewrite_operation_id, revision,
               revision_hash, semantic_scope_key, canonical_claim,
               promotion_destination, affected_tracker_keys_json
        FROM applied_canon_transition_rows WHERE id = 'legacy-transition'
      ''').getSingle();
        expect(row.read<String>('chat_session_id'), 'legacy-session');
        expect(row.read<String>('character_id'), 'legacy-character');
        expect(row.read<String>('transition_json'), '{"legacy":true}');
        expect(row.read<int>('basis_revision'), 4);
        expect(row.read<String>('basis_revision_hash'), 'basis-hash');
        expect(row.read<String>('rewrite_operation_id'), '');
        expect(row.read<int>('revision'), 0);
        expect(row.read<String>('revision_hash'), '');
        expect(row.read<String>('semantic_scope_key'), '');
        expect(row.read<String>('canonical_claim'), '');
        expect(row.read<String>('promotion_destination'), '');
        expect(row.read<String>('affected_tracker_keys_json'), '[]');
      },
    );

    test('v70 refreshes only the default Ledger prompt block', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_ledger_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      final staleBlocks = [
        {
          'id': 'ledger_system',
          'name': 'Ledger system prompt',
          'kind': 'instruction',
          'role': 'system',
          'content': 'Promote facts into durableFacts.',
          'enabled': true,
          'order': 0,
          'section': 'ledger',
        },
        {
          'id': 'custom_block',
          'name': 'Custom block',
          'kind': 'instruction',
          'role': 'system',
          'content': 'keep this customization',
          'enabled': true,
          'order': 1,
          'section': 'ledger',
        },
      ];
      await seeded.customStatement(
        'INSERT INTO studio_preset_rows '
        '(preset_id, name, blocks_json, updated_at) VALUES (?, ?, ?, ?)',
        ['default', 'Default Studio Preset', jsonEncode(staleBlocks), 1],
      );
      await seeded.customStatement('PRAGMA user_version = 70');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 85);
      final row = await upgraded
          .customSelect(
            'SELECT blocks_json FROM studio_preset_rows WHERE preset_id = ?',
            variables: [Variable.withString('default')],
          )
          .getSingle();
      final blocks = (jsonDecode(row.read<String>('blocks_json')) as List)
          .cast<Map<String, dynamic>>();
      final ledger = blocks.singleWhere(
        (block) => block['id'] == 'ledger_system',
      );
      final custom = blocks.singleWhere(
        (block) => block['id'] == 'custom_block',
      );
      expect(ledger['content'], isNot(contains('durableFacts')));
      expect(ledger['enabled'], isTrue);
      expect(custom['content'], 'keep this customization');
      expect(
        blocks.any((block) => block['id'] == 'ledger_reconciliation_prompt'),
        isTrue,
      );
    });

    test('v73 enables Ledger prompt without replacing its text', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_ledger_prompts_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      final blocks = [
        {
          'id': 'ledger_system',
          'name': 'Ledger system prompt',
          'kind': 'instruction',
          'role': 'system',
          'content': 'custom Ledger prompt',
          'enabled': false,
          'order': 0,
          'section': 'ledger',
        },
        {
          'id': 'ledger_reconciliation_prompt',
          'name': 'Ledger reconciliation prompt',
          'kind': 'instruction',
          'role': 'system',
          'content': 'custom reconciliation prompt',
          'enabled': true,
          'order': 1,
          'section': 'ledger',
        },
      ];
      await seeded.customStatement(
        'INSERT INTO studio_preset_rows '
        '(preset_id, name, blocks_json, updated_at) VALUES (?, ?, ?, ?)',
        ['separate_prompts', 'Separate prompts', jsonEncode(blocks), 1],
      );
      await seeded.customStatement('PRAGMA user_version = 73');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final row = await upgraded
          .customSelect(
            'SELECT blocks_json FROM studio_preset_rows WHERE preset_id = ?',
            variables: [Variable.withString('separate_prompts')],
          )
          .getSingle();
      final upgradedBlocks =
          (jsonDecode(row.read<String>('blocks_json')) as List)
              .cast<Map<String, dynamic>>();
      final ledger = upgradedBlocks.singleWhere(
        (block) => block['id'] == 'ledger_system',
      );
      final reconciliation = upgradedBlocks.singleWhere(
        (block) => block['id'] == 'ledger_reconciliation_prompt',
      );

      expect(ledger['enabled'], isTrue);
      expect(ledger['content'], 'custom Ledger prompt');
      expect(reconciliation['enabled'], isTrue);
      expect(reconciliation['content'], 'custom reconciliation prompt');
    });

    test('v67 upgrades to atomic character fact schema', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_atomic_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement('PRAGMA user_version = 67');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 85);
      final check = await upgraded.customSelect('PRAGMA integrity_check').get();
      expect(check.single.read<String>('integrity_check'), 'ok');
    });

    test('memory catalog table exists in current schema', () async {
      final rows = await db
          .customSelect("PRAGMA table_info('memory_catalog_rows')")
          .get();
      final names = rows.map((c) => c.read<String>('name')).toSet();

      expect(names, contains('chat_session_id'));
      expect(names, contains('memory_entry_id'));
      expect(names, contains('entry_revision'));
      expect(names, contains('source_hash'));
      expect(names, contains('entities_json'));
      expect(names, contains('locations_json'));
      expect(names, contains('topics_json'));
      expect(names, contains('message_range_start'));
      expect(names, contains('message_range_end'));
      expect(names, contains('token_count'));
      expect(names, contains('abstract_text'));
      expect(names, contains('stale'));
    });

    test(
      'v66 removes agentic micro-memory without rewriting stored presets',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_agentic_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });

        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          '''INSERT INTO memory_book_rows
           (session_id, entries_json, pending_drafts_json, settings_json,
            last_processed_message_count, updated_at)
           VALUES (?, ?, ?, '{}', 0, 0)''',
          [
            'session-1',
            '[{"id":"agent-entry","source":"agentic"},'
                '{"id":"range-entry","source":"scan"},'
                '{"id":"ledger-entry","source":"studio_ledger"}]',
            '[{"id":"agent-draft","source":"agentic"},'
                '{"id":"scan-draft","source":"scan"}]',
          ],
        );
        await seeded.customStatement(
          '''INSERT INTO embeddings (entry_id, source_type, source_id)
           VALUES ('agent-entry', 'memory_entry', 'memorybook_session-1'),
                  ('range-entry', 'memory_entry', 'memorybook_session-1')''',
        );
        await seeded.customStatement('''INSERT INTO memory_catalog_rows
           (id, chat_session_id, memory_entry_id)
           VALUES ('cat-agent', 'session-1', 'agent-entry'),
                  ('cat-range', 'session-1', 'range-entry')''');
        await seeded.customStatement('''INSERT INTO memory_entity_rows
           (id, chat_session_id, memory_entry_id, name)
           VALUES ('entity-agent', 'session-1', 'agent-entry', 'drop'),
                  ('entity-range', 'session-1', 'range-entry', 'keep')''');
        await seeded.customStatement('''INSERT INTO memory_salience_rows
           (id, chat_session_id, memory_entry_id)
           VALUES ('salience-agent', 'session-1', 'agent-entry'),
                  ('salience-range', 'session-1', 'range-entry')''');
        await seeded.customStatement(
          '''INSERT INTO studio_preset_rows
           (preset_id, name, blocks_json, updated_at)
           VALUES (?, ?, ?, 0), (?, ?, ?, 0)''',
          [
            'legacy-write-loop',
            'Legacy write-loop',
            '[{"id":"writeloop_system","name":"Legacy",'
                '"content":"Use writeMemory and {{existingBlock}}."}]',
            'custom-tracker-loop',
            'Custom tracker loop',
            '[{"id":"writeloop_system","name":"Custom",'
                '"content":"Track only weather changes."}]',
          ],
        );
        await seeded.customStatement('PRAGMA user_version = 65');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        await upgraded.customSelect('SELECT 1').get();

        final row = await upgraded.customSelect(
          '''SELECT entries_json, pending_drafts_json
           FROM memory_book_rows WHERE session_id = 'session-1' ''',
        ).getSingle();
        expect(row.read<String>('entries_json'), contains('range-entry'));
        expect(row.read<String>('entries_json'), contains('ledger-entry'));
        expect(
          row.read<String>('entries_json'),
          isNot(contains('agent-entry')),
        );
        expect(row.read<String>('pending_drafts_json'), contains('scan-draft'));
        expect(
          row.read<String>('pending_drafts_json'),
          isNot(contains('agent-draft')),
        );

        for (final table in [
          'embeddings',
          'memory_catalog_rows',
          'memory_entity_rows',
          'memory_salience_rows',
        ]) {
          final rows = await upgraded
              .customSelect('SELECT * FROM $table')
              .get();
          expect(rows, hasLength(1), reason: table);
        }

        final presetRows = await upgraded.customSelect(
          '''SELECT preset_id, blocks_json FROM studio_preset_rows
           WHERE preset_id IN ('legacy-write-loop', 'custom-tracker-loop')''',
        ).get();
        final presets = {
          for (final preset in presetRows)
            preset.read<String>('preset_id'): preset.read<String>(
              'blocks_json',
            ),
        };
        expect(presets['legacy-write-loop'], contains('writeMemory'));
        expect(presets['legacy-write-loop'], contains('{{existingBlock}}'));
        expect(
          presets['custom-tracker-loop'],
          contains('Track only weather changes.'),
        );
      },
    );

    test(
      'post-restore purge removes reintroduced agentic micro-memory',
      () async {
        await db.customStatement(
          '''INSERT INTO memory_book_rows
           (session_id, entries_json, pending_drafts_json, settings_json,
            last_processed_message_count, updated_at)
           VALUES (?, ?, ?, '{}', 0, 0)''',
          [
            'restored-session',
            '[{"id":"restored-agent","source":"agentic"},'
                '{"id":"restored-range","source":"scan"}]',
            '[{"id":"restored-draft","source":"agentic"},'
                '{"id":"restored-scan-draft","source":"scan"}]',
          ],
        );
        await db.customStatement(
          '''INSERT INTO embeddings (entry_id, source_type, source_id)
           VALUES ('restored-agent', 'memory_entry',
                   'memorybook_restored-session'),
                  ('restored-range', 'memory_entry',
                   'memorybook_restored-session')''',
        );

        await db.purgeRetiredAgenticMicroMemory();

        final row = await db.customSelect(
          '''SELECT entries_json, pending_drafts_json
           FROM memory_book_rows WHERE session_id = 'restored-session' ''',
        ).getSingle();
        expect(
          row.read<String>('entries_json'),
          isNot(contains('restored-agent')),
        );
        expect(row.read<String>('entries_json'), contains('restored-range'));
        expect(
          row.read<String>('pending_drafts_json'),
          isNot(contains('restored-draft')),
        );
        expect(
          row.read<String>('pending_drafts_json'),
          contains('restored-scan-draft'),
        );
        final embeddings = await db
            .customSelect('SELECT entry_id FROM embeddings')
            .get();
        expect(embeddings.map((row) => row.read<String>('entry_id')), [
          'restored-range',
        ]);
      },
    );

    test('memory graph tables exist in current schema (v35)', () async {
      final entityCols = await db
          .customSelect("PRAGMA table_info('memory_entity_rows')")
          .get();
      final entityNames = entityCols.map((c) => c.read<String>('name')).toSet();
      expect(entityNames, contains('chat_session_id'));
      expect(entityNames, contains('memory_entry_id'));
      expect(entityNames, contains('name'));
      expect(entityNames, contains('entity_type'));
      expect(entityNames, contains('salience_avg'));
      expect(entityNames, contains('source_hash'));

      final salienceCols = await db
          .customSelect("PRAGMA table_info('memory_salience_rows')")
          .get();
      final salienceNames = salienceCols
          .map((c) => c.read<String>('name'))
          .toSet();
      expect(salienceNames, contains('chat_session_id'));
      expect(salienceNames, contains('memory_entry_id'));
      expect(salienceNames, contains('score'));
      expect(salienceNames, contains('emotional_tags_json'));
      expect(salienceNames, contains('narrative_flags_json'));

      final cadenceCols = await db
          .customSelect("PRAGMA table_info('memory_cadence_rows')")
          .get();
      final cadenceNames = cadenceCols
          .map((c) => c.read<String>('name'))
          .toSet();
      expect(cadenceNames, contains('chat_session_id'));
      expect(cadenceNames, contains('assistant_messages_since_last_run'));
      expect(cadenceNames, contains('last_run_kind'));

      final consolidationCols = await db
          .customSelect("PRAGMA table_info('memory_consolidation_rows')")
          .get();
      final consolidationNames = consolidationCols
          .map((c) => c.read<String>('name'))
          .toSet();
      expect(consolidationNames, contains('chat_session_id'));
      expect(consolidationNames, contains('tier'));
      expect(consolidationNames, contains('summary'));
      expect(consolidationNames, contains('status'));
      expect(consolidationNames, contains('error_message'));
    });
  });
}

Map<String, dynamic> _minimalBackup() => {
  'keyvalue': <String, dynamic>{},
  'localStorage': <String, dynamic>{},
  'characters': <dynamic>[],
  'personas': <dynamic>[],
};
