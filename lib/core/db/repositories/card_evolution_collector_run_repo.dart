import 'package:drift/drift.dart';

import '../../utils/id_generator.dart';
import '../app_db.dart';

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

    final id = 'evolution-collector-${generateId()}';
    try {
      await db
          .into(db.cardEvolutionCollectorRuns)
          .insert(
            CardEvolutionCollectorRunsCompanion.insert(
              id: id,
              sessionId: reconciliationRun.sessionId,
              characterId: characterId,
              collectorOrdinal: reconciliationRun.ordinal,
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
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(predecessor_run_ordinal), 0) AS ordinal '
          'FROM card_evolution_claims '
          "WHERE session_id = ? AND status = 'completed'",
          variables: [Variable.withString(sessionId)],
        )
        .getSingle();
    return row.read<int>('ordinal');
  }
}
