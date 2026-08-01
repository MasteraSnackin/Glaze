import 'dart:convert';

import 'package:drift/drift.dart';

import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../services/card_rewriter/effective_canon_assembler.dart';
import '../../services/card_rewriter/effective_canon_read_repository.dart';
import '../../llm/character_tokens.dart';
import '../../models/character.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';
import 'session_lorebook_evolution_repo.dart';

/// The only durable request shape accepted by manual apply.  It is stored in
/// the immutable operation-revision snapshot; callers never provide it.
///
/// `{field, patches, transition}` where each patch has `scopeKey`, `anchor`,
/// `anchorSha256`, and `value`; transition has `id`, `scopeKey`,
/// `canonicalClaim`, `promotionDestination`, `affectedTrackerKeys`, and
/// optional `factIds` and `chatSessionId` (null means global).
final class ManualRewriteApplyOutcome {
  const ManualRewriteApplyOutcome._(this.kind, [this.reason]);
  const ManualRewriteApplyOutcome.applied() : this._('applied');
  const ManualRewriteApplyOutcome.alreadyApplied() : this._('alreadyApplied');
  const ManualRewriteApplyOutcome.blocked(String reason)
    : this._('blocked', reason);
  final String kind;
  final String? reason;
  bool get isApplied => kind == 'applied';
}

/// Test-only fault injection points used to prove transaction rollback.
enum ManualRewriteApplyFailurePoint {
  afterCharacterUpdate,
  afterProvenance,
  afterSecondTransitionOrRefWrite,
}

/// Aggregate transaction for the Phase-3 manual scalar rewrite slice.
class ManualRewriteApplyRepo {
  ManualRewriteApplyRepo({
    required this._db,
    required this._canonReader,
    SessionLorebookEvolutionRepo? lorebookEvolutionRepo,
    this.failureHook,
    this.beforeScalarUpdateHook,
  }) : _lorebookEvolutionRepo = lorebookEvolutionRepo ??
           SessionLorebookEvolutionRepo(_db);

  final AppDatabase _db;
  final EffectiveCanonReadRepository _canonReader;
  final SessionLorebookEvolutionRepo _lorebookEvolutionRepo;
  final void Function(ManualRewriteApplyFailurePoint point)? failureHook;
  final Future<void> Function()? beforeScalarUpdateHook;
  static const _assembler = EffectiveCanonAssembler();

