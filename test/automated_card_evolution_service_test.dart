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
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
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
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_assembler.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() => fixture.db.close());

  test('not eligible makes zero executor calls', () async {
    var calls = 0;
    final result = await fixture.service((_) async {
      calls++;
      return _ok(fixture.validOutput);
    }).runOneBatch('session');
    expect(result, isNull);
    expect(calls, 0);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('successful output persists a pending proposal and cursor', () async {
    await fixture.makeEligible();
    var calls = 0;
    final result = await fixture.service((token) async {
      calls++;
      expect(token, isNotNull);
      return _ok(fixture.validOutput);
    }).runOneBatch('session');
    expect(result?.kind, 'persisted');
    expect(calls, 1);
    expect((await fixture.db.select(fixture.db.rewriteJobs).getSingle()).status,
        'pending');
    expect(await fixture.db.select(fixture.db.cardEvolutionProposalRuns).get(),
        hasLength(1));
    expect(await fixture.db.select(fixture.db.ledgerReconciliationCursors).get(),
        hasLength(1));
    await fixture.expectCanonRowsUnchanged();
  });

  test('model failure leaves no proposal or cursor', () async {
    await fixture.makeEligible();
    final result = await fixture.service((_) async => const AuxCallOutcome(
      status: AgentOperationStatus.error,
    )).runOneBatch('session');
    expect(result, isNull);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('malformed parser output leaves no proposal or cursor', () async {
    await fixture.makeEligible();
    final result = await fixture.service((_) async => _ok('not json'))
        .runOneBatch('session');
    expect(result, isNull);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('cancellation reaches dedicated token and leaves no proposal or cursor',
      () async {
    await fixture.makeEligible();
    final started = Completer<CancelToken>();
    final release = Completer<AuxCallOutcome>();
    final service = fixture.service((token) {
      started.complete(token!);
      return release.future;
    });
    final future = service.runOneBatch('session');
    final token = await started.future;
    service.cancelSession('session');
    expect(token.isCancelled, isTrue);
    release.complete(const AuxCallOutcome(
      status: AgentOperationStatus.aborted,
    ));
    expect(await future, isNull);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('canon change after generation returns stale with no proposal or cursor',
      () async {
    await fixture.makeEligible();
    final result = await fixture.service((_) async {
      await fixture.db.customStatement(
        "INSERT INTO tracker_rows (session_id, name, value, scope, provenance, updated_at) VALUES ('session', 'canon_lock:npc:alice', 'locked', 'ledger', 'manual', 2)",
      );
      return _ok(fixture.validOutput);
    }).runOneBatch('session');
    expect(result?.kind, 'staleCanon');
    await fixture.expectNoProposalOrCanonWrites();
  });
}

typedef _Executor = Future<AuxCallOutcome> Function(CancelToken? token);

final class _Fixture {
  _Fixture(this.db, this.repo, this.runs, this.revisionCount);

  final AppDatabase db;
  final CardEvolutionRepo repo;
  final LedgerReconciliationRunRepo runs;
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
    await revisions.insert(CharacterRevisionRecord(
      characterId: 'character',
      revision: 1,
      revisionHash: hash,
      parentRevisionHash: '',
      snapshotJson: jsonEncode(character.toJson()),
      createdAt: 1,
    ));
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
    return _Fixture(db, repo, LedgerReconciliationRunRepo(db), 1);
  }

  String get validOutput => jsonEncode({
    'field': 'description',
    'patches': [
      {
        'scopeKey': 'npc:alice',
        'anchor': 'cautious',
        'anchorSha256': CardCanonicalizer.scalarSha256('cautious'),
        'value': 'cautious but increasingly trusting',
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
        executor: ({
          required config,
          required prompt,
          required maxTokens,
          required temperature,
          required timeoutMs,
          cancelToken,
        }) => executor(cancelToken),
      );

  Future<void> makeEligible() async {
    await _seedManifest(db, 'a1', 'u1', 'entry one');
    await _seedManifest(db, 'a2', 'u2', 'entry two');
    final reader = repo.canonReader;
    final assembly = const EffectiveCanonAssembler().assemble(
      await reader.read(sessionId: 'session', characterId: 'character'),
    );
    var predecessor = '';
    for (var ordinal = 1; ordinal <= 2; ordinal++) {
      final manifest = await (db.select(db.lorebookUseManifests)
            ..where((row) => row.messageId.equals('a$ordinal')))
          .getSingle();
      final acceptance = await (db.select(db.lorebookUseAcceptanceRecords)
            ..where((row) => row.messageId.equals('a$ordinal')))
          .getSingle();
      final run = LedgerReconciliationRun(
        id: 'run-$ordinal',
        sessionId: 'session',
        ordinal: ordinal,
        anchors: [ReconciliationAnchor(
          messageId: 'a$ordinal',
          swipeId: 0,
          agentSwipeId: 0,
          role: 'assistant',
          contentHash: computeHash('assistant $ordinal'),
        )],
        acceptedManifestRefs: [AcceptedManifestRef(
          acceptanceId: acceptance.acceptanceId,
          sessionId: 'session',
          messageId: 'a$ordinal',
          swipeId: 0,
          agentSwipeId: 0,
          manifestHash: manifest.manifestHash,
          acceptedByUserMessageId: 'u$ordinal',
        )],
        effectiveCanonStamp: assembly.identity,
        effectiveCanonRevision: 1,
        effectiveCanonHash: assembly.effectiveRevision.hash,
        canonicalResult: {'ordinal': ordinal},
        predecessorChainHash: predecessor,
        contractVersion: 1,
        opsApplied: const [],
        createdAt: ordinal,
      );
      expect(await runs.append(run), isA<ReconciliationRunAppended>());
      predecessor = run.chainHash;
    }
  }

  Future<void> expectNoProposalOrCanonWrites() async {
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
    expect(await db.select(db.ledgerReconciliationCursors).get(), isEmpty);
    await expectCanonRowsUnchanged();
  }

  Future<void> expectCanonRowsUnchanged() async {
    expect(await db.select(db.characterRevisionRows).get(),
        hasLength(revisionCount));
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
  String userId,
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
    entries: [LorebookUseManifestEntryInput(
      lorebookId: entry.lorebookId,
      entryId: entry.entryId,
      entryOrder: 0,
      evidenceJson: jsonEncode(entry.toJson()),
    )],
  );
  await repo.insertVariationAcceptance(
    acceptanceId: 'accept-$messageId',
    identity: identity,
    acceptedByUserMessageId: userId,
    acceptedAt: 2,
  );
}

AuxCallOutcome _ok(String text) => AuxCallOutcome(
  status: AgentOperationStatus.ok,
  text: text,
);
