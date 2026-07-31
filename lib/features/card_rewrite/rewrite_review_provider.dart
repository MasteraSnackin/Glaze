import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_db.dart';
import '../../core/db/repositories/manual_rewrite_apply_repo.dart';
import '../../core/db/repositories/manual_rewrite_job_repo.dart';
import '../../core/models/character.dart';
import '../../core/services/card_rewriter/card_rewriter_contracts.dart';
import '../../core/services/card_rewriter/effective_canon_assembler.dart';
import '../../core/services/card_rewriter/effective_canon_read_repository.dart';
import '../../core/state/card_rewriter_providers.dart';
import '../../core/state/db_provider.dart';

/// Durable review aggregate for one job: job row + operations joined with
/// their current immutable revision snapshots and evidence counts.
final rewriteJobSnapshotProvider =
    StreamProvider.family<ManualRewriteJobSnapshot?, String>((ref, jobId) {
      return ref.watch(manualRewriteJobRepoProvider).watchJob(jobId);
    });

/// The live source character, for advisory previews and canon re-checks.
final rewriteCharacterProvider = FutureProvider.family<Character?, String>((
  ref,
  charId,
) {
  return ref.watch(characterRepoProvider).getById(charId);
});

/// Raw names of the session's manual canon controls (`canon_lock:<key>` /
/// `canon_override:<key>`). Advisory only — guarded apply re-checks these
/// transactionally.
final rewriteManualControlsProvider = FutureProvider.family<Set<String>, String>((
  ref,
  sessionId,
) async {
  final raw = await ref
      .watch(ledgerRawTrackerStateReaderProvider)
      .read(sessionId);
  return raw.manualControls.map((t) => t.name).toSet();
});

/// Read-side canon reader composed from the context loader's own parts
/// (mirrors the db_provider wiring; this file may not edit that file).
final _canonReaderProvider = Provider<EffectiveCanonReadRepository>((ref) {
  final loader = ref.watch(effectiveCanonContextLoaderProvider);
  return EffectiveCanonReadRepository(
    db: loader.db,
    characterRepo: loader.characterRepo,
    revisionRepo: loader.characterRevisionRepo,
    baselineRepo: loader.baselineRepo,
    factRepo: loader.factRepo,
    transitionRepo: loader.transitionRepo,
    transitionFactRefRepo: loader.transitionFactRefRepo,
    rawTrackerStateReader: ref.watch(ledgerRawTrackerStateReaderProvider),
  );
});

enum RewriteCanonFreshness { unknown, checking, current, stale, unavailable }

class RewriteReviewUiState {
  const RewriteReviewUiState({
    this.selectedOperationId,
    this.busy = false,
    this.freshness = RewriteCanonFreshness.unknown,
  });

  final String? selectedOperationId;

  /// In-flight mutation/apply — the screen locks interactions while true.
  final bool busy;
  final RewriteCanonFreshness freshness;

  RewriteReviewUiState copyWith({
    String? Function()? selectedOperationId,
    bool? busy,
    RewriteCanonFreshness? freshness,
  }) => RewriteReviewUiState(
    selectedOperationId: selectedOperationId == null
        ? this.selectedOperationId
        : selectedOperationId(),
    busy: busy ?? this.busy,
    freshness: freshness ?? this.freshness,
  );
}

/// Transient review state and all side-effecting user actions for one job.
/// Durable facts come from [rewriteJobSnapshotProvider]; every mutation goes
/// through the job repo's typed-CAS methods and reports its conflict kind.
class RewriteReviewController extends Notifier<RewriteReviewUiState> {
  RewriteReviewController(this.jobId);

  final String jobId;

  @override
  RewriteReviewUiState build() => const RewriteReviewUiState();

  void selectOperation(String? id) =>
      state = state.copyWith(selectedOperationId: () => id);

  void markStaleCanon() =>
      state = state.copyWith(freshness: RewriteCanonFreshness.stale);

