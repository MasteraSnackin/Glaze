import 'package:drift/drift.dart';

import '../../utils/id_generator.dart';
import '../app_db.dart';
import 'ledger_reconciliation_run_repo.dart';

final class CardEvolutionCollectorClaimOutcome {
  const CardEvolutionCollectorClaimOutcome(this.kind, [this.row]);

  final String kind;
  final CardEvolutionCollectorRunRow? row;

  bool get canRun => kind == 'claimed' || kind == 'existing';
}

/// Durable collector lease and completion journal. A valid empty observation
/// response is a completed run, so cadence remains stable across restarts.
class CardEvolutionCollectorRunRepo {
  CardEvolutionCollectorRunRepo(this.db);

  final AppDatabase db;

  Future<CardEvolutionCollectorClaimOutcome> claim({
    required LedgerReconciliationSuccessfulRunRow reconciliationRun,
    required String characterId,
    required String inputHash,
    required String ownerId,
    required int now,
    required int leaseSeconds,
  }) => db.transaction(() async {
    final existing =
        await (db.select(db.cardEvolutionCollectorRuns)..where(
              (row) =>
                  row.sessionId.equals(reconciliationRun.sessionId) &
                  row.reconciliationRunId.equals(reconciliationRun.id),
            ))
            .getSingleOrNull();
    if (existing != null) {
      if (existing.status == 'completed') {
        return CardEvolutionCollectorClaimOutcome('completed', existing);
      }
      if (existing.inputHash != inputHash) {
        return const CardEvolutionCollectorClaimOutcome('staleInput');
      }
      if (existing.leaseExpiresAt > now && existing.ownerId != ownerId) {
        return const CardEvolutionCollectorClaimOutcome('busy');
      }
      final changed =
          await (db.update(db.cardEvolutionCollectorRuns)..where(
                (row) =>
                    row.id.equals(existing.id) & row.status.equals('claimed'),
              ))
              .write(
                CardEvolutionCollectorRunsCompanion(
                  ownerId: Value(ownerId),
                  leaseExpiresAt: Value(now + leaseSeconds),
                ),
              );
      if (changed != 1) {
        return const CardEvolutionCollectorClaimOutcome('busy');
      }
      final row = await (db.select(
        db.cardEvolutionCollectorRuns,
      )..where((row) => row.id.equals(existing.id))).getSingle();
      return CardEvolutionCollectorClaimOutcome('existing', row);
    }

    final nextOrdinalRow = await db
        .customSelect(
          'SELECT COALESCE(MAX(collector_ordinal), 0) + 1 AS ordinal '
          'FROM card_evolution_collector_runs WHERE session_id = ?',
          variables: [Variable.withString(reconciliationRun.sessionId)],
        )
        .getSingle();
    final collectorOrdinal = nextOrdinalRow.read<int>('ordinal');
    final id = 'evolution-collector-${generateId()}';
    try {
      await db
          .into(db.cardEvolutionCollectorRuns)
          .insert(
            CardEvolutionCollectorRunsCompanion.insert(
              id: id,
              sessionId: reconciliationRun.sessionId,
              characterId: characterId,
              collectorOrdinal: collectorOrdinal,
              reconciliationRunId: reconciliationRun.id,
              reconciliationRunOrdinal: reconciliationRun.ordinal,
              reconciliationChainHash: reconciliationRun.chainHash,
              rangeHash: reconciliationRun.rangeHash,
              inputHash: inputHash,
              ownerId: ownerId,
              status: 'claimed',
              leaseExpiresAt: now + leaseSeconds,
              createdAt: now,
            ),
          );
    } catch (_) {
      return const CardEvolutionCollectorClaimOutcome('busy');
    }
    final row = await (db.select(
      db.cardEvolutionCollectorRuns,
    )..where((item) => item.id.equals(id))).getSingle();
    return CardEvolutionCollectorClaimOutcome('claimed', row);
  });

  Future<bool> complete({
    required String id,
    required String ownerId,
    required String modelOutputHash,
    required int now,
  }) async {
    final changed =
        await (db.update(db.cardEvolutionCollectorRuns)..where(
              (row) =>
                  row.id.equals(id) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed') &
                  row.leaseExpiresAt.isBiggerThanValue(now),
            ))
            .write(
              CardEvolutionCollectorRunsCompanion(
                status: const Value('completed'),
                modelOutputHash: Value(modelOutputHash),
                completedAt: Value(now),
              ),
            );
    return changed == 1;
  }