  Future<ManualRewriteApplyOutcome> applyApproved({
    required String jobId,
    required String expectedCanonStamp,
    required int expectedJobVersion,
  }) async {
    try {
      return await _db.transaction(() async {
    final job = await (_db.select(
      _db.rewriteJobs,
    )..where((t) => t.id.equals(jobId))).getSingleOrNull();
    if (job == null) {
      return const ManualRewriteApplyOutcome.blocked('jobNotFound');
    }
    final operations =
        await (_db.select(_db.rewriteOperations)
              ..where((t) => t.rewriteJobId.equals(jobId))
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get();
    if (job.status == 'applied') return _alreadyApplied(job, operations);
    // `pending` is the sole durable applyable state: it is the schema default
    // and the state used by seeded jobs. All other values fail closed.
    if (job.status != 'pending') {
      return const ManualRewriteApplyOutcome.blocked('jobNotApplyable');
    }
    if (job.version != expectedJobVersion) {
      return const ManualRewriteApplyOutcome.blocked('staleJob');
    }

    final input = await _canonReader.readInTransaction(
      sessionId: job.chatSessionId,
      characterId: job.characterId,
    );
    if (!_hasCurrentSourceLineage(input)) {
      return const ManualRewriteApplyOutcome.blocked('sourceLineageStale');
    }
    EffectiveCanonAssembly assembly;
    try {
      assembly = _assembler.assemble(input);
    } on EffectiveCanonAssemblyUnavailable {
      return const ManualRewriteApplyOutcome.blocked('invalidCanonContext');
    }
    if (assembly.identity != expectedCanonStamp) {
      return const ManualRewriteApplyOutcome.blocked('staleCanonStamp');
    }
    if (assembly.identity != job.canonStamp) {
      return const ManualRewriteApplyOutcome.blocked('staleJobCanonStamp');
    }
    if (assembly.requiresBaselineDecision ||
        assembly.effectiveRevision.number != job.basisRevision ||
        assembly.effectiveRevision.hash != job.basisRevisionHash ||
        input.lineage.last.revisionHash != job.basisRevisionHash) {
      return const ManualRewriteApplyOutcome.blocked('staleSourceOrBaseline');
    }

    final approved = operations
        .where((item) => item.decision == 'approved')
        .toList(growable: false);
    if (approved.isEmpty) {
      return const ManualRewriteApplyOutcome.blocked('noApprovedOperations');
    }
    final parsed = <_StoredOperation>[];
    for (final operation in approved) {
      if (operation.status != 'reviewable' ||
          operation.validationStatus != 'valid' ||
          operation.decisionRevision != operation.currentRevision ||
          operation.appliedCharacterRevision != 0 ||
          operation.chatSessionId != job.chatSessionId) {
        return const ManualRewriteApplyOutcome.blocked('staleOperation');
      }
      final revision =
          await (_db.select(_db.rewriteOperationRevisions)..where(
                (t) =>
                    t.rewriteOperationId.equals(operation.id) &
                    t.revision.equals(operation.currentRevision),
              ))
              .getSingleOrNull();
      if (revision == null ||
          revision.snapshotJson != operation.operationJson) {
        return const ManualRewriteApplyOutcome.blocked(
          'operationRevisionMismatch',
        );
      }
      final value = _StoredOperation.tryParse(
        operation.id,
        revision.snapshotJson,
      );
      if (value == null) {
        return const ManualRewriteApplyOutcome.blocked(
          'invalidOperationSnapshot',
        );
      }
      parsed.add(value);
    }
    final cardOperations = parsed
        .where((item) => item.snapshot is CardRewriteOperationSnapshot)
        .toList(growable: false);
    final lorebookOperations = parsed
        .where((item) => item.snapshot is LorebookRewriteOperationSnapshot)
        .toList(growable: false);
    final patches = cardOperations
        .expand((item) => item.patches)
        .toList(growable: false);
    if (patches.isNotEmpty) {
      final validation = AnchoredScalarPatchValidator.validate(
        patches: patches,
        currentCardValues: _values(input.sourceCharacter),
      );
      if (!validation.isValid) {
        return const ManualRewriteApplyOutcome.blocked('anchor');
      }
    }
    for (
      var operationIndex = 0;
      operationIndex < cardOperations.length;
      operationIndex++
    ) {
      final operation = cardOperations[operationIndex];
      if (!_isValidGlobalTransition(operation.transition) ||
          operation.patches.any(
            (patch) =>
                patch.scopeKey != operation.transition.scopeKey ||
                CardRewriteScope.tryParse(patch.scopeKey) == null,
          ) ||
          operation.transition.affectedTrackerKeys.any(
            (key) => input.manualControls.any(
              (control) =>
                  control.name == 'canon_override:$key' ||
                  control.name == 'canon_lock:$key',
            ),
          ) ||
          !operation.transition.factIds.every((id) {
            final matches = input.facts.where((fact) => fact.id == id);
            // Facts exposed by the reader are already reviewable facts from
            // this job's session. Scope equality is intentionally exact: no
            // broader inference is safe for unsupported scope families.
            return matches.length == 1 &&
                matches.single.scopeKey == operation.transition.scopeKey;
          })) {
        return const ManualRewriteApplyOutcome.blocked(
          'manualControlOrTransition',
        );
      }
    }

    final patchesByField = <CardRewriteField, List<AnchoredScalarPatch>>{};
    for (final patch in patches) {
      (patchesByField[patch.field] ??= []).add(patch);
    }
    var updated = input.sourceCharacter;
    final values = <CardRewriteField, String>{};
    for (final entry in patchesByField.entries) {
      var next = _fieldValue(updated, entry.key);
      for (final patch in entry.value) {
        next = next.replaceFirst(patch.anchor, patch.value);
      }
      values[entry.key] = next;
      updated = _withField(updated, entry.key, next);
    }
    final parent = input.lineage.last;
    var newRevision = 0;
    var newHash = '';
    if (cardOperations.isNotEmpty) {
      newRevision = parent.revision + 1;
      newHash = CardCanonicalizer.sha256(updated);
      if (newHash == parent.revisionHash) {
        return const ManualRewriteApplyOutcome.blocked('noEffectiveChange');
      }
      await beforeScalarUpdateHook?.call();
      if (!await _updateFields(
        job.characterId,
        input.sourceCharacter,
        input.sourceCharacter.updatedAt,
        values,
        updated,
      )) {
        return const ManualRewriteApplyOutcome.blocked('staleCharacterField');
      }
      failureHook?.call(ManualRewriteApplyFailurePoint.afterCharacterUpdate);
      await _db
          .into(_db.characterRevisionRows)
          .insert(
            CharacterRevisionRowsCompanion.insert(
              characterId: job.characterId,
              revision: newRevision,
              revisionHash: newHash,
              parentRevisionHash: Value(parent.revisionHash),
              snapshotJson: jsonEncode(updated.toJson()),
              createdAt: Value(currentTimestampSeconds()),
            ),
          );
    }
    for (
      var operationIndex = 0;
      operationIndex < cardOperations.length;
      operationIndex++
    ) {
      final operation = cardOperations[operationIndex];
      await _db
          .into(_db.appliedCanonTransitionRows)
          .insert(
            AppliedCanonTransitionRowsCompanion.insert(
              id: operation.transition.id,
              characterId: job.characterId,
              chatSessionId: Value(operation.transition.chatSessionId),
              rewriteOperationId: Value(operation.id),
              revision: Value(newRevision),
              revisionHash: Value(newHash),
              semanticScopeKey: Value(operation.transition.scopeKey),
              canonicalClaim: Value(operation.transition.canonicalClaim),
              promotionDestination: Value(
                operation.transition.promotionDestination,
              ),
              affectedTrackerKeysJson: Value(
                jsonEncode(operation.transition.affectedTrackerKeys),
              ),
              transitionJson: jsonEncode(operation.transition.toJson()),
              appliedAt: Value(currentTimestampSeconds()),
            ),
          );
      for (final factId in operation.transition.factIds) {
        await _db
            .into(_db.canonTransitionFactRefs)
            .insert(
              CanonTransitionFactRefsCompanion.insert(
                appliedCanonTransitionId: operation.transition.id,
                characterKnowledgeFactId: factId,
              ),
            );
      }
      if (operationIndex == 1) {
        failureHook?.call(
          ManualRewriteApplyFailurePoint.afterSecondTransitionOrRefWrite,
        );
      }
    }
    for (final operation in lorebookOperations) {
      final lore = operation.snapshot as LorebookRewriteOperationSnapshot;
      if (!await _lorebookEvolutionRepo.applyPatchesInTransaction(
        sessionId: job.chatSessionId,
        lorebookId: lore.lorebookId,
        entryId: lore.entryId,
        baseContent: lore.baseContent,
        expectedContentHash: lore.expectedContentHash,
        patches: lore.patches,
      )) {
        throw const _ApplyBlocked('staleLorebookEntry');
      }
    }
    failureHook?.call(ManualRewriteApplyFailurePoint.afterProvenance);
    for (var index = 0; index < approved.length; index++) {
      final operation = approved[index];
      final snapshot = parsed[index].snapshot;
      final changed =
          await (_db.update(_db.rewriteOperations)..where(
                (t) =>
                    t.id.equals(operation.id) &
                    t.currentRevision.equals(operation.currentRevision) &
                    t.status.equals('reviewable') &
                    t.decision.equals('approved') &
                    t.validationStatus.equals('valid') &
                    t.decisionRevision.equals(operation.currentRevision) &
                    t.appliedCharacterRevision.equals(0),
              ))
              .write(
                RewriteOperationsCompanion(
                  status: const Value('applied'),
                  appliedCharacterRevision: Value(
                    snapshot is CardRewriteOperationSnapshot
                        ? newRevision
                        : 0,
                  ),
                  appliedCharacterRevisionHash: Value(
                    snapshot is CardRewriteOperationSnapshot
                        ? newHash
                        : '',
                  ),
                  updatedAt: Value(currentTimestampSeconds()),
                ),
              );
      if (changed != 1) {
        throw StateError('Operation CAS changed inside apply transaction.');
      }
    }
    final jobChanged =
        await (_db.update(_db.rewriteJobs)..where(
              (t) =>
                  t.id.equals(jobId) &
                  t.version.equals(expectedJobVersion) &
                  t.status.equals(job.status),
            ))
            .write(
              RewriteJobsCompanion(
                status: const Value('applied'),
                version: Value(expectedJobVersion + 1),
                appliedCharacterRevision: Value(newRevision),
                appliedCharacterRevisionHash: Value(newHash),
                updatedAt: Value(currentTimestampSeconds()),
              ),
            );
    if (jobChanged != 1) {
      throw StateError('Job CAS changed inside apply transaction.');
    }
        return const ManualRewriteApplyOutcome.applied();
      });
    } on _ApplyBlocked catch (blocked) {
      return ManualRewriteApplyOutcome.blocked(blocked.reason);
    }
  }

  Future<ManualRewriteApplyOutcome> _alreadyApplied(
    RewriteJobRow job,
    List<RewriteOperationRow> operations,
  ) async {
    final approved = operations.where((o) => o.decision == 'approved');
    if (approved.any((o) => o.status != 'applied')) {
      return const ManualRewriteApplyOutcome.blocked('inconsistentAppliedJob');
    }
    if (job.appliedCharacterRevision == 0 &&
        job.appliedCharacterRevisionHash.isEmpty) {
      return const ManualRewriteApplyOutcome.alreadyApplied();
    }
    if (job.appliedCharacterRevision <= 0 ||
        job.appliedCharacterRevisionHash.isEmpty ||
        approved.any(
          (o) =>
              o.appliedCharacterRevision != 0 &&
              (o.appliedCharacterRevision != job.appliedCharacterRevision ||
                  o.appliedCharacterRevisionHash !=
                      job.appliedCharacterRevisionHash),
        )) {
      return const ManualRewriteApplyOutcome.blocked('inconsistentAppliedJob');
    }
    final revision =
        await (_db.select(_db.characterRevisionRows)..where(
              (t) =>
                  t.characterId.equals(job.characterId) &
                  t.revision.equals(job.appliedCharacterRevision) &
                  t.revisionHash.equals(job.appliedCharacterRevisionHash),
            ))
            .getSingleOrNull();
    return revision == null
        ? const ManualRewriteApplyOutcome.blocked('inconsistentAppliedJob')
        : const ManualRewriteApplyOutcome.alreadyApplied();
  }

  Future<bool> _updateFields(
    String id,
    Character expected,
    int expectedUpdatedAt,
    Map<CardRewriteField, String> values,
    Character updated,
  ) async {
    final row = _db.update(_db.characters)
      ..where((t) {
        var predicate =
            t.charId.equals(id) & t.updatedAt.equals(expectedUpdatedAt);
        for (final field in values.keys) {
          final expectedValue = _nullableFieldValue(expected, field);
          final fieldColumn = switch (field) {
            CardRewriteField.description => t.description,
            CardRewriteField.personality => t.personality,
            CardRewriteField.scenario => t.scenario,
            CardRewriteField.systemPrompt => t.systemPrompt,
            CardRewriteField.postHistoryInstructions =>
              t.postHistoryInstructions,
            CardRewriteField.creatorNotes => t.creatorNotes,
          };
          predicate =
              predicate &
              (expectedValue == null
                  ? fieldColumn.isNull()
                  : fieldColumn.equals(expectedValue));
        }
        return predicate;
      });
    final result = await row.write(
      CharactersCompanion(
        description: values.containsKey(CardRewriteField.description)
            ? Value(values[CardRewriteField.description]!)
            : const Value.absent(),
        personality: values.containsKey(CardRewriteField.personality)
            ? Value(values[CardRewriteField.personality]!)
            : const Value.absent(),
        scenario: values.containsKey(CardRewriteField.scenario)
            ? Value(values[CardRewriteField.scenario]!)
            : const Value.absent(),
        systemPrompt: values.containsKey(CardRewriteField.systemPrompt)
            ? Value(values[CardRewriteField.systemPrompt]!)
            : const Value.absent(),
        postHistoryInstructions:
            values.containsKey(CardRewriteField.postHistoryInstructions)
            ? Value(values[CardRewriteField.postHistoryInstructions]!)
            : const Value.absent(),
        creatorNotes: values.containsKey(CardRewriteField.creatorNotes)
            ? Value(values[CardRewriteField.creatorNotes]!)
            : const Value.absent(),
        updatedAt: Value(currentTimestampSeconds()),
        tokenCount: Value(estimateCharacterTokens(updated)),
      ),
    );
    return result == 1;
  }

  static Map<CardRewriteField, String?> _values(Character c) => {
    for (final f in CardRewriteField.values) f: _fieldValue(c, f),
  };
  static String _fieldValue(Character c, CardRewriteField f) => switch (f) {
    CardRewriteField.description => c.description ?? '',
    CardRewriteField.personality => c.personality ?? '',
    CardRewriteField.scenario => c.scenario ?? '',
    CardRewriteField.systemPrompt => c.systemPrompt ?? '',
    CardRewriteField.postHistoryInstructions => c.postHistoryInstructions ?? '',
    CardRewriteField.creatorNotes => c.creatorNotes ?? '',
  };
  static String? _nullableFieldValue(Character c, CardRewriteField f) =>
      switch (f) {
        CardRewriteField.description => c.description,
        CardRewriteField.personality => c.personality,
        CardRewriteField.scenario => c.scenario,
        CardRewriteField.systemPrompt => c.systemPrompt,
        CardRewriteField.postHistoryInstructions => c.postHistoryInstructions,
        CardRewriteField.creatorNotes => c.creatorNotes,
      };
  static Character _withField(Character c, CardRewriteField f, String value) =>
      switch (f) {
        CardRewriteField.description => c.copyWith(description: value),
        CardRewriteField.personality => c.copyWith(personality: value),
        CardRewriteField.scenario => c.copyWith(scenario: value),
        CardRewriteField.systemPrompt => c.copyWith(systemPrompt: value),
        CardRewriteField.postHistoryInstructions => c.copyWith(
          postHistoryInstructions: value,
        ),
        CardRewriteField.creatorNotes => c.copyWith(creatorNotes: value),
      };
  static bool _isValidGlobalTransition(_Transition transition) =>
      transition.chatSessionId == null &&
      transition.id.isNotEmpty &&
      transition.canonicalClaim.isNotEmpty &&
      transition.promotionDestination.isNotEmpty &&
      CardRewriteScope.tryParse(transition.scopeKey) != null &&
      transition.affectedTrackerKeys.every((key) => key.isNotEmpty);

  /// A source card is authoritative only when its complete canonical payload
  /// is represented by one contiguous, hash-linked revision chain. Apply never
  /// repairs or reconciles a broken chain.
  static bool _hasCurrentSourceLineage(EffectiveCanonAssemblyInput input) {
    final lineage = input.lineage;
    if (lineage.isEmpty ||
        CardCanonicalizer.sha256(input.sourceCharacter) !=
            lineage.last.revisionHash) {
      return false;
    }
    for (var index = 0; index < lineage.length; index++) {
      final row = lineage[index];
      if (row.characterId != input.sourceCharacter.id ||
          row.revision <= 0 ||
          row.revisionHash.isEmpty) {
        return false;
      }
      if (index == 0) {
        if (row.parentRevisionHash.isNotEmpty) return false;
      } else {
        final parent = lineage[index - 1];
        if (row.revision != parent.revision + 1 ||
            row.parentRevisionHash != parent.revisionHash) {
          return false;
        }
      }
    }
    return true;
  }
}

final class _ApplyBlocked implements Exception {
  const _ApplyBlocked(this.reason);
  final String reason;
}

final class _StoredOperation {
  const _StoredOperation(this.id, this.snapshot);
  final String id;
  final RewriteOperationSnapshot snapshot;
  List<AnchoredScalarPatch> get patches =>
      (snapshot as CardRewriteOperationSnapshot).patches;
  _Transition get transition {
    final value = (snapshot as CardRewriteOperationSnapshot).transition;
    return _Transition(
      value.id,
      value.scopeKey,
      value.canonicalClaim,
      value.promotionDestination,
      value.affectedTrackerKeys,
      value.factIds,
      value.chatSessionId,
    );
  }
  static _StoredOperation? tryParse(String id, String source) {
    try {
      final snapshot = RewriteOperationSnapshotCodec.tryDecode(jsonDecode(source));
      return snapshot == null ? null : _StoredOperation(id, snapshot);
    } catch (_) {
      return null;
    }
  }
}

final class _Transition {
  const _Transition(
    this.id,
    this.scopeKey,
    this.canonicalClaim,
    this.promotionDestination,
    this.affectedTrackerKeys,
    this.factIds,
    this.chatSessionId,
  );
  final String id, scopeKey, canonicalClaim, promotionDestination;
  final List<String> affectedTrackerKeys, factIds;
  final String? chatSessionId;
  Map<String, Object?> toJson() => {
    'id': id,
    'scopeKey': scopeKey,
    'canonicalClaim': canonicalClaim,
    'promotionDestination': promotionDestination,
    'affectedTrackerKeys': affectedTrackerKeys,
    'factIds': factIds,
    'chatSessionId': chatSessionId,
  };
}
