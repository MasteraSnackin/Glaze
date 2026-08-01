import 'dart:convert';

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
import 'package:glaze_flutter/core/llm/prompt/exact_lorebook_manifest.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_assembler.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

void main() {
  late AppDatabase db;
  late LedgerReconciliationRunRepo runs;
  late ManualRewriteJobRepo jobs;
  late CardEvolutionRepo evolution;
  late String canonStamp;
  late String canonHash;
  late Future<void> Function(int ordinal) appendRun;
  late LedgerReconciliationRun Function(
    int ordinal,
    String predecessor,
    AcceptedManifestRef? ref,
  ) makeRun;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final characters = CharacterRepo(db);
    final revisions = CharacterRevisionRepo(db);
    jobs = ManualRewriteJobRepo(
      db: db,
      rawTrackerStateReader: LedgerRawTrackerStateReader(db),
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
    evolution = CardEvolutionRepo(db: db, canonReader: reader, jobRepo: jobs);
    runs = LedgerReconciliationRunRepo(db);
    const character = Character(
      id: 'character',
      name: 'Card',
      description: 'Alice is cautious.',
    );
    await characters.put(character);
    canonHash = CardCanonicalizer.sha256(character);
    await revisions.insert(CharacterRevisionRecord(
      characterId: character.id,
      revision: 1,
      revisionHash: canonHash,
      parentRevisionHash: '',
      snapshotJson: jsonEncode(character.toJson()),
      createdAt: 1,
    ));
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES (?, ?, 0, ?)',
      ['session', 'character', jsonEncode(_messages)],
    );
    canonStamp = const EffectiveCanonAssembler()
        .assemble(await reader.read(sessionId: 'session', characterId: 'character'))
        .identity;
    await _seedManifest(db, 'a1', 'u1', 'entry one');
    await _seedManifest(db, 'a2', 'u2', 'entry two');
    makeRun = (ordinal, predecessor, ref) => LedgerReconciliationRun(
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
      acceptedManifestRefs: ref == null ? const [] : [ref],
      effectiveCanonStamp: canonStamp,
      effectiveCanonRevision: 1,
      effectiveCanonHash: canonHash,
      canonicalResult: {'ordinal': ordinal},
      predecessorChainHash: predecessor,
      contractVersion: 1,
      opsApplied: const [],
      createdAt: ordinal,
    );
    appendRun = (ordinal) async {
      final messageId = 'a$ordinal';
      final userId = 'u$ordinal';
      final manifest = await (db.select(db.lorebookUseManifests)
            ..where((row) => row.messageId.equals(messageId)))
          .getSingle();
      final acceptance = await (db.select(db.lorebookUseAcceptanceRecords)
            ..where((row) => row.messageId.equals(messageId)))
          .getSingle();
      final predecessor = ordinal == 1
          ? ''
          : (await db.select(db.ledgerReconciliationSuccessfulRuns).getSingle())
              .chainHash;
      final run = makeRun(ordinal, predecessor, AcceptedManifestRef(
        acceptanceId: acceptance.acceptanceId,
        sessionId: 'session',
        messageId: messageId,
        swipeId: 0,
        agentSwipeId: 0,
        manifestHash: manifest.manifestHash,
        acceptedByUserMessageId: userId,
      ));
      expect(await runs.append(run), isA<ReconciliationRunAppended>());
    };
  });

  tearDown(() => db.close());

  test('requires exactly two contiguous valid runs after cursor', () async {
    await appendRun(1);
    expect(await evolution.isEligible('session'), isFalse);
    await appendRun(2);
    expect(await evolution.isEligible('session'), isTrue);

    final claim = await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    );
    expect(claim.kind, 'claimed');
    expect(claim.claim!.row.firstRunId, 'run-1');
    expect(claim.claim!.row.secondRunId, 'run-2');
    expect(claim.claim!.selectedInputJson, contains('entry one'));
    expect(claim.claim!.selectedInputJson, contains('entry two'));
  });

  test('claim is exclusive, recoverable after expiry, and owner-idempotent', () async {
    await appendRun(1);
    await appendRun(2);
    final first = await evolution.claim(
      sessionId: 'session', ownerId: 'one', now: 10, leaseSeconds: 10);
    expect(first.kind, 'claimed');
    expect((await evolution.claim(
      sessionId: 'session', ownerId: 'one', now: 11, leaseSeconds: 10)).kind,
      'existing');
    expect((await evolution.claim(
      sessionId: 'session', ownerId: 'two', now: 11, leaseSeconds: 10)).kind,
      'busy');
    final recovered = await evolution.claim(
      sessionId: 'session', ownerId: 'two', now: 20, leaseSeconds: 10);
    expect(recovered.kind, 'claimed');
    expect(recovered.claim!.row.id, first.claim!.row.id);
    expect(recovered.claim!.row.ownerId, 'two');
  });

  test('finalize atomically writes pending review aggregate, provenance and cursor', () async {
    await appendRun(1);
    await appendRun(2);
    final claim = (await evolution.claim(
      sessionId: 'session', ownerId: 'owner', now: 10, leaseSeconds: 30)).claim!;
    final operation = _operation();
    final result = await evolution.finalize(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 11,
      modelOutput: '{"model":"raw"}',
      operation: operation,
    );
    expect(result.kind, 'persisted');
    expect(result.job!.status, 'pending');
    expect(jsonDecode(result.job!.requestJson), containsPair('provenance', 'automatedEvolution'));
    expect(await db.select(db.rewriteOperations).get(), hasLength(1));
    expect((await db.select(db.rewriteOperations).getSingle()).status, 'reviewable');
    expect(await db.select(db.rewriteOperationRevisions).get(), hasLength(1));
    expect(await db.select(db.rewriteEvidenceRows).get(), hasLength(1));
    expect(await db.select(db.cardEvolutionProposalRuns).get(), hasLength(1));
    expect((await runs.readCursors('session')).single.throughRunId, 'run-2');
    expect((await db.select(db.cardEvolutionClaims).getSingle()).status, 'completed');

    final replay = await evolution.finalize(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 12,
      modelOutput: 'different ignored replay',
      operation: operation,
    );
    expect(replay.kind, 'alreadyCompleted');
    expect(await db.select(db.rewriteJobs).get(), hasLength(1));
  });

  test('lease loss and invalidation leave no proposal or cursor', () async {
    await appendRun(1);
    await appendRun(2);
    final expired = (await evolution.claim(
      sessionId: 'session', ownerId: 'owner', now: 10, leaseSeconds: 1)).claim!;
    expect((await evolution.finalize(
      claimId: expired.row.id,
      ownerId: 'owner',
      now: 11,
      modelOutput: 'output',
      operation: _operation(),
    )).kind, 'leaseLost');
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.ledgerReconciliationCursors).get(), isEmpty);

    await db.customStatement(
      "INSERT INTO reconciliation_run_invalidations (session_id, run_id, cause_message_id, reason, created_at) VALUES ('session', 'run-2', 'a2', 'deleted', 12)",
    );
    expect((await evolution.finalize(
      claimId: expired.row.id,
      ownerId: 'owner',
      now: 10,
      modelOutput: 'output',
      operation: _operation(),
    )).kind, 'staleRuns');
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
  });

  test('unexpected failure rolls back job, evidence, output, cursor and claim CAS', () async {
    await appendRun(1);
    await appendRun(2);
    final reader = evolution.canonReader;
    evolution = CardEvolutionRepo(
      db: db,
      canonReader: reader,
      jobRepo: jobs,
      beforeCursorInsert: () async => throw StateError('injected'),
    );
    final claim = (await evolution.claim(
      sessionId: 'session', ownerId: 'owner', now: 10, leaseSeconds: 30)).claim!;
    await expectLater(
      evolution.finalize(
        claimId: claim.row.id,
        ownerId: 'owner',
        now: 11,
        modelOutput: 'output',
        operation: _operation(),
      ),
      throwsStateError,
    );
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
    expect(await db.select(db.rewriteOperationRevisions).get(), isEmpty);
    expect(await db.select(db.rewriteEvidenceRows).get(), isEmpty);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
    expect(await db.select(db.ledgerReconciliationCursors).get(), isEmpty);
    expect((await db.select(db.cardEvolutionClaims).getSingle()).status, 'claimed');
  });

  test('active manual job blocks claim and automated provenance cannot retry', () async {
    await appendRun(1);
    await appendRun(2);
    await jobs.createOrGet(
      chatSessionId: 'session',
      characterId: 'character',
      requestJson: '{}',
    );
    expect((await evolution.claim(
      sessionId: 'session', ownerId: 'owner', now: 10, leaseSeconds: 30)).kind,
      'activeJob');

    await db.customStatement('DELETE FROM rewrite_jobs');
    await db.customStatement(
      "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, status, request_json, version) VALUES ('auto', 'session', 'character', 'failed', '{\"provenance\":\"automatedEvolution\"}', 1)",
    );
    expect((await jobs.retry(jobId: 'auto', expectedVersion: 1)).kind, 'invalidState');
    expect((await db.select(db.rewriteJobs).getSingle()).status, 'failed');
  });

  test('malformed nonempty cursor fails closed instead of restarting at genesis', () async {
    await appendRun(1);
    await appendRun(2);
    await db.customStatement(
      "INSERT INTO ledger_reconciliation_cursors (session_id, sequence, predecessor_hash, through_run_id, through_run_ordinal, through_run_chain_hash, cursor_hash, created_at) VALUES ('session', 1, '', 'run-2', 2, 'wrong', 'wrong', 1)",
    );
    expect(await evolution.isEligible('session'), isFalse);
    expect((await evolution.claim(
      sessionId: 'session', ownerId: 'owner', now: 10, leaseSeconds: 30)).kind,
      'notEligible');
  });

  test('wrong accepting adjacency and malformed manifest fail closed', () async {
    await appendRun(1);
    await appendRun(2);
    await db.customStatement(
      'UPDATE chat_sessions SET messages_json = ?',
      [jsonEncode([
        _messages[0],
        {'id': 'intervening', 'role': 'assistant', 'content': 'other'},
        ..._messages.skip(1),
      ])],
    );
    expect(await evolution.isEligible('session'), isFalse);
    expect((await evolution.claim(
      sessionId: 'session', ownerId: 'owner', now: 10, leaseSeconds: 30)).kind,
      'notEligible');

    await db.customStatement(
      'UPDATE chat_sessions SET messages_json = ?',
      [jsonEncode(_messages)],
    );
    await db.customStatement('DROP TRIGGER lorebook_use_manifests_no_update');
    await db.customStatement(
      "UPDATE lorebook_use_manifests SET manifest_json = '{}' WHERE message_id = 'a1'",
    );
    expect((await evolution.claim(
      sessionId: 'session', ownerId: 'owner', now: 10, leaseSeconds: 30)).kind,
      'emptyAcceptedEvidence');
  });

  test('prompt snapshot is read-only and bound to claimed canon', () async {
    await appendRun(1);
    await appendRun(2);
    final claim = (await evolution.claim(
      sessionId: 'session', ownerId: 'owner', now: 10, leaseSeconds: 30)).claim!;
    final beforeRevisions = await db.select(db.characterRevisionRows).get();
    final snapshot = await evolution.readPromptSnapshot(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 11,
    );
    expect(snapshot?.character.description, 'Alice is cautious.');
    expect(snapshot?.selectedInputJson, contains('entry one'));
    expect(await db.select(db.characterRevisionRows).get(), beforeRevisions);
    expect(await db.select(db.characterSessionBaselineRows).get(), isEmpty);
  });

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
  final manifest = ExactLorebookManifest(
    entries: [ExactLorebookManifestEntry.fromMergedEntry(
      entry: LorebookEntry(
        id: 'entry-$messageId',
        lorebookId: 'book-$messageId',
        lorebookName: 'Book',
        comment: 'Evidence',
        content: content,
        position: 'worldInfoBefore',
      ),
      source: 'keyword',
      classification: 'worldInfoBefore',
      injectionIndex: 0,
      renderedContent: content,
    )],
    promptProvenance: const ExactLorebookPromptProvenance(
      characterId: 'character',
      sessionId: 'session',
      presetSnapshotHash: 'preset',
    ),
    providerMessagesHash: 'prompt-$messageId',
  );
  final repo = LorebookUseManifestRepo(db);
  final identity = LorebookUseGenerationIdentity(
    sessionId: 'session', messageId: messageId, swipeId: 0, agentSwipeId: 0);
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
      lorebookId: manifest.entries.single.lorebookId,
      entryId: manifest.entries.single.entryId,
      entryOrder: 0,
      evidenceJson: jsonEncode(manifest.entries.single.toJson()),
    )],
  );
  await repo.insertVariationAcceptance(
    acceptanceId: 'accept-$messageId',
    identity: identity,
    acceptedByUserMessageId: userId,
    acceptedAt: 2,
  );
}

CardRewriteOperationSnapshot _operation() => CardRewriteOperationSnapshot(
  field: CardRewriteField.description,
  patches: [AnchoredScalarPatch(
    scopeKey: 'npc:alice',
    field: CardRewriteField.description,
    anchor: 'cautious',
    anchorSha256: CardCanonicalizer.scalarSha256('cautious'),
    value: 'cautious but increasingly trusting',
  )],
  transition: const CardRewriteTransitionSnapshot(
    id: 'transition',
    scopeKey: 'npc:alice',
    canonicalClaim: 'Alice is increasingly trusting.',
    promotionDestination: 'card',
    affectedTrackerKeys: [],
    factIds: [],
  ),
);