  /// Commits observation effects and collector completion atomically. If a
  /// chat mutation removed the claimed collector while its model call was in
  /// flight, no effects are applied.
  Future<bool> completeWithEffects({
    required String id,
    required String ownerId,
    required String modelOutputHash,
    required int now,
    required Future<void> Function() applyEffects,
  }) => db.transaction(() async {
    final claimed =
        await (db.select(db.cardEvolutionCollectorRuns)..where(
              (row) =>
                  row.id.equals(id) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed') &
                  row.leaseExpiresAt.isBiggerThanValue(now),
            ))
            .getSingleOrNull();
    if (claimed == null) return false;
    await applyEffects();
    final changed =
        await (db.update(db.cardEvolutionCollectorRuns)..where(
              (row) =>
                  row.id.equals(id) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed') &
                  row.leaseExpiresAt.isBiggerThanValue(now),
            ))
            .write(
              CardEvolutionCollectorRunsCompanion(
                status: const Value('completed'),
                modelOutputHash: Value(modelOutputHash),
                completedAt: Value(now),
              ),
            );
    if (changed != 1) {
      throw StateError('Collector claim changed in transaction');
    }
    return true;
  });

  Future<void> abandon({required String id, required String ownerId}) =>
      (db.delete(db.cardEvolutionCollectorRuns)..where(
            (row) =>
                row.id.equals(id) &
                row.ownerId.equals(ownerId) &
                row.status.equals('claimed'),
          ))
          .go();

  Future<int> latestCompletedOrdinal(String sessionId) async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(collector_ordinal), 0) AS ordinal '
          'FROM card_evolution_collector_runs '
          "WHERE session_id = ? AND status = 'completed'",
          variables: [Variable.withString(sessionId)],
        )
        .getSingle();
    return row.read<int>('ordinal');
  }

  Future<int> latestDeliveredWriterBoundary(String sessionId) async {
    final claims =
        await (db.select(db.cardEvolutionClaims)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where((row) => row.status.equals('completed'))
              ..where((row) => row.predecessorRunOrdinal.isBiggerThanValue(0))
              ..orderBy([
                (row) => OrderingTerm.desc(row.predecessorRunOrdinal),
              ]))
            .get();
    for (final claim in claims) {
      final boundary =
          await (db.select(db.cardEvolutionCollectorRuns)
                ..where((row) => row.sessionId.equals(sessionId))
                ..where(
                  (row) =>
                      row.collectorOrdinal.equals(claim.predecessorRunOrdinal),
                )
                ..where((row) => row.status.equals('completed')))
              .getSingleOrNull();
      if (boundary != null &&
          boundary.reconciliationChainHash == claim.predecessorCursorHash) {
        return claim.predecessorRunOrdinal;
      }
    }
    return 0;
  }

  /// Valid logical reconciliation runs which do not yet have a completed
  /// collector. This is the durable backlog used to recover runs skipped by a
  /// crash, a disabled model, or a superseded post-generation callback.
  Future<List<LedgerReconciliationSuccessfulRunRow>> pendingValidRuns(
    String sessionId, {
    LedgerReconciliationSuccessfulRunRow? currentRun,
  }) async {
    final runs = await LedgerReconciliationRunRepo(db).readSession(sessionId);
    if (currentRun != null &&
        currentRun.sessionId == sessionId &&
        !runs.any((run) => run.id == currentRun.id)) {
      final invalidated =
          await (db.select(db.ledgerReconciliationRunInvalidations)..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.runId.equals(currentRun.id),
              ))
              .getSingleOrNull();
      // The orchestration caller already obtained this row as its current
      // successful run. Keep that direct hand-off usable for legacy/imported
      // chains which cannot be projected as a complete backlog; the collector
      // snapshot still validates the run's live evidence fail-closed.
      if (invalidated == null) runs.add(currentRun);
    }
    runs.sort((left, right) => left.ordinal.compareTo(right.ordinal));
    final collectors =
        await (db.select(db.cardEvolutionCollectorRuns)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.status.equals('completed'),
            ))
            .get();
    final completedIds = collectors
        .map((row) => row.reconciliationRunId)
        .toSet();
    return [
      for (final run in runs)
        if (!completedIds.contains(run.id)) run,
    ];
  }

  /// Exact three completed collectors ending at [boundary]. Gaps or claimed
  /// rows fail closed, so a writer never substitutes newer reconciliation data.
  Future<List<CardEvolutionCollectorRunRow>> completedBoundary(
    String sessionId,
    int boundary,
  ) async {
    if (boundary < 3) return const [];
    final rows =
        await (db.select(db.cardEvolutionCollectorRuns)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where(
                (row) => row.collectorOrdinal.isBetweenValues(
                  boundary - 2,
                  boundary,
                ),
              )
              ..where((row) => row.status.equals('completed'))
              ..orderBy([(row) => OrderingTerm.asc(row.collectorOrdinal)]))
            .get();
    if (rows.length != 3 ||
        rows.indexed.any(
          (entry) => entry.$2.collectorOrdinal != boundary - 2 + entry.$1,
        )) {
      return const [];
    }
    return rows;
  }
}
