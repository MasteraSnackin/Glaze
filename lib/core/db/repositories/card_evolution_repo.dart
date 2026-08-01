import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../llm/prompt/exact_lorebook_manifest.dart';
import '../../models/character.dart';
import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../services/card_rewriter/effective_canon_assembler.dart';
import '../../services/card_rewriter/effective_canon_read_repository.dart';
import '../../utils/cast_helpers.dart';
import '../../utils/id_generator.dart';
import '../app_db.dart';
import 'ledger_reconciliation_run_repo.dart';
import 'manual_rewrite_job_repo.dart';

const _maxManifests = 16;
const _maxEntries = 64;
const _maxEvidenceCodeUnits = 24000;

final class CardEvolutionClaim {
  const CardEvolutionClaim({required this.row, required this.selectedInputJson});
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
  const CardEvolutionFinalizeOutcome(this.kind, [this.job]);
  final String kind;
  final RewriteJobRow? job;
  bool get isPersisted => kind == 'persisted' || kind == 'alreadyCompleted';
}

/// Owns eligibility, lease ownership and the all-or-nothing automated proposal
/// commit. It reads only immutable accepted manifests referenced by journaled
/// reconciliation runs; it has no current-lorebook or retrieval dependency.
class CardEvolutionRepo {
  CardEvolutionRepo({
    required this.db,
    required this.canonReader,
    required this.jobRepo,
    @visibleForTesting this.beforeCursorInsert,
  });

  final AppDatabase db;
  final EffectiveCanonReadRepository canonReader;
  final ManualRewriteJobRepo jobRepo;
  final Future<void> Function()? beforeCursorInsert;

  Future<bool> isEligible(String sessionId) => db.transaction(() async {
    final pair = await _eligiblePair(sessionId);
    return pair != null && await _selectInput(pair.$1, pair.$2) != null;
  });

