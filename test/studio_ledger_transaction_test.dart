import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/prompt/ledger_tracker_loader.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_reconciliation.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_service.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_context_loader.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_fence_resolver.dart';

final _memoryBookRepoProvider = Provider<MemoryBookRepo>(
  (ref) => throw UnimplementedError(),
);

const _response = '''
<glaze_memory_export>
{"ops":[{"op":"set","key":"world:time","value":"01:00","evidence":"clock changed","eventState":"completed"}],"knowledgeFacts":[{"knowerKey":"alice","subjectKey":"bob","predicate":"knows","object":"the plan"}]}
</glaze_memory_export>
<studio_ledger>updated</studio_ledger>
''';

const _reconciliationResponse = '''
<glaze_memory_export>
{"ops":[{"op":"set","key":"world:time","value":"02:00","evidence":"reviewed","eventState":"completed"}],"knowledgeFacts":[]}
</glaze_memory_export>
<studio_ledger>reviewed</studio_ledger>
<glaze_knowledge_cleanup>{"ops":[]}</glaze_knowledge_cleanup>
''';

void main() {
  late AppDatabase db;
  late CharacterRepo characters;
  late ChatRepo chats;
  late TrackerRepo trackers;
  late TrackerSnapshotRepo snapshots;
  late CharacterKnowledgeFactRepo facts;
  late LedgerReconciliationCheckpointRepo checkpoints;
  late AppliedCanonTransitionRepo transitions;
  late StudioLedgerService service;
  late ProviderContainer container;
  late Future<LedgerRunResult> Function(
    String, {
    FutureOr<bool> Function()? isStillCurrent,
  })
  run;
  late CharacterKnowledgeFact Function(String) fact;

  const character = Character(id: 'char', name: 'Alice', description: 'one');
  const assistant = ChatMessage(
    id: 'a1',
    role: 'assistant',
    content: 'Alice tells Bob the plan.',
  );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    characters = CharacterRepo(db);
    chats = ChatRepo(db);
    trackers = TrackerRepo(db);
    snapshots = TrackerSnapshotRepo(db);
    facts = CharacterKnowledgeFactRepo(db);
    checkpoints = LedgerReconciliationCheckpointRepo(db);
    transitions = AppliedCanonTransitionRepo(db);
    container = ProviderContainer(
      overrides: [
        _memoryBookRepoProvider.overrideWith((ref) => MemoryBookRepo(db, ref)),
      ],
    );
    await characters.put(character);
    await chats.put(
      const ChatSession(
        id: 'session',
        characterId: 'char',
        sessionIndex: 0,
        messages: [
          ChatMessage(id: 'u1', role: 'user', content: 'Start'),
          assistant,
        ],
      ),
    );
    final loader = EffectiveCanonContextLoader(
      db: db,
      characterRepo: characters,
      characterRevisionRepo: CharacterRevisionRepo(db),
      baselineRepo: CharacterSessionBaselineRepo(db),
      factRepo: facts,
      transitionRepo: transitions,
      transitionFactRefRepo: CanonTransitionFactRefRepo(db),
      loadRawTrackerState: (sessionId) async {
        final committed = await snapshots.getLatestCommitted(sessionId);
        final live = await trackers.getBySessionAndScope(sessionId, 'ledger');
        return LedgerRawTrackerState(
          committedTrackers:
              committed?.trackers
                  .where((tracker) => tracker.scope == 'ledger')
                  .toList() ??
              const [],
          manualControls: live
              .where((tracker) => tracker.name.startsWith('canon_'))
              .toList(),
        );
      },
    );
    service = StudioLedgerService(
      llm: const AuxLlmClient(),
      trackerRepo: trackers,
      bookRepo: container.read(_memoryBookRepoProvider),
      snapshotRepo: snapshots,
      knowledgeFactRepo: facts,
      reconciliationCheckpointRepo: checkpoints,
      characterRepo: characters,
      chatRepo: chats,
      canonContextLoader: loader,
    );
    run = (url, {isStillCurrent}) => service.run(
      sessionId: 'session',
      settings: const PipelineSettings(),
      config: _config(url),
      finalAssistantText: assistant.content,
      recentHistoryText: 'Start',
      messageId: 'a1',
      swipeId: 0,
      agentSwipeId: 0,
      isStillCurrent: isStillCurrent,
    );
    fact = (id) => CharacterKnowledgeFact(
      id: id,
      chatSessionId: 'session',
      knowerKey: 'alice',
      subjectKey: 'bob',
      factClass: CharacterKnowledgeFactClass.knowledge,
      predicate: 'knows',
      object: 'old',
      epistemicState: CharacterKnowledgeEpistemicState.observed,
      sourceMessageId: 'old',
      sourceSwipeId: 0,
      sourceAgentSwipeId: 0,
    );
  });

  tearDown(() {
    container.dispose();
    return db.close();
  });

  test(
    'canon changes after LLM completion abort normal commit without writes',
    () async {
      final endpoint = await _serve(_response);
      addTearDown(endpoint.close);
      var checks = 0;

      final result = await run(
        endpoint.url,
        isStillCurrent: () async {
          if (++checks == 3) {
            // This is the post-LLM guard. Exercise each stamp input without
            // changing the target itself; the transaction fence must reject it.
            await trackers.upsertValue(
              'session',
              'canon_override:world:time',
              'manual',
              scope: 'ledger',
            );
            await facts.insertTentative(fact('existing'));
            await transitions.insert(
              const AppliedCanonTransitionRecord(
                id: 'transition',
                characterId: 'char',
                chatSessionId: 'session',
                rewriteOperationId: 'rewrite',
                revision: 1,
                revisionHash: 'hash',
                semanticScopeKey: 'world',
                canonicalClaim: 'changed',
                promotionDestination: 'card',
                affectedTrackerKeys: ['world:time'],
                transitionJson: '{}',
              ),
            );
          }
          return true;
        },
      );

      expect(result.status, 'aborted');
      expect(await trackers.get('session', 'world:time'), isNull);
      expect(
        await facts.getBySourceAnchor(
          sessionId: 'session',
          messageId: 'a1',
          swipeId: 0,
          agentSwipeId: 0,
        ),
        isEmpty,
      );
      expect(
        await snapshots.getByAnchor(
          sessionId: 'session',
          messageId: 'a1',
          swipeId: 0,
          agentSwipeId: 0,
        ),
        isNull,
      );
    },
  );

  for (final mutation in [
    'same-ID tracker value',
    'fact lifecycle',
    'fact content',
    'transition claim',
    'transition scope',
    'transition affected key',
    'transition-fact ref',
  ]) {
    test(
      'normal commit aborts without output writes for $mutation stamp change',
      () async {
        await _seedStampMutationInput(
          mutation,
          snapshots: snapshots,
          facts: facts,
          transitions: transitions,
          db: db,
          fact: fact,
        );
        final endpoint = await _serve(_response);
        addTearDown(endpoint.close);
        var checks = 0;

        final result = await run(
          endpoint.url,
          isStillCurrent: () async {
            if (++checks == 3) {
              await _applyStampMutation(mutation, snapshots: snapshots, db: db);
            }
            return true;
          },
        );

        expect(result.status, 'aborted');
        expect(await trackers.get('session', 'world:time'), isNull);
        expect(
          await facts.getBySourceAnchor(
            sessionId: 'session',
            messageId: 'a1',
            swipeId: 0,
            agentSwipeId: 0,
          ),
          isEmpty,
        );
        expect(
          await snapshots.getByAnchor(
            sessionId: 'session',
            messageId: 'a1',
            swipeId: 0,
            agentSwipeId: 0,
          ),
          isNull,
        );
      },
    );
  }

  test(
    'target content or swipe changes at commit abort without writes',
    () async {
      for (final changed in [
        assistant.copyWith(content: 'swiped content'),
        assistant.copyWith(swipeId: 1),
      ]) {
        final endpoint = await _serve(_response);
        addTearDown(endpoint.close);
        var checks = 0;
        final result = await run(
          endpoint.url,
          isStillCurrent: () async {
            if (++checks == 3) {
              await chats.put(
                ChatSession(
                  id: 'session',
                  characterId: 'char',
                  sessionIndex: 0,
                  messages: [
                    const ChatMessage(id: 'u1', role: 'user', content: 'Start'),
                    changed,
                  ],
                ),
              );
            }
            return true;
          },
        );
        expect(result.status, 'aborted');
        expect(await trackers.get('session', 'world:time'), isNull);
        expect(
          await facts.getBySourceAnchor(
            sessionId: 'session',
            messageId: 'a1',
            swipeId: 0,
            agentSwipeId: 0,
          ),
          isEmpty,
        );
        expect(
          await snapshots.getByAnchor(
            sessionId: 'session',
            messageId: 'a1',
            swipeId: 0,
            agentSwipeId: 0,
          ),
          isNull,
        );
      }
    },
  );

  test(
    'normal transaction rolls back prior tracker and fact writes on snapshot failure',
    () async {
      final endpoint = await _serve(_response);
      addTearDown(endpoint.close);
      await db.customStatement(
        "CREATE TRIGGER fail_ledger_snapshot BEFORE INSERT ON tracker_snapshots BEGIN SELECT RAISE(ABORT, 'snapshot failure'); END",
      );

      expect((await run(endpoint.url)).status, 'error');
      expect(await trackers.get('session', 'world:time'), isNull);
      expect(
        await facts.getBySourceAnchor(
          sessionId: 'session',
          messageId: 'a1',
          swipeId: 0,
          agentSwipeId: 0,
        ),
        isEmpty,
      );
    },
  );

  test(
    'reconciliation transaction rolls back prior writes on checkpoint failure',
    () async {
      await snapshots.upsert(
        const TrackerSnapshot(
          sessionId: 'session',
          messageId: 'a1',
          swipeId: 0,
          agentSwipeId: 0,
          trackers: [],
          committed: true,
        ),
      );
      final endpoint = await _serve(_reconciliationResponse);
      addTearDown(endpoint.close);
      await db.customStatement(
        "CREATE TRIGGER fail_checkpoint BEFORE INSERT ON ledger_reconciliation_checkpoints BEGIN SELECT RAISE(ABORT, 'checkpoint failure'); END",
      );
      final plan = const LedgerReconciliationPlan(
        messages: [
          ChatMessage(id: 'u1', role: 'user', content: 'Start'),
          assistant,
        ],
        endMessage: assistant,
        rangeHash: 'range',
      );

      final result = await service.reconcile(
        sessionId: 'session',
        settings: const PipelineSettings(),
        config: _config(endpoint.url),
        plan: plan,
      );
      expect(result.status, 'error');
      expect(await trackers.get('session', 'world:time'), isNull);
      expect(await checkpoints.get('session'), isNull);
      final snapshot = await snapshots.getByAnchor(
        sessionId: 'session',
        messageId: 'a1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      expect(snapshot?.trackers, isEmpty);
    },
  );

  test(
    'canon changes after reconciliation LLM completion abort without writes',
    () async {
      await snapshots.upsert(
        const TrackerSnapshot(
          sessionId: 'session',
          messageId: 'a1',
          swipeId: 0,
          agentSwipeId: 0,
          trackers: [],
          committed: true,
        ),
      );
      final endpoint = await _serve(_reconciliationResponse);
      addTearDown(endpoint.close);
      var checks = 0;
      final plan = const LedgerReconciliationPlan(
        messages: [
          ChatMessage(id: 'u1', role: 'user', content: 'Start'),
          assistant,
        ],
        endMessage: assistant,
        rangeHash: 'range',
      );

      final result = await service.reconcile(
        sessionId: 'session',
        settings: const PipelineSettings(),
        config: _config(endpoint.url),
        plan: plan,
        isStillCurrent: () async {
          if (++checks == 6) {
            await trackers.upsertValue(
              'session',
              'canon_lock:world:time',
              'true',
              scope: 'ledger',
            );
            await facts.insertTentative(fact('reconciliation-existing'));
            await transitions.insert(
              const AppliedCanonTransitionRecord(
                id: 'reconciliation-transition',
                characterId: 'char',
                chatSessionId: 'session',
                rewriteOperationId: 'rewrite',
                revision: 1,
                revisionHash: 'hash',
                semanticScopeKey: 'world',
                canonicalClaim: 'changed',
                promotionDestination: 'card',
                affectedTrackerKeys: ['world:time'],
                transitionJson: '{}',
              ),
            );
          }
          return true;
        },
      );

      expect(result.status, 'aborted');
      expect(await trackers.get('session', 'world:time'), isNull);
      expect(await checkpoints.get('session'), isNull);
      final snapshot = await snapshots.getByAnchor(
        sessionId: 'session',
        messageId: 'a1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      expect(snapshot?.trackers, isEmpty);
    },
  );

  test(
    'successful commit stamps trackers, facts, and snapshot with captured revision',
    () async {
      final endpoint = await _serve(_response);
      addTearDown(endpoint.close);

      expect((await run(endpoint.url)).status, 'ok');
      final tracker = await trackers.get('session', 'world:time');
      final fact = (await facts.getBySourceAnchor(
        sessionId: 'session',
        messageId: 'a1',
        swipeId: 0,
        agentSwipeId: 0,
      )).single;
      final snapshot = await snapshots.getByAnchor(
        sessionId: 'session',
        messageId: 'a1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      final snapshotTracker = snapshot!.trackers.singleWhere(
        (item) => item.name == 'world:time',
      );
      expect(tracker!.basisRevisionNumber, 1);
      expect(fact.basisRevisionNumber, 1);
      expect(snapshotTracker.basisRevisionNumber, 1);
      expect(tracker.basisRevisionHash, isNotEmpty);
      expect(fact.basisRevisionHash, isNotEmpty);
      expect(snapshotTracker.basisRevisionHash, isNotEmpty);
      expect(snapshotTracker.basisRevisionHash, tracker.basisRevisionHash);
      expect(fact.basisRevisionHash, tracker.basisRevisionHash);
    },
  );
}

Future<void> _seedStampMutationInput(
  String mutation, {
  required AppDatabase db,
  required TrackerSnapshotRepo snapshots,
  required CharacterKnowledgeFactRepo facts,
  required AppliedCanonTransitionRepo transitions,
  required CharacterKnowledgeFact Function(String) fact,
}) async {
  if (mutation == 'same-ID tracker value') {
    await snapshots.upsert(
      const TrackerSnapshot(
        sessionId: 'session',
        messageId: 'prior',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: [
          Tracker(
            sessionId: 'session',
            name: 'scene:status',
            value: 'before',
            scope: 'ledger',
          ),
        ],
        committed: true,
      ),
    );
    return;
  }
  await facts.insertTentative(fact('stamp-fact'));
  if (mutation == 'fact lifecycle' || mutation == 'fact content') return;
  await transitions.insert(
    const AppliedCanonTransitionRecord(
      id: 'stamp-transition',
      characterId: 'char',
      chatSessionId: 'session',
      rewriteOperationId: 'rewrite',
      revision: 1,
      revisionHash: 'hash',
      semanticScopeKey: 'before-scope',
      canonicalClaim: 'before-claim',
      promotionDestination: 'card',
      affectedTrackerKeys: ['before-key'],
      transitionJson: '{}',
    ),
  );
  if (mutation == 'transition-fact ref') {
    await CanonTransitionFactRefRepo(db).insert(
      const CanonTransitionFactRef(
        transitionId: 'stamp-transition',
        factId: 'stamp-fact',
      ),
    );
  }
}

Future<void> _applyStampMutation(
  String mutation, {
  required AppDatabase db,
  required TrackerSnapshotRepo snapshots,
}) async {
  switch (mutation) {
    case 'same-ID tracker value':
      await snapshots.upsert(
        const TrackerSnapshot(
          sessionId: 'session',
          messageId: 'prior',
          swipeId: 0,
          agentSwipeId: 0,
          trackers: [
            Tracker(
              sessionId: 'session',
              name: 'scene:status',
              value: 'after',
              scope: 'ledger',
            ),
          ],
          committed: true,
        ),
      );
    case 'fact lifecycle':
      await db.customStatement(
        "UPDATE character_knowledge_fact_rows SET lifecycle = 'retracted' WHERE id = 'stamp-fact'",
      );
    case 'fact content':
      await db.customStatement(
        "UPDATE character_knowledge_fact_rows SET object = 'after' WHERE id = 'stamp-fact'",
      );
    case 'transition claim':
      await db.customStatement(
        "UPDATE applied_canon_transition_rows SET canonical_claim = 'after-claim' WHERE id = 'stamp-transition'",
      );
    case 'transition scope':
      await db.customStatement(
        "UPDATE applied_canon_transition_rows SET semantic_scope_key = 'after-scope' WHERE id = 'stamp-transition'",
      );
    case 'transition affected key':
      await db.customStatement(
        "UPDATE applied_canon_transition_rows SET affected_tracker_keys_json = '[\"after-key\"]' WHERE id = 'stamp-transition'",
      );
    case 'transition-fact ref':
      await db.customStatement(
        "UPDATE canon_transition_fact_refs SET character_knowledge_fact_id = 'after-fact' WHERE applied_canon_transition_id = 'stamp-transition' AND character_knowledge_fact_id = 'stamp-fact'",
      );
  }
}

AuxApiConfig _config(String endpoint) => AuxApiConfig(
  endpoint: endpoint,
  apiKey: 'test',
  model: 'test',
  protocol: 'openai',
);

Future<({String url, Future<void> Function() close})> _serve(
  String content,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.first.then((request) async {
      await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {'content': content},
            },
          ],
        }),
      );
      await request.response.close();
    }),
  );
  return (
    url: 'http://${server.address.host}:${server.port}',
    close: () => server.close(force: true),
  );
}
