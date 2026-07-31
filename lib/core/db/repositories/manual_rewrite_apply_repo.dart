import 'dart:convert';

import 'package:drift/drift.dart';

import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../services/card_rewriter/effective_canon_assembler.dart';
import '../../services/card_rewriter/effective_canon_read_repository.dart';
import '../../llm/character_tokens.dart';
import '../../models/character.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

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
    this.failureHook,
    this.beforeScalarUpdateHook,
  });

  final AppDatabase _db;
  final EffectiveCanonReadRepository _canonReader;
  final void Function(ManualRewriteApplyFailurePoint point)? failureHook;
  final Future<void> Function()? beforeScalarUpdateHook;
  static const _assembler = EffectiveCanonAssembler();

  Future<ManualRewriteApplyOutcome> applyApproved({
    required String jobId,
    required String expectedCanonStamp,
    required int expectedJobVersion,
  }) => _db.transaction(() async {
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
    final field = parsed.first.field;
    if (parsed.any((item) => item.field != field)) {
      return const ManualRewriteApplyOutcome.blocked('multipleFields');
    }
    final patches = parsed
        .expand((item) => item.patches)
        .toList(growable: false);
    final validation = AnchoredScalarPatchValidator.validate(
      patches: patches,
      currentCardValues: _values(input.sourceCharacter),
      fullCardBaselineSize: CardCanonicalizer.serialize(
        input.sourceCharacter,
      ).length,
    );
    if (!validation.isValid) {
      return const ManualRewriteApplyOutcome.blocked('anchorOrBudget');
    }
    for (
      var operationIndex = 0;
      operationIndex < parsed.length;
      operationIndex++
    ) {
      final operation = parsed[operationIndex];
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

    var next = _fieldValue(input.sourceCharacter, field);
    for (final patch in patches) {
      next = next.replaceFirst(patch.anchor, patch.value);
    }
    final updated = _withField(input.sourceCharacter, field, next);
    final parent = input.lineage.last;
    final newRevision = parent.revision + 1;
    final newHash = CardCanonicalizer.sha256(updated);
    if (newHash == parent.revisionHash) {
      return const ManualRewriteApplyOutcome.blocked('noEffectiveChange');
    }
    await beforeScalarUpdateHook?.call();
    if (!await _updateScalar(
      job.characterId,
      field,
      _nullableFieldValue(input.sourceCharacter, field),
      input.sourceCharacter.updatedAt,
      next,
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
    for (
      var operationIndex = 0;
      operationIndex < parsed.length;
      operationIndex++
    ) {
      final operation = parsed[operationIndex];
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
    failureHook?.call(ManualRewriteApplyFailurePoint.afterProvenance);
    for (final operation in approved) {
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
                  appliedCharacterRevision: Value(newRevision),
                  appliedCharacterRevisionHash: Value(newHash),
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

  Future<ManualRewriteApplyOutcome> _alreadyApplied(
    RewriteJobRow job,
    List<RewriteOperationRow> operations,
  ) async {
    if (job.appliedCharacterRevision <= 0 ||
        job.appliedCharacterRevisionHash.isEmpty ||
        operations
            .where((o) => o.decision == 'approved')
            .any(
              (o) =>
                  o.status != 'applied' ||
                  o.appliedCharacterRevision != job.appliedCharacterRevision ||
                  o.appliedCharacterRevisionHash !=
                      job.appliedCharacterRevisionHash,
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

  Future<bool> _updateScalar(
    String id,
    CardRewriteField field,
    String? expectedValue,
    int expectedUpdatedAt,
    String value,
    Character updated,
  ) async {
    final row = _db.update(_db.characters)
      ..where((t) {
        final fieldColumn = switch (field) {
          CardRewriteField.description => t.description,
          CardRewriteField.personality => t.personality,
          CardRewriteField.scenario => t.scenario,
          CardRewriteField.systemPrompt => t.systemPrompt,
          CardRewriteField.postHistoryInstructions => t.postHistoryInstructions,
          CardRewriteField.creatorNotes => t.creatorNotes,
        };
        return t.charId.equals(id) &
            t.updatedAt.equals(expectedUpdatedAt) &
            (expectedValue == null
                ? fieldColumn.isNull()
                : fieldColumn.equals(expectedValue));
      });
    final result = await row.write(switch (field) {
      CardRewriteField.description => CharactersCompanion(
        description: Value(value),
        updatedAt: Value(currentTimestampSeconds()),
        tokenCount: Value(estimateCharacterTokens(updated)),
      ),
      CardRewriteField.personality => CharactersCompanion(
        personality: Value(value),
        updatedAt: Value(currentTimestampSeconds()),
        tokenCount: Value(estimateCharacterTokens(updated)),
      ),
      CardRewriteField.scenario => CharactersCompanion(
        scenario: Value(value),
        updatedAt: Value(currentTimestampSeconds()),
        tokenCount: Value(estimateCharacterTokens(updated)),
      ),
      CardRewriteField.systemPrompt => CharactersCompanion(
        systemPrompt: Value(value),
        updatedAt: Value(currentTimestampSeconds()),
        tokenCount: Value(estimateCharacterTokens(updated)),
      ),
      CardRewriteField.postHistoryInstructions => CharactersCompanion(
        postHistoryInstructions: Value(value),
        updatedAt: Value(currentTimestampSeconds()),
        tokenCount: Value(estimateCharacterTokens(updated)),
      ),
      CardRewriteField.creatorNotes => CharactersCompanion(
        creatorNotes: Value(value),
        updatedAt: Value(currentTimestampSeconds()),
        tokenCount: Value(estimateCharacterTokens(updated)),
      ),
    });
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

final class _StoredOperation {
  const _StoredOperation(this.id, this.field, this.patches, this.transition);
  final String id;
  final CardRewriteField field;
  final List<AnchoredScalarPatch> patches;
  final _Transition transition;
  static _StoredOperation? tryParse(String id, String source) {
    try {
      final json = jsonDecode(source) as Map<String, dynamic>;
      final field = CardRewriteField.values
          .where((v) => v.wireName == json['field'])
          .single;
      final patches = (json['patches'] as List)
          .map((v) {
            final p = v as Map<String, dynamic>;
            return AnchoredScalarPatch(
              scopeKey: p['scopeKey'] as String,
              field: field,
              anchor: p['anchor'] as String,
              anchorSha256: p['anchorSha256'] as String,
              value: p['value'] as String,
            );
          })
          .toList(growable: false);
      if (patches.isEmpty) return null;
      return _StoredOperation(
        id,
        field,
        patches,
        _Transition.parse(json['transition'] as Map<String, dynamic>),
      );
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
  factory _Transition.parse(Map<String, dynamic> v) => _Transition(
    v['id'] as String,
    v['scopeKey'] as String,
    v['canonicalClaim'] as String,
    v['promotionDestination'] as String? ?? '',
    List<String>.from(v['affectedTrackerKeys'] as List),
    List<String>.from(v['factIds'] as List? ?? const []),
    v['chatSessionId'] as String?,
  );
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
