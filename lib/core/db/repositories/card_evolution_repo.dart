import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../models/character.dart';
import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../services/card_rewriter/effective_canon_assembler.dart';
import '../../services/card_rewriter/effective_canon_read_repository.dart';
import '../../llm/prompt/exact_lorebook_manifest.dart';
import '../../utils/cast_helpers.dart';
import '../../utils/id_generator.dart';
import '../app_db.dart';
import 'manual_rewrite_job_repo.dart';
import 'session_lorebook_evolution_repo.dart';

const _maxChatHistoryMessages = 20;

final class CardEvolutionClaim {
  const CardEvolutionClaim({
    required this.row,
    required this.selectedInputJson,
  });
  final CardEvolutionClaimRow row;
  final String selectedInputJson;
}

final class CardEvolutionClaimOutcome {
  const CardEvolutionClaimOutcome(this.kind, [this.claim]);
  final String kind;
  final CardEvolutionClaim? claim;
  bool get isClaimed => kind == 'claimed' || kind == 'existing';
}

final class CardEvolutionPromptSnapshot {
  const CardEvolutionPromptSnapshot({
    required this.claim,
    required this.character,
    required this.selectedInputJson,
  });

  final CardEvolutionClaimRow claim;
  final Character character;
  final String selectedInputJson;
}

final class CardEvolutionFinalizeOutcome {
  const CardEvolutionFinalizeOutcome(this.kind, [this.job, this.detail]);
  final String kind;
  final RewriteJobRow? job;
  final String? detail;
  bool get isPersisted => kind == 'persisted' || kind == 'alreadyCompleted';
}

/// Owns eligibility, lease ownership and the all-or-nothing automated proposal
/// commit. The immutable chat-history snapshot is the primary evidence; the
/// current effective canon supplies Ledger's durable facts and tracker state.
class CardEvolutionRepo {
  CardEvolutionRepo({
    required this.db,
    required this.canonReader,
    required this.jobRepo,
    SessionLorebookEvolutionRepo? lorebookEvolutionRepo,
    @visibleForTesting this.beforeCursorInsert,
  }) : lorebookEvolutionRepo =
           lorebookEvolutionRepo ?? SessionLorebookEvolutionRepo(db);

  final AppDatabase db;
  final EffectiveCanonReadRepository canonReader;
  final ManualRewriteJobRepo jobRepo;
  final SessionLorebookEvolutionRepo lorebookEvolutionRepo;
  final Future<void> Function()? beforeCursorInsert;

  Future<bool> isEligible(String sessionId) =>
      db.transaction<bool>(() async => (await _selectInput(sessionId)) != null);

