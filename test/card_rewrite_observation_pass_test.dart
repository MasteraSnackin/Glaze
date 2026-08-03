import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_observation_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/automated_card_evolution_service.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() => fixture.db.close());

  test('zero reconciliation runs skips observation pass', () async {
    var calls = 0;
    await fixture
        .service((_, prompt) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(calls, 1);
    expect(
      await fixture.observationRepo.getActiveObservations('session'),
      isEmpty,
    );
  });

  test('odd reconciliation count skips observation pass', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    var calls = 0;
    await fixture
        .service((_, prompt) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(calls, 1);
  });

  test(
    'even reconciliation count runs observation pass before card writer',
    () async {
      await fixture.seedReconciliationRun(ordinal: 1);
      await fixture.seedReconciliationRun(ordinal: 2);
      final prompts = <String>[];
      await fixture
          .service((_, prompt) async {
            prompts.add(prompt);
            if (prompt.contains('observation journal keeper')) {
              return _ok(fixture.observationNewOutput);
            }
            return _ok(fixture.cardBatchOutput);
          })
          .runOneBatch('session');
      expect(prompts, hasLength(2));
      expect(prompts.first, contains('observation journal keeper'));
      expect(prompts.last, contains('Glaze card rewriter'));
      final active = await fixture.observationRepo.getActiveObservations(
        'session',
      );
      expect(active, hasLength(1));
      expect(active.first.semanticScopeKey, 'character.preference.trust');
      expect(active.first.status, 'active');
      expect(active.first.repeatCount, 1);
    },
  );

  test(
    'promoted observation appears as validated target in card writer prompt',
    () async {
      await fixture.observationRepo.insertObservation(
        CardEvolutionObservation(
          id: 'obs-promoted',
          sessionId: 'session',
          characterId: 'character',
          runOrdinal: 1,
          semanticScopeKey: 'character.preference.trust',
          observedChange: 'Alice is consistently more trusting',
          canonicalClaim: 'Alice has become more trusting',
          evidenceMessageIds: const ['a1', 'u1'],
          cardFieldPath: 'personality',
          confidence: 0.9,
          status: 'promoted',
          firstSeenRun: 1,
          repeatCount: 3,
          lastConfirmedRun: 3,
          createdAt: 10,
          updatedAt: 10,
        ),
      );
      String? cardPrompt;
      await fixture
          .service((_, prompt) async {
            if (!prompt.contains('observation journal keeper')) {
              cardPrompt = prompt;
            }
            return _ok(fixture.cardBatchOutput);
          })
          .runOneBatch('session');
      expect(cardPrompt, isNotNull);
      expect(
        cardPrompt,
        contains('Validated targets from observation journal'),
      );
      expect(cardPrompt, contains('character.preference.trust'));
    },
  );

  test('promotion after threshold confirmations', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    await fixture.observationRepo.insertObservation(
      CardEvolutionObservation(
        id: 'obs-1',
        sessionId: 'session',
        characterId: 'character',
        runOrdinal: 1,
        semanticScopeKey: 'character.preference.trust',
        observedChange: 'Alice is becoming more trusting',
        canonicalClaim: 'Alice has become more trusting',
        evidenceMessageIds: const ['a1'],
        cardFieldPath: 'personality',
        confidence: 0.8,
        status: 'active',
        firstSeenRun: 1,
        repeatCount: 2,
        lastConfirmedRun: 1,
        createdAt: 10,
        updatedAt: 10,
      ),
    );
    await fixture
        .service((_, prompt) async {
          if (prompt.contains('observation journal keeper')) {
            return _ok(fixture.observationConfirmOutput);
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    // The observation goes through the full cycle: confirm (repeatCount 3)
    // → promote → consume (after successful card writer apply).
    final obs = await fixture.observationRepo.findById('obs-1');
    expect(obs, isNotNull);
    expect(obs!.status, 'consumed');
    expect(obs.repeatCount, 3);
  });

  test('successful apply consumes promoted observations', () async {
    await fixture.observationRepo.insertObservation(
      CardEvolutionObservation(
        id: 'obs-promoted',
        sessionId: 'session',
        characterId: 'character',
        runOrdinal: 1,
        semanticScopeKey: 'character.preference.trust',
        observedChange: 'Alice is consistently more trusting',
        evidenceMessageIds: const ['a1'],
        confidence: 0.9,
        status: 'promoted',
        firstSeenRun: 1,
        repeatCount: 3,
        lastConfirmedRun: 3,
        createdAt: 10,
        updatedAt: 10,
      ),
    );
    final result = await fixture
        .service((_, _) async => _ok(fixture.cardBatchOutput))
        .runOneBatch('session');
    expect(result.kind, 'persisted');
    expect(
      await fixture.observationRepo.getPromotedObservations('session'),
      isEmpty,
    );
  });

  test('observation pass failure does not block card writer', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    var calls = 0;
    final result = await fixture
        .service((_, prompt) async {
          calls++;
          if (prompt.contains('observation journal keeper')) {
            return _ok('not valid json');
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(calls, 2);
    expect(result.kind, 'persisted');
    expect(
      await fixture.observationRepo.getActiveObservations('session'),
      isEmpty,
    );
  });

  test('expiry after runs without confirmation', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    await fixture.observationRepo.insertObservation(
      CardEvolutionObservation(
        id: 'obs-stale',
        sessionId: 'session',
        characterId: 'character',
        runOrdinal: 1,
        semanticScopeKey: 'character.preference.trust',
        observedChange: 'Alice is becoming more trusting',
        evidenceMessageIds: const ['a1'],
        confidence: 0.6,
        status: 'active',
        firstSeenRun: 1,
        repeatCount: 1,
        lastConfirmedRun: 1,
        createdAt: 10,
        updatedAt: 10,
      ),
    );
    await fixture
        .service(
          (_, _) async => _ok(fixture.cardBatchOutput),
          observationExpiryRuns: () => 4,
        )
        .runOneBatch('session');
    // runOrdinal = 2~/2 = 1. 1 - 1 = 0 < 4, so NOT expired yet.
    final active = await fixture.observationRepo.getActiveObservations(
      'session',
    );
    expect(active, hasLength(1));
  });
}

AuxCallOutcome _ok(String text) =>
    AuxCallOutcome(status: AgentOperationStatus.ok, text: text);

final class _Fixture {
  _Fixture(this.db, this.repo, this.observationRepo);

  final AppDatabase db;
  final CardEvolutionRepo repo;
  final CardEvolutionObservationRepo observationRepo;

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
    final observationRepo = CardEvolutionObservationRepo(db);
    return _Fixture(db, repo, observationRepo);
  }

  Future<void> seedReconciliationRun({required int ordinal}) async {
    await db.customStatement(
      'INSERT INTO reconciliation_successful_runs '
      '(id, session_id, ordinal, start_message_id, start_swipe_id, '
      'start_agent_swipe_id, end_message_id, end_swipe_id, '
      'end_agent_swipe_id, anchors_json, range_hash, '
      'accepted_manifest_refs_json, effective_canon_stamp, '
      'effective_canon_revision, effective_canon_hash, '
      'canonical_result_json, content_hash, predecessor_chain_hash, '
      'chain_hash, contract_version, ops_applied_json, created_at) '
      'VALUES (?, ?, ?, ?, 0, 0, ?, 0, 0, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, 1, ?, ?)',
      [
        'run-$ordinal',
        'session',
        ordinal,
        'a1',
        'a1',
        '[]',
        'range-$ordinal',
        '[]',
        'canon-stamp-$ordinal',
        'canon-hash-$ordinal',
        '{"result":"ok"}',
        'content-$ordinal',
        '',
        'chain-$ordinal',
        '[]',
        ordinal * 10,
      ],
    );
  }

  String get cardBatchOutput => jsonEncode({
    'operations': [
      {
        'field': CardRewriteField.description.wireName,
        'patches': [
          {
            'scopeKey': 'npc:alice',
            'anchor': 'Alice is cautious.',
            'anchorSha256': CardCanonicalizer.scalarSha256(
              'Alice is cautious.',
            ),
            'value': 'Alice is increasingly trusting.',
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

  String get observationNewOutput => jsonEncode({
    'observations': [
      {
        'action': 'new',
        'scopeKey': 'character.preference.trust',
        'observedChange': 'Alice is becoming more trusting',
        'canonicalClaim': 'Alice has become more trusting over time',
        'evidenceMessageIds': ['a1', 'u1'],
        'cardFieldPath': 'personality',
        'confidence': 0.8,
      },
    ],
  });

  String get observationConfirmOutput => jsonEncode({
    'observations': [
      {
        'action': 'confirm',
        'scopeKey': 'character.preference.trust',
        'observedChange': 'Alice is becoming more trusting',
        'confidence': 0.85,
      },
    ],
  });

  AutomatedCardEvolutionService service(
    Future<AuxCallOutcome> Function(CancelToken? token, String prompt)
    executor, {
    int Function()? observationExpiryRuns,
  }) => AutomatedCardEvolutionService(
    repo: repo,
    observationRepo: observationRepo,
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
    observationPromotionThreshold: () => 3,
    observationMinConfidence: () => 0.7,
    observationExpiryRuns: observationExpiryRuns ?? () => 4,
  );
}

const _messages = [
  {'id': 'a1', 'role': 'assistant', 'content': 'assistant 1'},
  {'id': 'u1', 'role': 'user', 'content': 'user 1'},
  {'id': 'a2', 'role': 'assistant', 'content': 'assistant 2'},
  {'id': 'u2', 'role': 'user', 'content': 'user 2'},
];