  Future<CardEvolutionClaimOutcome> claim({
    required String sessionId,
    required String ownerId,
    required int now,
    required int leaseSeconds,
  }) => db.transaction(() async {
    if (ownerId.isEmpty || leaseSeconds <= 0) {
      return const CardEvolutionClaimOutcome('invalidRequest');
    }
    final existing = await (db.select(db.cardEvolutionClaims)
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
      final pair = await _eligiblePair(sessionId);
      final selected = await _selectedInputForClaim(existing);
      final cursorState = await _cursorState(sessionId);
      final cursor = cursorState.$2;
      if (pair == null ||
          selected == null ||
          !cursorState.$1 ||
          pair.$1.id != existing.firstRunId ||
          pair.$2.id != existing.secondRunId ||
          (cursor?.cursorHash ?? '') != existing.predecessorCursorHash ||
          (cursor?.throughRunOrdinal ?? 0) !=
              existing.predecessorRunOrdinal) {
        return const CardEvolutionClaimOutcome('stale');
      }
      final changed = await (db.update(db.cardEvolutionClaims)
            ..where((row) => row.id.equals(existing.id))
            ..where((row) => row.status.equals('claimed'))
            ..where(
              (row) => row.leaseExpiresAt.isSmallerOrEqualValue(now),
            ))
          .write(
            CardEvolutionClaimsCompanion(
              ownerId: Value(ownerId),
              leaseExpiresAt: Value(now + leaseSeconds),
            ),
          );
      if (changed != 1) {
        return const CardEvolutionClaimOutcome('busy');
      }
      final recovered = await (db.select(db.cardEvolutionClaims)
            ..where((row) => row.id.equals(existing.id)))
          .getSingle();
      return CardEvolutionClaimOutcome(
        'claimed',
        CardEvolutionClaim(row: recovered, selectedInputJson: selected),
      );
    }
    final pair = await _eligiblePair(sessionId);
    if (pair == null) return const CardEvolutionClaimOutcome('notEligible');
    final selected = await _selectInput(pair.$1, pair.$2);
    if (selected == null) {
      return const CardEvolutionClaimOutcome('emptyAcceptedEvidence');
    }
    final session = await (db.select(db.chatSessions)
          ..where((row) => row.sessionId.equals(sessionId)))
        .getSingleOrNull();
    if (session == null) return const CardEvolutionClaimOutcome('notFound');
    if (await _activeJob(sessionId, session.characterId) != null) {
      return const CardEvolutionClaimOutcome('activeJob');
    }
    final cursorState = await _cursorState(sessionId);
    if (!cursorState.$1) {
      return const CardEvolutionClaimOutcome('staleCursor');
    }
    final predecessor = cursorState.$2;
    final id = 'evolution-claim-${generateId()}';
    final inputHash = computeHash(selected);
    try {
      await db.into(db.cardEvolutionClaims).insert(
            CardEvolutionClaimsCompanion.insert(
              id: id,
              sessionId: sessionId,
              characterId: session.characterId,
              ownerId: ownerId,
              status: 'claimed',
              leaseExpiresAt: now + leaseSeconds,
              firstRunId: pair.$1.id,
              secondRunId: pair.$2.id,
              predecessorCursorHash: predecessor?.cursorHash ?? '',
              predecessorRunOrdinal: predecessor?.throughRunOrdinal ?? 0,
              inputHash: inputHash,
              createdAt: now,
            ),
          );
    } catch (_) {
      return const CardEvolutionClaimOutcome('busy');
    }
    final row = await (db.select(db.cardEvolutionClaims)
          ..where((item) => item.id.equals(id)))
        .getSingle();
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
    final claim = await (db.select(db.cardEvolutionClaims)
          ..where((row) => row.id.equals(claimId)))
        .getSingleOrNull();
    if (claim == null ||
        claim.status != 'claimed' ||
        claim.ownerId != ownerId ||
        claim.leaseExpiresAt <= now) {
      return null;
    }
    final pair = await _eligiblePair(claim.sessionId);
    if (pair == null ||
        pair.$1.id != claim.firstRunId ||
        pair.$2.id != claim.secondRunId) {
      return null;
    }
    final selected = await _selectInput(pair.$1, pair.$2);
    if (selected == null || computeHash(selected) != claim.inputHash) {
      return null;
    }
    final assembled = await _assemble(claim.sessionId, claim.characterId);
    if (assembled == null || assembled.$2.requiresBaselineDecision) {
      return null;
    }
    final assembly = assembled.$2;
    if (assembly.identity != pair.$2.effectiveCanonStamp ||
        assembly.effectiveRevision.number != pair.$2.effectiveCanonRevision ||
        assembly.effectiveRevision.hash != pair.$2.effectiveCanonHash) {
      return null;
    }
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
    required CardRewriteOperationSnapshot operation,
  }) => db.transaction(() async {
    final claim = await (db.select(db.cardEvolutionClaims)
          ..where((row) => row.id.equals(claimId)))
        .getSingleOrNull();
    if (claim == null) return const CardEvolutionFinalizeOutcome('claimMissing');
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
    if (operation.field != CardRewriteField.description) {
      return const CardEvolutionFinalizeOutcome('fieldMismatch');
    }
    final pair = await _eligiblePair(claim.sessionId);
    if (pair == null ||
        pair.$1.id != claim.firstRunId ||
        pair.$2.id != claim.secondRunId) {
      return const CardEvolutionFinalizeOutcome('staleRuns');
    }
    final cursorState = await _cursorState(claim.sessionId);
    if (!cursorState.$1) {
      return const CardEvolutionFinalizeOutcome('staleCursor');
    }
    final predecessor = cursorState.$2;
    if ((predecessor?.cursorHash ?? '') != claim.predecessorCursorHash ||
        (predecessor?.throughRunOrdinal ?? 0) != claim.predecessorRunOrdinal) {
      return const CardEvolutionFinalizeOutcome('staleCursor');
    }
    final selected = await _selectInput(pair.$1, pair.$2);
    if (selected == null || computeHash(selected) != claim.inputHash) {
      return const CardEvolutionFinalizeOutcome('staleEvidence');
    }
    final assembled = await _assemble(claim.sessionId, claim.characterId);
    if (assembled == null || assembled.$2.requiresBaselineDecision) {
      return const CardEvolutionFinalizeOutcome('canonUnavailable');
    }
    final input = assembled.$1;
    final assembly = assembled.$2;
    if (assembly.identity != pair.$2.effectiveCanonStamp ||
        assembly.effectiveRevision.number != pair.$2.effectiveCanonRevision ||
        assembly.effectiveRevision.hash != pair.$2.effectiveCanonHash) {
      return const CardEvolutionFinalizeOutcome('staleCanon');
    }
    if (await _activeJob(claim.sessionId, claim.characterId) != null) {
      return const CardEvolutionFinalizeOutcome('activeJob');
    }
    final validation = AnchoredScalarPatchValidator.validate(
      patches: operation.patches,
      currentCardValues: {
        for (final field in CardRewriteField.values)
          field: _fieldValue(assembly.character, field),
      },
      fullCardBaselineSize: CardCanonicalizer.serialize(assembly.character).length,
      requiredFields: const [CardRewriteField.description],
    );
    if (!validation.isValid) {
      return const CardEvolutionFinalizeOutcome('invalidOperation');
    }
    final controls = input.manualControls;
    final controlledKeys = {
      operation.transition.scopeKey,
      ...operation.transition.affectedTrackerKeys,
      ...operation.patches.map((patch) => patch.scopeKey),
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

    final snapshot = ManualRewriteOperationSnapshotCodec.encode(operation);
    final jobId = 'rewrite-job-${generateId()}';
    final operationId = 'rewrite-op-${generateId()}';
    final proposalId = 'evolution-run-${generateId()}';
    final job = await jobRepo.insertPendingInTransaction(
      jobId: jobId,
      operationId: operationId,
      chatSessionId: claim.sessionId,
      characterId: claim.characterId,
      requestJson: _canonicalJson({
        'field': CardRewriteField.description.wireName,
        'provenance': 'automatedEvolution',
        'claimId': claim.id,
        'inputHash': claim.inputHash,
      }),
      requestKey: 'automated-evolution:${claim.inputHash}',
      basisRevision: assembly.effectiveRevision.number,
      basisRevisionHash: assembly.effectiveRevision.hash,
      canonStamp: assembly.identity,
      snapshotJson: snapshot,
      evidence: [
        ManualRewriteEvidenceDraft(
          id: 'rewrite-evidence-${generateId()}',
          evidenceJson: selected,
        ),
      ],
      now: now,
    );
    await db.into(db.cardEvolutionProposalRuns).insert(
          CardEvolutionProposalRunsCompanion.insert(
            id: proposalId,
            claimId: claim.id,
            sessionId: claim.sessionId,
            characterId: claim.characterId,
            rewriteJobId: jobId,
            firstRunId: claim.firstRunId,
            secondRunId: claim.secondRunId,
            selectedInputJson: selected,
            inputHash: claim.inputHash,
            modelOutput: modelOutput,
            modelOutputHash: computeHash(modelOutput),
            operationSnapshotJson: snapshot,
            createdAt: now,
          ),
        );
    await beforeCursorInsert?.call();
    final sequence = (predecessor?.sequence ?? 0) + 1;
    final cursorHash = computeHash(_canonicalJson({
      'sessionId': claim.sessionId,
      'sequence': sequence,
      'predecessorHash': predecessor?.cursorHash ?? '',
      'throughRunId': pair.$2.id,
      'throughRunOrdinal': pair.$2.ordinal,
      'throughRunChainHash': pair.$2.chainHash,
    }));
    await db.into(db.ledgerReconciliationCursors).insert(
          LedgerReconciliationCursorsCompanion.insert(
            sessionId: claim.sessionId,
            sequence: sequence,
            predecessorHash: predecessor?.cursorHash ?? '',
            throughRunId: pair.$2.id,
            throughRunOrdinal: pair.$2.ordinal,
            throughRunChainHash: pair.$2.chainHash,
            cursorHash: cursorHash,
            createdAt: now,
          ),
        );
    final changed = await (db.update(db.cardEvolutionClaims)
          ..where((row) => row.id.equals(claim.id))
          ..where((row) => row.ownerId.equals(ownerId))
          ..where((row) => row.status.equals('claimed'))
          ..where((row) => row.leaseExpiresAt.isBiggerThanValue(now)))
        .write(CardEvolutionClaimsCompanion(
          status: const Value('completed'),
          rewriteJobId: Value(jobId),
          completedAt: Value(now),
        ));
    if (changed != 1) throw StateError('evolution claim CAS changed');
    return CardEvolutionFinalizeOutcome('persisted', job);
  });

  Future<(LedgerReconciliationSuccessfulRunRow,
      LedgerReconciliationSuccessfulRunRow)?> _eligiblePair(String sessionId) async {
    final runRepo = LedgerReconciliationRunRepo(db);
    if (await runRepo.validateChain(sessionId) is! ReconciliationRunValid) {
      return null;
    }
    final cursorState = await _cursorState(sessionId);
    if (!cursorState.$1) return null;
    final cursor = cursorState.$2;
    final after = cursor?.throughRunOrdinal ?? 0;
    final rows = await (db.select(db.ledgerReconciliationSuccessfulRuns)
          ..where((row) => row.sessionId.equals(sessionId))
          ..where((row) => row.ordinal.isBiggerThanValue(after))
          ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
        .get();
    if (rows.length < 2 || rows[0].ordinal != after + 1 || rows[1].ordinal != after + 2) {
      return null;
    }
    final invalidations = await (db.select(db.ledgerReconciliationRunInvalidations)
          ..where((row) => row.sessionId.equals(sessionId))
          ..where((row) => row.runId.isIn([rows[0].id, rows[1].id])))
        .get();
    if (invalidations.isNotEmpty ||
        rows[0].chainHash != rows[1].predecessorChainHash ||
        rows[0].effectiveCanonStamp != rows[1].effectiveCanonStamp ||
        rows[0].effectiveCanonRevision != rows[1].effectiveCanonRevision ||
        rows[0].effectiveCanonHash != rows[1].effectiveCanonHash) {
      return null;
    }
    return (rows[0], rows[1]);
  }

  Future<(bool, LedgerReconciliationCursorRow?)> _cursorState(
    String sessionId,
  ) async {
    final cursors = await LedgerReconciliationRunRepo(db).readCursors(sessionId);
    if (cursors.isNotEmpty) return (true, cursors.last);
    final physical = await (db.select(db.ledgerReconciliationCursors)
          ..where((row) => row.sessionId.equals(sessionId))
          ..limit(1))
        .getSingleOrNull();
    return (physical == null, null);
  }

  Future<String?> _selectedInputForClaim(CardEvolutionClaimRow claim) async {
    final first = await (db.select(db.ledgerReconciliationSuccessfulRuns)
          ..where((row) => row.id.equals(claim.firstRunId)))
        .getSingleOrNull();
    final second = await (db.select(db.ledgerReconciliationSuccessfulRuns)
          ..where((row) => row.id.equals(claim.secondRunId)))
        .getSingleOrNull();
    if (first == null || second == null) return null;
    final selected = await _selectInput(first, second);
    return selected != null && computeHash(selected) == claim.inputHash
        ? selected
        : null;
  }

  Future<String?> _selectInput(
    LedgerReconciliationSuccessfulRunRow first,
    LedgerReconciliationSuccessfulRunRow second,
  ) async {
    try {
      final session = await (db.select(db.chatSessions)
            ..where((row) => row.sessionId.equals(first.sessionId)))
          .getSingleOrNull();
      if (session == null || first.sessionId != second.sessionId) return null;
      final messages = jsonDecode(session.messagesJson);
      if (messages is! List) return null;
      final selectedManifests = <Object?>[];
      final seenAcceptances = <String, String>{};
      var entryCount = 0;
      var evidenceSize = 0;
      for (final run in [first, second]) {
        final refs = _decodeRefs(run.acceptedManifestRefsJson);
        final anchors = _decodeRunAnchors(run.anchorsJson);
        for (final ref in refs) {
          final signature = _canonicalJson(ref.toJson());
          final previous = seenAcceptances[ref.acceptanceId];
          if (previous != null) {
            if (previous != signature) return null;
            continue;
          }
          seenAcceptances[ref.acceptanceId] = signature;
          if (!_refMatchesRunAnchor(ref, anchors) ||
              !_isImmediatelyAccepted(messages, ref)) {
            return null;
          }
        if (selectedManifests.length >= _maxManifests) {
          break;
        }
        final manifest = await (db.select(db.lorebookUseManifests)
              ..where((row) => row.sessionId.equals(ref.sessionId))
              ..where((row) => row.messageId.equals(ref.messageId))
              ..where((row) => row.swipeId.equals(ref.swipeId))
              ..where((row) => row.agentSwipeId.equals(ref.agentSwipeId)))
            .getSingleOrNull();
        final acceptance = await (db.select(db.lorebookUseAcceptanceRecords)
              ..where((row) => row.acceptanceId.equals(ref.acceptanceId)))
            .getSingleOrNull();
        if (manifest == null ||
            acceptance == null ||
            acceptance.acceptanceKind != 'variation' ||
            acceptance.sessionId != ref.sessionId ||
            acceptance.messageId != ref.messageId ||
            acceptance.swipeId != ref.swipeId ||
            acceptance.agentSwipeId != ref.agentSwipeId ||
            acceptance.acceptedByUserMessageId != ref.acceptedByUserMessageId ||
            manifest.manifestHash != ref.manifestHash) {
          return null;
        }
        final decoded = ExactLorebookManifest.decodeDurable({
          ...Map<String, dynamic>.from(jsonDecode(manifest.manifestJson) as Map),
          'canonicalHash': manifest.manifestHash,
        });
        if (decoded.promptProvenance.sessionId != ref.sessionId) {
          return null;
        }
        if (decoded.canonicalJson != manifest.manifestJson ||
            decoded.canonicalHash != manifest.manifestHash ||
            decoded.providerMessagesHash != manifest.finalPromptHash ||
            decoded.promptProvenance.presetSnapshotHash !=
                manifest.presetSnapshotHash ||
            manifest.manifestSchemaVersion != 1) {
          return null;
        }
        final entries = <Object?>[];
        for (final entry in decoded.entries) {
          final evidence = _canonicalJson({
            'lorebookId': entry.lorebookId,
            'entryId': entry.entryId,
            'injectionIndex': entry.injectionIndex,
            'source': entry.source,
            'classification': entry.classification,
            'renderedContent': entry.renderedContent,
            'renderedContentHash': entry.renderedContentHash,
          });
          if (entryCount >= _maxEntries ||
              evidenceSize + evidence.length > _maxEvidenceCodeUnits) {
            break;
          }
          entries.add(jsonDecode(evidence));
          entryCount++;
          evidenceSize += evidence.length;
        }
        if (entries.isNotEmpty) {
          selectedManifests.add({
            'runId': run.id,
            'acceptanceId': ref.acceptanceId,
            'manifestHash': ref.manifestHash,
            'messageId': ref.messageId,
            'swipeId': ref.swipeId,
            'agentSwipeId': ref.agentSwipeId,
            'entries': entries,
          });
        }
      }
      }
      if (selectedManifests.isEmpty || entryCount == 0) return null;
      return _canonicalJson({
        'contractVersion': 1,
        'field': CardRewriteField.description.wireName,
        'firstRunId': first.id,
        'secondRunId': second.id,
        'effectiveCanonStamp': second.effectiveCanonStamp,
        'effectiveCanonRevision': second.effectiveCanonRevision,
        'effectiveCanonHash': second.effectiveCanonHash,
        'limits': {
          'maxManifests': _maxManifests,
          'maxEntries': _maxEntries,
          'maxEvidenceCodeUnits': _maxEvidenceCodeUnits,
        },
        'manifests': selectedManifests,
      });
    } catch (_) {
      return null;
    }
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
}

List<AcceptedManifestRef> _decodeRefs(String source) {
  final values = jsonDecode(source) as List;
  final ids = <String>{};
  return values.map((value) {
    final json = Map<String, dynamic>.from(value as Map);
    final result = AcceptedManifestRef(
      acceptanceId: json['acceptanceId'] as String,
      sessionId: json['sessionId'] as String,
      messageId: json['messageId'] as String,
      swipeId: json['swipeId'] as int,
      agentSwipeId: json['agentSwipeId'] as int,
      manifestHash: json['manifestHash'] as String,
      acceptedByUserMessageId: json['acceptedByUserMessageId'] as String,
    );
    if (!ids.add(result.acceptanceId)) {
      throw const FormatException('duplicate acceptance ref in run');
    }
    return result;
  }).toList(growable: false);
}

List<ReconciliationAnchor> _decodeRunAnchors(String source) {
  final values = jsonDecode(source) as List;
  return values.map((value) {
    final json = Map<String, dynamic>.from(value as Map);
    return ReconciliationAnchor(
      messageId: json['messageId'] as String,
      swipeId: json['swipeId'] as int,
      agentSwipeId: json['agentSwipeId'] as int,
      role: json['role'] as String,
      contentHash: json['contentHash'] as String,
    );
  }).toList(growable: false);
}

bool _refMatchesRunAnchor(
  AcceptedManifestRef ref,
  List<ReconciliationAnchor> anchors,
) => anchors.any(
  (anchor) =>
      anchor.role == 'assistant' &&
      anchor.messageId == ref.messageId &&
      anchor.swipeId == ref.swipeId &&
      anchor.agentSwipeId == ref.agentSwipeId,
);

bool _isImmediatelyAccepted(List<dynamic> messages, AcceptedManifestRef ref) {
  final index = messages.indexWhere(
    (message) => message is Map && message['id'] == ref.messageId,
  );
  if (index < 0 || index + 1 >= messages.length) return false;
  final assistant = messages[index];
  final accepting = messages[index + 1];
  if (assistant is! Map ||
      assistant['role'] != 'assistant' ||
      accepting is! Map ||
      accepting['role'] != 'user' ||
      accepting['id'] != ref.acceptedByUserMessageId) {
    return false;
  }
  return _anchoredContent(
        assistant,
        ref.swipeId,
        ref.agentSwipeId,
      ) !=
      null;
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

String? _fieldValue(Character character, CardRewriteField field) => switch (field) {
  CardRewriteField.description => character.description,
  CardRewriteField.personality => character.personality,
  CardRewriteField.scenario => character.scenario,
  CardRewriteField.systemPrompt => character.systemPrompt,
  CardRewriteField.postHistoryInstructions =>
    character.postHistoryInstructions,
  CardRewriteField.creatorNotes => character.creatorNotes,
};

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