  Future<CardEvolutionClaimOutcome> claim({
    required String sessionId,
    required String ownerId,
    required int now,
    required int leaseSeconds,
  }) => db.transaction(() async {
    if (ownerId.isEmpty || leaseSeconds <= 0) {
      return const CardEvolutionClaimOutcome('invalidRequest');
    }
    final existing =
        await (db.select(db.cardEvolutionClaims)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where((row) => row.status.equals('claimed')))
            .getSingleOrNull();
    if (existing != null && existing.leaseExpiresAt > now) {
      if (existing.ownerId != ownerId) {
        return const CardEvolutionClaimOutcome('busy');
      }
      final selected = await _selectedInputForClaim(existing);
      return selected == null
          ? const CardEvolutionClaimOutcome('stale')
          : CardEvolutionClaimOutcome(
              'existing',
              CardEvolutionClaim(row: existing, selectedInputJson: selected),
            );
    }
    if (existing != null) {
      // An expired owner cannot finalize (finalize checks the same lease). Do
      // not reuse its snapshot: chat/canon may have advanced while the app was
      // closed, so drop the stale lease and create a fresh claim below.
      final deleted = await (db.delete(db.cardEvolutionClaims)
            ..where((row) => row.id.equals(existing.id))
            ..where((row) => row.status.equals('claimed'))
            ..where((row) => row.leaseExpiresAt.isSmallerOrEqualValue(now)))
          .go();
      if (deleted != 1) {
        return const CardEvolutionClaimOutcome('busy');
      }
    }
    final selected = await _selectInput(sessionId);
    if (selected == null) {
      return const CardEvolutionClaimOutcome('notEligible');
    }
    final session = await (db.select(
      db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
    if (session == null) return const CardEvolutionClaimOutcome('notFound');
    if (await _activeJob(sessionId, session.characterId) != null) {
      return const CardEvolutionClaimOutcome('activeJob');
    }
    final id = 'evolution-claim-${generateId()}';
    final inputHash = computeHash(selected);
    final snapshot = jsonDecode(selected) as Map<String, dynamic>;
    try {
      await db
          .into(db.cardEvolutionClaims)
          .insert(
            CardEvolutionClaimsCompanion.insert(
              id: id,
              sessionId: sessionId,
              characterId: session.characterId,
              ownerId: ownerId,
              status: 'claimed',
              leaseExpiresAt: now + leaseSeconds,
              chatHistoryHash: snapshot['chatHistoryHash'] as String,
              effectiveCanonIdentity:
                  snapshot['effectiveCanonIdentity'] as String,
              predecessorCursorHash: '',
              predecessorRunOrdinal: 0,
              inputHash: inputHash,
              createdAt: now,
            ),
          );
    } catch (_) {
      return const CardEvolutionClaimOutcome('busy');
    }
    final row = await (db.select(
      db.cardEvolutionClaims,
    )..where((item) => item.id.equals(id))).getSingle();
    return CardEvolutionClaimOutcome(
      'claimed',
      CardEvolutionClaim(row: row, selectedInputJson: selected),
    );
  });

  /// Returns the immutable, canon-bound prompt input for a live claimed lease.
  /// This path is read-only: it never reconciles source lineage or writes any
  /// baseline/canon state.
  Future<CardEvolutionPromptSnapshot?> readPromptSnapshot({
    required String claimId,
    required String ownerId,
    required int now,
  }) => db.transaction(() async {
    final claim = await (db.select(
      db.cardEvolutionClaims,
    )..where((row) => row.id.equals(claimId))).getSingleOrNull();
    if (claim == null ||
        claim.status != 'claimed' ||
        claim.ownerId != ownerId ||
        claim.leaseExpiresAt <= now) {
      return null;
    }
    final selected = await _selectedInputForClaim(claim);
    if (selected == null || computeHash(selected) != claim.inputHash) {
      return null;
    }
    final assembled = await _assemble(claim.sessionId, claim.characterId);
    if (assembled == null || assembled.$2.requiresBaselineDecision) {
      return null;
    }
    final assembly = assembled.$2;
    return CardEvolutionPromptSnapshot(
      claim: claim,
      character: assembly.character,
      selectedInputJson: selected,
    );
  });

  Future<CardEvolutionFinalizeOutcome> finalize({
    required String claimId,
    required String ownerId,
    required int now,
    required String modelOutput,
    required List<RewriteOperationSnapshot> operations,
  }) => db.transaction(() async {
    final claim = await (db.select(
      db.cardEvolutionClaims,
    )..where((row) => row.id.equals(claimId))).getSingleOrNull();
    if (claim == null) {
      return const CardEvolutionFinalizeOutcome('claimMissing');
    }
    if (claim.status == 'completed') {
      final job = claim.rewriteJobId == null
          ? null
          : await (db.select(db.rewriteJobs)
                  ..where((row) => row.id.equals(claim.rewriteJobId!)))
                .getSingleOrNull();
      return CardEvolutionFinalizeOutcome('alreadyCompleted', job);
    }
    if (claim.ownerId != ownerId || claim.leaseExpiresAt <= now) {
      return const CardEvolutionFinalizeOutcome('leaseLost');
    }
    final selected = await _selectedInputForClaim(claim);
    if (selected == null || computeHash(selected) != claim.inputHash) {
      return const CardEvolutionFinalizeOutcome('staleEvidence');
    }
    final assembled = await _assemble(claim.sessionId, claim.characterId);
    if (assembled == null || assembled.$2.requiresBaselineDecision) {
      return const CardEvolutionFinalizeOutcome('canonUnavailable');
    }
    final input = assembled.$1;
    final assembly = assembled.$2;
    final allowedCardFields = CardRewritePolicy.nonEmptyEvolutionFields(
      assembly.character,
    );
    if (!_hasEvolutionOperations(
      operations,
      allowedCardFields: allowedCardFields,
    )) {
      return const CardEvolutionFinalizeOutcome('fieldMismatch');
    }
    if (await _activeJob(claim.sessionId, claim.characterId) != null) {
      return const CardEvolutionFinalizeOutcome('activeJob');
    }
    final cardOperations = operations.whereType<CardRewriteOperationSnapshot>();
    final lorebookOperations = operations
        .whereType<LorebookRewriteOperationSnapshot>()
        .toList(growable: false);
    final allowedLoreTargets = _loreTargetsFromInput(selected);
    if (allowedLoreTargets == null ||
        lorebookOperations.any((operation) {
          final target = allowedLoreTargets[
              '${operation.lorebookId}\u0000${operation.entryId}'];
          return target == null ||
              target.$1 != operation.baseContent ||
              target.$2 != operation.expectedContentHash;
        })) {
      return const CardEvolutionFinalizeOutcome('invalidLorebookOperation');
    }
    final values = {
      for (final field in CardRewriteField.values)
        field: _fieldValue(assembly.character, field),
    };
    for (final operation in cardOperations) {
      final validation = AnchoredScalarPatchValidator.validate(
        patches: operation.patches,
        currentCardValues: values,
        fullCardBaselineSize: CardCanonicalizer.serialize(
          assembly.character,
        ).length,
        requiredFields: [operation.field],
      );
      if (!validation.isValid) {
        return CardEvolutionFinalizeOutcome(
          'invalidOperation',
          null,
          '${operation.field.wireName}: '
          '${validation.violations.map((violation) => violation.name).join(', ')}',
        );
      }
    }
    final controls = input.manualControls;
    final controlledKeys = {
      for (final operation in cardOperations) ...{
        operation.transition.scopeKey,
        ...operation.transition.affectedTrackerKeys,
        ...operation.patches.map((patch) => patch.scopeKey),
      },
    };
    if (controlledKeys.any(
      (key) => controls.any(
        (control) =>
            control.name == 'canon_override:$key' ||
            control.name == 'canon_lock:$key',
      ),
    )) {
      return const CardEvolutionFinalizeOutcome('manualControl');
    }

    final snapshots = [
      for (final operation in operations)
        RewriteOperationSnapshotCodec.encode(operation),
    ];
    final jobId = 'rewrite-job-${generateId()}';
    final operationId = 'rewrite-op-${generateId()}';
    final proposalId = 'evolution-run-${generateId()}';
    final job = await jobRepo.insertPendingInTransaction(
      jobId: jobId,
      chatSessionId: claim.sessionId,
      characterId: claim.characterId,
      requestJson: _canonicalJson({
        'fields': [
          for (final operation in cardOperations) operation.field.wireName,
        ],
        'lorebookTargets': [
          for (final operation in lorebookOperations)
            '${operation.lorebookId}:${operation.entryId}',
        ],
        'provenance': 'automatedEvolution',
        'claimId': claim.id,
        'inputHash': claim.inputHash,
      }),
      requestKey: 'automated-evolution:${claim.inputHash}',
      basisRevision: assembly.effectiveRevision.number,
      basisRevisionHash: assembly.effectiveRevision.hash,
      canonStamp: assembly.identity,
      operations: [
        for (var index = 0; index < snapshots.length; index++)
          ManualRewriteOperationDraft(
            id: index == 0 ? operationId : 'rewrite-op-${generateId()}',
            snapshotJson: snapshots[index],
            evidence: index == 0
                ? [
                    ManualRewriteEvidenceDraft(
                      id: 'rewrite-evidence-${generateId()}',
                      evidenceJson: selected,
                    ),
                  ]
                : const [],
          ),
      ],
      now: now,
    );
    await db
        .into(db.cardEvolutionProposalRuns)
        .insert(
          CardEvolutionProposalRunsCompanion.insert(
            id: proposalId,
            claimId: claim.id,
            sessionId: claim.sessionId,
            characterId: claim.characterId,
            rewriteJobId: jobId,
            chatHistoryHash: claim.chatHistoryHash,
            effectiveCanonIdentity: claim.effectiveCanonIdentity,
            selectedInputJson: selected,
            inputHash: claim.inputHash,
            modelOutput: modelOutput,
            modelOutputHash: computeHash(modelOutput),
            operationSnapshotJson: _canonicalJson(snapshots),
            createdAt: now,
          ),
        );
    await beforeCursorInsert?.call();
    final changed =
        await (db.update(db.cardEvolutionClaims)
              ..where((row) => row.id.equals(claim.id))
              ..where((row) => row.ownerId.equals(ownerId))
              ..where((row) => row.status.equals('claimed'))
              ..where((row) => row.leaseExpiresAt.isBiggerThanValue(now)))
            .write(
              CardEvolutionClaimsCompanion(
                status: const Value('completed'),
                rewriteJobId: Value(jobId),
                completedAt: Value(now),
              ),
            );
    if (changed != 1) throw StateError('evolution claim CAS changed');
    return CardEvolutionFinalizeOutcome('persisted', job);
  });

  /// Releases an uncompleted lease after work outside the transaction fails.
  /// Claims are otherwise retained only for successful idempotency records.
  Future<void> abandonClaim({
    required String claimId,
    required String ownerId,
  }) => db.transaction(() async {
    await (db.delete(db.cardEvolutionClaims)
          ..where((row) => row.id.equals(claimId))
          ..where((row) => row.ownerId.equals(ownerId))
          ..where((row) => row.status.equals('claimed')))
         .go();
  });

  /// Replaces the session's diagnostic record after every writer call. It is
  /// deliberately separate from the proposal transaction so rejected outputs
  /// and transport failures remain inspectable.
  Future<void> saveDebugRun({
    required String sessionId,
    required String stage,
    required String status,
    required String model,
    required String? output,
    required String attemptsJson,
    required int updatedAt,
  }) => db.into(db.cardEvolutionDebugRuns).insertOnConflictUpdate(
    CardEvolutionDebugRunsCompanion.insert(
      sessionId: sessionId,
      stage: stage,
      status: status,
      model: model,
      output: Value(output),
      attemptsJson: attemptsJson,
      updatedAt: updatedAt,
    ),
  );

  Future<String?> _selectedInputForClaim(CardEvolutionClaimRow claim) async {
    final selected = await _selectInput(claim.sessionId);
    if (selected == null || computeHash(selected) != claim.inputHash) {
      return null;
    }
    final snapshot = jsonDecode(selected) as Map<String, dynamic>;
    return snapshot['chatHistoryHash'] == claim.chatHistoryHash &&
            snapshot['effectiveCanonIdentity'] == claim.effectiveCanonIdentity
        ? selected
        : null;
  }

  Future<String?> _selectInput(String sessionId) async {
    try {
      final session =
           await (db.select(db.chatSessions)
                ..where((row) => row.sessionId.equals(sessionId)))
               .getSingleOrNull();
      if (session == null) return null;
      final messages = jsonDecode(session.messagesJson);
      if (messages is! List) return null;
      final assembled = await _assemble(sessionId, session.characterId);
      if (assembled == null || assembled.$2.requiresBaselineDecision) {
        return null;
      }
      final history = _selectChatHistory(messages: messages);
      if (history == null || history.length < 2) {
        return null;
      }
      final hasUser = history.any(
        (message) => message is Map && message['role'] == 'user',
      );
      final hasAssistant = history.any(
        (message) => message is Map && message['role'] == 'assistant',
      );
      if (!hasUser || !hasAssistant) {
        return null;
      }
      final lorebookEntries = await _selectInjectedLorebookEntries(
        sessionId: sessionId,
        history: history,
      );
      if (lorebookEntries == null) return null;
      final historyJson = _canonicalJson(history);
      final canonEvidence = _canonEvidence(assembled.$1, assembled.$2);
      final writableFields = CardRewritePolicy.nonEmptyEvolutionFields(
        assembled.$2.character,
      );
      return _canonicalJson({
        'contractVersion': 7,
        'fields': [
          for (final field in writableFields) field.wireName,
        ],
        'chatHistoryHash': computeHash(historyJson),
        'effectiveCanonIdentity': assembled.$2.identity,
        'limits': {
          'maxChatHistoryMessages': _maxChatHistoryMessages,
          'excludesTrailingUserAssistantPair': true,
        },
        'chatHistory': history,
        'card': _evolutionCardSnapshot(assembled.$2.character),
        'effectiveCanon': jsonDecode(canonEvidence),
        'injectedLorebookEntries': lorebookEntries,
      });
    } catch (_) {
      return null;
    }
  }

  Future<List<Object?>?> _selectInjectedLorebookEntries({
    required String sessionId,
    required List<Object?> history,
  }) async {
    final selected = <String, ExactLorebookManifestEntry>{};
    for (final item in history) {
      if (item is! Map || item['role'] != 'assistant') continue;
      final messageId = item['messageId'];
      final swipeId = item['swipeId'];
      final agentSwipeId = item['agentSwipeId'];
      if (messageId is! String || swipeId is! int || agentSwipeId is! int) {
        return null;
      }
      final row = await (db.select(db.lorebookUseManifests)
            ..where((value) => value.sessionId.equals(sessionId))
            ..where((value) => value.messageId.equals(messageId))
            ..where((value) => value.swipeId.equals(swipeId))
            ..where((value) => value.agentSwipeId.equals(agentSwipeId)))
          .getSingleOrNull();
      if (row == null) continue;
      try {
        final manifest = ExactLorebookManifest.decodeDurable(
          {
            ...Map<String, dynamic>.from(jsonDecode(row.manifestJson) as Map),
            'canonicalHash': row.manifestHash,
          },
        );
        for (final entry in manifest.entries) {
          selected['${entry.lorebookId}\u0000${entry.entryId}'] = entry;
        }
      } catch (_) {
        return null;
      }
    }
    final overlays = await lorebookEvolutionRepo.getByTargets(
      sessionId: sessionId,
      targets: [
        for (final entry in selected.values) (entry.lorebookId, entry.entryId),
      ],
    );
    return [
      for (final entry in selected.values)
        () {
          final overlay = overlays['${entry.lorebookId}\u0000${entry.entryId}'];
          final content = overlay?.content ?? entry.rawContent;
          return <String, Object?>{
            'lorebookId': entry.lorebookId,
            'entryId': entry.entryId,
            'baseContent': overlay?.baseContent ?? entry.rawContent,
            'content': content,
            'expectedContentHash': CardCanonicalizer.scalarSha256(content),
          };
        }(),
    ];
  }

  Future<(EffectiveCanonAssemblyInput, EffectiveCanonAssembly)?> _assemble(
    String sessionId,
    String characterId,
  ) async {
    try {
      final input = await canonReader.readInTransaction(
        sessionId: sessionId,
        characterId: characterId,
      );
      return (input, const EffectiveCanonAssembler().assemble(input));
    } catch (_) {
      return null;
    }
  }

  Future<RewriteJobRow?> _activeJob(String sessionId, String characterId) =>
      (db.select(db.rewriteJobs)
            ..where((row) => row.chatSessionId.equals(sessionId))
            ..where((row) => row.characterId.equals(characterId))
            ..where((row) => row.status.isIn(const ['generating', 'pending']))
            ..limit(1))
          .getSingleOrNull();

  List<Object?>? _selectChatHistory({
    required List<dynamic> messages,
  }) {
    final candidates = <Map<String, Object?>>[];
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      if (message is! Map || message['isHidden'] == true) continue;
      final id = message['id'];
      final role = message['role'];
      if (id is! String || (role != 'user' && role != 'assistant')) continue;
      final swipeId = message['swipeId'] as int? ?? 0;
      final agentSwipeId = message['agentSwipeId'] as int? ?? 0;
      final content = _anchoredContent(message, swipeId, agentSwipeId);
      if (content == null) return null;
      candidates.add({
        'messageId': id,
        'role': role,
        'swipeId': swipeId,
        'agentSwipeId': agentSwipeId,
        'content': content,
        'contentHash': computeHash(content),
      });
    }
    // The final assistant response remains mutable until the user follows up.
    // Its user prompt is omitted with it, so both chat evidence and the Ledger
    // snapshot describe only accepted turns.
    final stableCandidates = List<Map<String, Object?>>.from(candidates);
    if (stableCandidates.length >= 2 &&
        stableCandidates[stableCandidates.length - 2]['role'] == 'user' &&
        stableCandidates.last['role'] == 'assistant') {
      stableCandidates.removeRange(stableCandidates.length - 2, stableCandidates.length);
    }
    final start = stableCandidates.length > _maxChatHistoryMessages
        ? stableCandidates.length - _maxChatHistoryMessages
        : 0;
    final result = stableCandidates.sublist(start, stableCandidates.length);
    return result.isEmpty ? null : result;
  }

  String _canonEvidence(
    EffectiveCanonAssemblyInput input,
    EffectiveCanonAssembly assembly,
  ) => _canonicalJson({
    'identity': assembly.identity,
    'revision': {
      'number': assembly.effectiveRevision.number,
      'hash': assembly.effectiveRevision.hash,
    },
    'trackers': [
      for (final tracker in input.committedTrackers)
        {
          'name': tracker.name,
          'value': tracker.value,
          'scope': tracker.scope,
          'provenance': tracker.provenance,
        },
    ],
    'facts': [
      for (final fact in input.facts)
        {
          'scopeKey': fact.scopeKey,
          'predicate': fact.predicate,
          'object': fact.object,
          'epistemicState': fact.epistemicState.wireName,
          'confidence': fact.confidence,
          'importance': fact.importance,
        },
    ],
    'transitions': [
      for (final transition in input.transitions)
        {
          'scopeKey': transition.semanticScopeKey,
          'canonicalClaim': transition.canonicalClaim,
          'promotionDestination': transition.promotionDestination,
        },
    ],
  });
}

bool _hasEvolutionOperations(
  List<RewriteOperationSnapshot> operations, {
  required Set<CardRewriteField> allowedCardFields,
}) {
  final cards = operations.whereType<CardRewriteOperationSnapshot>().toList();
  final lores = operations
      .whereType<LorebookRewriteOperationSnapshot>()
      .toList();
  final fields = cards.map((operation) => operation.field).toSet();
  final targets = lores
      .map((operation) => '${operation.lorebookId}\u0000${operation.entryId}')
      .toSet();
  return operations.isNotEmpty &&
      fields.length == cards.length &&
      targets.length == lores.length &&
      allowedCardFields.containsAll(fields);
}

Map<String, (String, String)>? _loreTargetsFromInput(
  String selectedInputJson,
) {
  try {
    final input = jsonDecode(selectedInputJson) as Map;
    final entries = input['injectedLorebookEntries'];
    if (entries is! List) return null;
    final result = <String, (String, String)>{};
    for (final raw in entries) {
      if (raw is! Map ||
          raw['lorebookId'] is! String ||
          raw['entryId'] is! String ||
          raw['baseContent'] is! String ||
          raw['expectedContentHash'] is! String) {
        return null;
      }
      result['${raw['lorebookId']}\u0000${raw['entryId']}'] = (
        raw['baseContent'] as String,
        raw['expectedContentHash'] as String,
      );
    }
    return result;
  } catch (_) {
    return null;
  }
}

String? _anchoredContent(
  Map<Object?, Object?> message,
  int swipeId,
  int agentSwipeId,
) {
  final swipes = message['swipes'];
  final String content;
  if (swipes is List && swipes.isNotEmpty) {
    if (swipeId < 0 || swipeId >= swipes.length || swipes[swipeId] is! String) {
      return null;
    }
    content = swipes[swipeId] as String;
  } else {
    if (swipeId != 0 || message['content'] is! String) return null;
    content = message['content'] as String;
  }
  final agentSwipes = message['agentSwipes'];
  if (agentSwipes is List && agentSwipes.isNotEmpty) {
    if (agentSwipeId < 0 || agentSwipeId >= agentSwipes.length) return null;
    final agent = agentSwipes[agentSwipeId];
    return agent is Map && agent['content'] is String
        ? agent['content'] as String
        : null;
  }
  return agentSwipeId == 0 ? content : null;
}

String? _fieldValue(Character character, CardRewriteField field) =>
    switch (field) {
      CardRewriteField.description => character.description,
      CardRewriteField.personality => character.personality,
      CardRewriteField.scenario => character.scenario,
      CardRewriteField.systemPrompt => character.systemPrompt,
      CardRewriteField.postHistoryInstructions =>
        character.postHistoryInstructions,
      CardRewriteField.creatorNotes => character.creatorNotes,
    };

Map<String, Object?> _evolutionCardSnapshot(Character character) {
  final snapshot = Map<String, Object?>.from(
    CardCanonicalizer.snapshot(character),
  );
  final writableFields = CardRewritePolicy.nonEmptyEvolutionFields(character);
  for (final field in CardRewritePolicy.evolutionFields) {
    if (!writableFields.contains(field)) snapshot.remove(field.wireName);
  }
  return snapshot;
}

String _canonicalJson(Object? value) {
  Object? canonical(Object? item) {
    if (item is Map) {
      final keys = item.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: canonical(item[key])};
    }
    if (item is Iterable) return item.map(canonical).toList();
    return item;
  }

  return jsonEncode(canonical(value));
}