  /// Advisory re-check: fresh read-side assembly identity vs. the stamp the
  /// job was generated against. Never reconciles or writes lineage rows.
  Future<RewriteCanonFreshness> recheckCanon(RewriteJobRow job) async {
    state = state.copyWith(freshness: RewriteCanonFreshness.checking);
    final character = await ref
        .read(characterRepoProvider)
        .getById(job.characterId);
    if (character == null) {
      state = state.copyWith(freshness: RewriteCanonFreshness.unavailable);
      return state.freshness;
    }
    final fresh = await computeFreshCanonIdentity(
      sessionId: job.chatSessionId,
      character: character,
    );
    final next = fresh == null
        ? RewriteCanonFreshness.unavailable
        : job.canonStamp.isNotEmpty && fresh == job.canonStamp
        ? RewriteCanonFreshness.current
        : RewriteCanonFreshness.stale;
    state = state.copyWith(freshness: next);
    return next;
  }

  /// Fresh read-side canon stamp. Null when the assembly is unreadable.
  Future<String?> computeFreshCanonIdentity({
    required String sessionId,
    required Character character,
  }) async {
    try {
      final input = await ref
          .read(_canonReaderProvider)
          .readFromSource(sessionId: sessionId, sourceCharacter: character);
      return const EffectiveCanonAssembler().assemble(input).identity;
    } catch (_) {
      return null;
    }
  }

  /// Returns the typed conflict kind (`updated`, `staleRevision`, …).
  Future<String> decide(ManualRewriteOperationView view, String decision) async {
    final op = view.operation;
    final outcome = await ref
        .read(manualRewriteJobRepoProvider)
        .setDecision(
          operationId: op.id,
          expectedCurrentRevision: op.currentRevision,
          expectedDecision: op.decision,
          decision: decision,
        );
    return outcome.kind;
  }

  /// Approves every still-`pending`, reviewable, durably-valid operation that
  /// is not advisory-lock-blocked. Returns the number actually approved.
  Future<int> approveAllValid({
    required List<ManualRewriteOperationView> ops,
    required Set<String> manualControlNames,
  }) async {
    var approved = 0;
    for (final view in ops) {
      final op = view.operation;
      if (op.status != 'reviewable' ||
          op.decision != 'pending' ||
          op.validationStatus != 'valid') {
        continue;
      }
      final snapshot = decodeOperationSnapshot(view.currentSnapshotJson);
      if (snapshot == null) continue;
      if (lockOverlap(snapshot, manualControlNames).isNotEmpty) continue;
      final kind = await decide(view, 'approved');
      // After the first decision the job version moved on; re-read each op
      // through the stream on the next frame. Kinds other than `updated`
      // (e.g. a concurrent mutation) simply don't count.
      if (kind == 'updated') approved++;
    }
    return approved;
  }

  /// Reviewer edit: immutable revision +1 through the repo (decision and
  /// validation reset, advisory-revalidated against the live card).
  Future<String> saveEdit(
    ManualRewriteOperationView view,
    List<String> newValues,
  ) async {
    final snapshot = decodeOperationSnapshot(view.currentSnapshotJson);
    if (snapshot == null || snapshot.patches.length != newValues.length) {
      return 'invalidSnapshot';
    }
    final updated = CardRewriteOperationSnapshot(
      field: snapshot.field,
      patches: [
        for (var i = 0; i < snapshot.patches.length; i++)
          AnchoredScalarPatch(
            scopeKey: snapshot.patches[i].scopeKey,
            field: snapshot.field,
            anchor: snapshot.patches[i].anchor,
            anchorSha256: snapshot.patches[i].anchorSha256,
            value: newValues[i],
          ),
      ],
      transition: snapshot.transition,
    );
    final outcome = await ref
        .read(manualRewriteJobRepoProvider)
        .editAndRevalidate(
          operationId: view.operation.id,
          expectedCurrentRevision: view.operation.currentRevision,
          newSnapshotJson: ManualRewriteOperationSnapshotCodec.encode(updated),
        );
    return outcome.kind;
  }

