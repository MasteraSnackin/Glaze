import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_use_manifest_repo.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/prompt/exact_lorebook_manifest.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/card_rewriter/automated_card_evolution_service.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() => fixture.db.close());

  test('empty chat history makes zero executor calls', () async {
    await fixture.db.customStatement(
      "UPDATE chat_sessions SET messages_json = '[]' WHERE session_id = 'session'",
    );
    var calls = 0;
    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(result, isNull);
    expect(calls, 0);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('disabled automation makes zero claim or executor calls', () async {
    var calls = 0;
    final service = AutomatedCardEvolutionService(
      repo: fixture.repo,
      resolveModel: () async => throw StateError('must not resolve'),
      isEnabled: () => false,
      executor:
          ({
            required config,
            required prompt,
            required maxTokens,
            required temperature,
            required timeoutMs,
            cancelToken,
          }) async {
            calls++;
            return _ok(fixture.cardBatchOutput);
          },
    );

    expect(await service.runOneBatch('session'), isNull);
    expect(calls, 0);
    expect(
      await fixture.db.select(fixture.db.cardEvolutionClaims).get(),
      isEmpty,
    );
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('successful output persists a pending proposal', () async {
    var calls = 0;
    final result = await fixture
        .service((token, prompt) async {
          calls++;
          expect(token, isNotNull);
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(result?.kind, 'persisted');
    expect(calls, 1);
    expect(
      (await fixture.db.select(fixture.db.rewriteJobs).getSingle()).status,
      'pending',
    );
    expect(
      await fixture.db.select(fixture.db.cardEvolutionProposalRuns).get(),
      hasLength(1),
    );
    final operations = await fixture.db.select(fixture.db.rewriteOperations).get();
    expect(operations, hasLength(1));
    expect(
      operations
          .map(
            (operation) =>
                jsonDecode(operation.operationJson)['field'] as String,
          )
          .toSet(),
      {CardRewriteField.description.wireName},
    );
    await fixture.expectCanonRowsUnchanged();
  });

  test('model failure leaves no proposal', () async {
    final result = await fixture
        .service(
          (_, _) async =>
              const AuxCallOutcome(status: AgentOperationStatus.error),
        )
        .runOneBatch('session');
    expect(result, isNull);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('malformed parser output leaves no proposal or cursor', () async {
    final result = await fixture
        .service((_, _) async => _ok('not json'))
        .runOneBatch('session');
    expect(result, isNull);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test(
    'cancellation reaches dedicated token and leaves no proposal',
    () async {
      final started = Completer<CancelToken>();
      final release = Completer<AuxCallOutcome>();
      final service = fixture.service((token, _) {
        started.complete(token!);
        return release.future;
      });
      final future = service.runOneBatch('session');
      final token = await started.future;
      service.cancelSession('session');
      expect(token.isCancelled, isTrue);
      release.complete(
        const AuxCallOutcome(status: AgentOperationStatus.aborted),
      );
      expect(await future, isNull);
      await fixture.expectNoProposalOrCanonWrites();
    },
  );

  test(
    'canon changes after generation block proposal',
    () async {
      var changedCanon = false;
      final result = await fixture
          .service((_, prompt) async {
            if (!changedCanon) {
              changedCanon = true;
              await fixture.db.customStatement(
                "INSERT INTO tracker_rows (session_id, name, value, scope, provenance, updated_at) VALUES ('session', 'canon_lock:npc:alice', 'locked', 'ledger', 'manual', 2)",
              );
            }
            return _ok(fixture.cardBatchOutput);
          })
          .runOneBatch('session');
      expect(result?.kind, 'staleEvidence');
      await fixture.expectNoProposalOrCanonWrites();
    },
  );

  test('injected lorebook entries use a separate second call', () async {
    await _seedManifest(fixture.db, 'a1', 'entry one');
    var calls = 0;
    final result = await fixture
        .service((_, prompt) async {
          calls++;
          if (prompt.contains('Glaze lorebook rewriter')) {
            return _ok(fixture.lorebookBatchOutput);
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');

    expect(calls, 2);
    expect(result?.kind, 'persisted');
    final operations = await fixture.db.select(fixture.db.rewriteOperations).get();
    expect(operations, hasLength(2));
    expect(
      operations.map((operation) => jsonDecode(operation.operationJson)['target']),
      contains('lorebook'),
    );
  });
}

typedef _Executor =
    Future<AuxCallOutcome> Function(CancelToken? token, String prompt);

final class _Fixture {
  _Fixture(this.db, this.repo, this.revisionCount);

  final AppDatabase db;
  final CardEvolutionRepo repo;
  final int revisionCount;

  static Future<_Fixture> create() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final characters = CharacterRepo(db);
    final revisions = CharacterRevisionRepo(db);
    const character = Character(
      id: 'character',
      name: 'Card',
      description: 'Alice is cautious.',
    );
    await characters.put(character);
    final hash = CardCanonicalizer.sha256(character);
    await revisions.insert(
      CharacterRevisionRecord(
        characterId: 'character',
        revision: 1,
        revisionHash: hash,
        parentRevisionHash: '',
        snapshotJson: jsonEncode(character.toJson()),
        createdAt: 1,
      ),
    );
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES (?, ?, 0, ?)',
      ['session', 'character', jsonEncode(_messages)],
    );
    final reader = EffectiveCanonReadRepository(
      db: db,
      characterRepo: characters,
      revisionRepo: revisions,
      baselineRepo: CharacterSessionBaselineRepo(db),
      factRepo: CharacterKnowledgeFactRepo(db),
      transitionRepo: AppliedCanonTransitionRepo(db),
      transitionFactRefRepo: CanonTransitionFactRefRepo(db),
    );
    final jobs = ManualRewriteJobRepo(
      db: db,
      rawTrackerStateReader: LedgerRawTrackerStateReader(db),
    );
    final repo = CardEvolutionRepo(db: db, canonReader: reader, jobRepo: jobs);
    return _Fixture(db, repo, 1);
  }

  String get cardBatchOutput => jsonEncode({
    'operations': [
      {
        'field': CardRewriteField.description.wireName,
        'patches': [
          {
            'scopeKey': 'npc:alice',
            'anchor': 'cautious',
            'anchorSha256': CardCanonicalizer.scalarSha256('cautious'),
            'value': 'increasingly trusting',
          },
        ],
        'transition': {
          'id': 'transition',
          'scopeKey': 'npc:alice',
          'canonicalClaim': 'Alice is increasingly trusting.',
          'promotionDestination': 'card',
          'affectedTrackerKeys': <String>[],
          'factIds': <String>[],
          'chatSessionId': null,
        },
      },
    ],
  });

  String get lorebookBatchOutput => jsonEncode({
    'operations': [
      {
        'lorebookId': 'book-a1',
        'entryId': 'entry-a1',
        'baseContent': 'entry one',
        'expectedContentHash': CardCanonicalizer.scalarSha256('entry one'),
        'patches': [
          {
            'anchor': 'entry one',
            'anchorSha256': CardCanonicalizer.scalarSha256('entry one'),
            'value': 'entry one updated',
          },
        ],
      },
    ],
  });

  AutomatedCardEvolutionService service(_Executor executor) =>
      AutomatedCardEvolutionService(
        repo: repo,
        resolveModel: () async => const AuxApiConfig(
          endpoint: 'https://rewrite.example',
          apiKey: 'key',
          model: 'model',
          protocol: 'openai',
        ),
        executor:
            ({
              required config,
              required prompt,
              required maxTokens,
              required temperature,
              required timeoutMs,
              cancelToken,
            }) => executor(cancelToken, prompt),
      );

  Future<void> expectNoProposalOrCanonWrites() async {
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
    await expectCanonRowsUnchanged();
  }

  Future<void> expectCanonRowsUnchanged() async {
    expect(
      await db.select(db.characterRevisionRows).get(),
      hasLength(revisionCount),
    );
    expect(await db.select(db.characterSessionBaselineRows).get(), isEmpty);
  }
}

const _messages = [
  {'id': 'a1', 'role': 'assistant', 'content': 'assistant 1'},
  {'id': 'u1', 'role': 'user', 'content': 'user 1'},
  {'id': 'a2', 'role': 'assistant', 'content': 'assistant 2'},
  {'id': 'u2', 'role': 'user', 'content': 'user 2'},
];

Future<void> _seedManifest(
  AppDatabase db,
  String messageId,
  String content,
) async {
  final entry = ExactLorebookManifestEntry.fromMergedEntry(
    entry: LorebookEntry(
      id: 'entry-$messageId',
      lorebookId: 'book-$messageId',
      content: content,
      position: 'worldInfoBefore',
    ),
    source: 'keyword',
    classification: 'worldInfoBefore',
    injectionIndex: 0,
    renderedContent: content,
  );
  final manifest = ExactLorebookManifest(
    entries: [entry],
    promptProvenance: const ExactLorebookPromptProvenance(
      characterId: 'character',
      sessionId: 'session',
      presetSnapshotHash: 'preset',
    ),
    providerMessagesHash: 'prompt-$messageId',
  );
  final identity = LorebookUseGenerationIdentity(
    sessionId: 'session',
    messageId: messageId,
    swipeId: 0,
    agentSwipeId: 0,
  );
  final repo = LorebookUseManifestRepo(db);
  await repo.insertGenerationManifest(
    identity: identity,
    manifest: LorebookUseManifestInput(
      manifestJson: manifest.canonicalJson,
      manifestHash: manifest.canonicalHash,
      manifestSchemaVersion: 1,
      finalPromptHash: manifest.providerMessagesHash,
      presetSnapshotHash: manifest.promptProvenance.presetSnapshotHash,
    ),
    createdAt: 1,
    entries: [
      LorebookUseManifestEntryInput(
        lorebookId: entry.lorebookId,
        entryId: entry.entryId,
        entryOrder: 0,
        evidenceJson: jsonEncode(entry.toJson()),
      ),
    ],
  );
}

AuxCallOutcome _ok(String text) =>
    AuxCallOutcome(status: AgentOperationStatus.ok, text: text);