  /// Atomic apply of all approved operations. The expected canon stamp is re-
  /// derived from a FRESH read-side assembly right before the call (Oracle
  /// contract), never reused from the stored job stamp.
  Future<ManualRewriteApplyOutcome> apply(ManualRewriteJobSnapshot snap) async {
    if (state.busy) {
      return const ManualRewriteApplyOutcome.blocked('uiBusy');
    }
    final character = await ref
        .read(characterRepoProvider)
        .getById(snap.job.characterId);
    if (character == null) {
      return const ManualRewriteApplyOutcome.blocked('characterNotFound');
    }
    state = state.copyWith(busy: true);
    try {
      final stamp = await computeFreshCanonIdentity(
        sessionId: snap.job.chatSessionId,
        character: character,
      );
      if (stamp == null) {
        return const ManualRewriteApplyOutcome.blocked('invalidCanonContext');
      }
      return await ref
          .read(manualRewriteApplyRepoProvider)
          .applyApproved(
            jobId: snap.job.id,
            expectedCanonStamp: stamp,
            expectedJobVersion: snap.job.version,
          );
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> cancelJob(String jobId) async {
    await ref.read(manualRewriteServiceProvider).cancelJob(jobId);
  }

  /// `failed → generating` retry, then re-attaches the writer lane using the
  /// job's original durable request. Returns a typed kind; `retryUnavailable`
  /// when the job lacks the data needed to re-attach (legacy keyless job or
  /// an unreadable request payload).
  Future<String> retry(RewriteJobRow job) async {
    final request = parseRewriteJobRequest(job.requestJson);
    final requestKey = job.requestKey;
    if (request == null || requestKey == null || requestKey.isEmpty) {
      return 'retryUnavailable';
    }
    final outcome = await ref
        .read(manualRewriteJobRepoProvider)
        .retry(jobId: job.id, expectedVersion: job.version);
    if (!outcome.isUpdated) return outcome.kind;
    unawaited(
      ref
          .read(manualRewriteServiceProvider)
          .run(
            requestKey: requestKey,
            chatSessionId: job.chatSessionId,
            characterId: job.characterId,
            field: request.field,
            instruction: request.instruction,
          ),
    );
    return 'updated';
  }
}

final rewriteReviewUiProvider =
    NotifierProvider.family<
      RewriteReviewController,
      RewriteReviewUiState,
      String
    >(RewriteReviewController.new);

/// Typed view of a job's durable request payload (`{field, instruction}`).
typedef RewriteJobRequest = ({CardRewriteField field, String instruction});

RewriteJobRequest? parseRewriteJobRequest(String requestJson) {
  try {
    final json = jsonDecode(requestJson);
    if (json is! Map) return null;
    final wireName = json['field'];
    final instruction = json['instruction'];
    if (wireName is! String) return null;
    CardRewriteField? field;
    for (final candidate in CardRewriteField.values) {
      if (candidate.wireName == wireName) field = candidate;
    }
    if (field == null) return null;
    return (field: field, instruction: instruction is String ? instruction : '');
  } catch (_) {
    return null;
  }
}

CardRewriteOperationSnapshot? decodeOperationSnapshot(String snapshotJson) {
  try {
    return ManualRewriteOperationSnapshotCodec.tryDecode(
      jsonDecode(snapshotJson),
    );
  } catch (_) {
    return null;
  }
}

/// Advisory set of a transition's tracker keys that currently sit under a
/// manual canon lock or override.
Set<String> lockOverlap(
  CardRewriteOperationSnapshot snapshot,
  Set<String> manualControlNames,
) => {
  for (final key in snapshot.transition.affectedTrackerKeys)
    if (manualControlNames.contains('canon_lock:$key') ||
        manualControlNames.contains('canon_override:$key'))
      key,
};

/// Advisory per-operation validation against the live card values. Guarded
/// apply re-validates authoritatively; this only drives chips and gating.
List<CardPatchViolation> advisoryViolations(
  CardRewriteOperationSnapshot snapshot,
  Character character,
) {
  final validation = AnchoredScalarPatchValidator.validate(
    patches: snapshot.patches,
    currentCardValues: rewriteFieldValues(character),
    fullCardBaselineSize: CardCanonicalizer.serialize(character).length,
  );
  return validation.violations;
}

Map<CardRewriteField, String?> rewriteFieldValues(Character c) => {
  for (final field in CardRewriteField.values) field: rewrittenFieldValue(c, field),
};

String rewrittenFieldValue(Character c, CardRewriteField field) =>
    switch (field) {
      CardRewriteField.description => c.description ?? '',
      CardRewriteField.personality => c.personality ?? '',
      CardRewriteField.scenario => c.scenario ?? '',
      CardRewriteField.systemPrompt => c.systemPrompt ?? '',
      CardRewriteField.postHistoryInstructions =>
        c.postHistoryInstructions ?? '',
      CardRewriteField.creatorNotes => c.creatorNotes ?? '',
    };
