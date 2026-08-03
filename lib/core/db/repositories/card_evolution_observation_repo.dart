import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/card_evolution_observation.dart';
import '../app_db.dart';

/// Repository for the Card Rewriter observation journal. Observations are
/// session-scoped candidate durable changes recorded by the observation pass.
/// One active observation per `(sessionId, semanticScopeKey)` is enforced by a
/// unique key; confirmations bump `repeatCount`/`lastConfirmedRun`, promotion
/// flips `status` to `promoted`, and a successful apply marks it `consumed`.
class CardEvolutionObservationRepo {
  CardEvolutionObservationRepo(this.db);

  final AppDatabase db;

  Future<CardEvolutionObservation?> findByScopeKey(
    String sessionId,
    String semanticScopeKey,
  ) => db.transaction(() async {
    final row =
        await (db.select(db.cardEvolutionObservations)
              ..where((r) => r.sessionId.equals(sessionId))
              ..where((r) => r.semanticScopeKey.equals(semanticScopeKey)))
            .getSingleOrNull();
    return row == null ? null : _toModel(row);
  });

  Future<CardEvolutionObservation?> findById(String id) =>
      db.transaction(() async {
        final row = await (db.select(
          db.cardEvolutionObservations,
        )..where((r) => r.id.equals(id))).getSingleOrNull();
        return row == null ? null : _toModel(row);
      });

  Future<void> insertObservation(CardEvolutionObservation observation) => db
      .into(db.cardEvolutionObservations)
      .insert(
        CardEvolutionObservationsCompanion.insert(
          id: observation.id,
          sessionId: observation.sessionId,
          characterId: observation.characterId,
          runOrdinal: observation.runOrdinal,
          semanticScopeKey: observation.semanticScopeKey,
          observedChange: observation.observedChange,
          canonicalClaim: Value(observation.canonicalClaim),
          evidenceMessageIds: jsonEncode(observation.evidenceMessageIds),
          cardFieldPath: Value(observation.cardFieldPath),
          lorebookEntryId: Value(observation.lorebookEntryId),
          confidence: observation.confidence,
          status: observation.status,
          firstSeenRun: observation.firstSeenRun,
          repeatCount: Value(observation.repeatCount),
          lastConfirmedRun: Value(observation.lastConfirmedRun),
          createdAt: observation.createdAt,
          updatedAt: observation.updatedAt,
        ),
      );

  Future<void> confirmObservation({
    required String id,
    required int runOrdinal,
    required double confidence,
    required int now,
  }) => db.transaction(() async {
    final row = await (db.select(
      db.cardEvolutionObservations,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    await (db.update(
      db.cardEvolutionObservations,
    )..where((r) => r.id.equals(id))).write(
      CardEvolutionObservationsCompanion(
        repeatCount: Value(row.repeatCount + 1),
        lastConfirmedRun: Value(runOrdinal),
        confidence: Value(confidence),
        updatedAt: Value(now),
      ),
    );
  });

  Future<void> promoteObservation(String id, {required int now}) =>
      (db.update(db.cardEvolutionObservations)
            ..where((r) => r.id.equals(id))
            ..where((r) => r.status.equals('active')))
          .write(
            CardEvolutionObservationsCompanion(
              status: const Value('promoted'),
              updatedAt: Value(now),
            ),
          );

  Future<void> expireObservation(String id, {required int now}) =>
      (db.update(db.cardEvolutionObservations)
            ..where((r) => r.id.equals(id))
            ..where((r) => r.status.equals('active')))
          .write(
            CardEvolutionObservationsCompanion(
              status: const Value('expired'),
              updatedAt: Value(now),
            ),
          );

  Future<void> consumeObservation(String id, {required int now}) =>
      (db.update(db.cardEvolutionObservations)
            ..where((r) => r.id.equals(id))
            ..where((r) => r.status.equals('promoted')))
          .write(
            CardEvolutionObservationsCompanion(
              status: const Value('consumed'),
              updatedAt: Value(now),
            ),
          );

  Future<List<CardEvolutionObservation>> getActiveObservations(
    String sessionId,
  ) => db.transaction(() async {
    final rows =
        await (db.select(db.cardEvolutionObservations)
              ..where((r) => r.sessionId.equals(sessionId))
              ..where((r) => r.status.equals('active'))
              ..orderBy([(r) => OrderingTerm.asc(r.createdAt)]))
            .get();
    return [for (final row in rows) _toModel(row)];
  });

  Future<List<CardEvolutionObservation>> getPromotedObservations(
    String sessionId,
  ) => db.transaction(() async {
    final rows =
        await (db.select(db.cardEvolutionObservations)
              ..where((r) => r.sessionId.equals(sessionId))
              ..where((r) => r.status.equals('promoted'))
              ..orderBy([(r) => OrderingTerm.asc(r.createdAt)]))
            .get();
    return [for (final row in rows) _toModel(row)];
  });

  Future<List<CardEvolutionObservation>> getPromotableObservations(
    String sessionId, {
    required int minRepeatCount,
    required double minConfidence,
  }) => db.transaction(() async {
    final rows =
        await (db.select(db.cardEvolutionObservations)
              ..where((r) => r.sessionId.equals(sessionId))
              ..where((r) => r.status.equals('active'))
              ..where((r) => r.repeatCount.isBiggerOrEqualValue(minRepeatCount))
              ..where((r) => r.confidence.isBiggerOrEqualValue(minConfidence)))
            .get();
    return [for (final row in rows) _toModel(row)];
  });

  Future<List<CardEvolutionObservation>> getExpiryCandidates(
    String sessionId, {
    required int currentRunOrdinal,
    required int expiryRuns,
  }) => db.transaction(() async {
    final rows =
        await (db.select(db.cardEvolutionObservations)
              ..where((r) => r.sessionId.equals(sessionId))
              ..where((r) => r.status.equals('active'))
              ..where((r) => r.lastConfirmedRun.isNotNull()))
            .get();
    return [
      for (final row in rows)
        if (currentRunOrdinal - (row.lastConfirmedRun ?? currentRunOrdinal) >=
            expiryRuns)
          _toModel(row),
    ];
  });

  static CardEvolutionObservation _toModel(CardEvolutionObservationRow row) {
    List<String> evidence;
    try {
      final decoded = jsonDecode(row.evidenceMessageIds);
      evidence = decoded is List
          ? [for (final item in decoded) item.toString()]
          : const [];
    } catch (_) {
      evidence = const [];
    }
    return CardEvolutionObservation(
      id: row.id,
      sessionId: row.sessionId,
      characterId: row.characterId,
      runOrdinal: row.runOrdinal,
      semanticScopeKey: row.semanticScopeKey,
      observedChange: row.observedChange,
      canonicalClaim: row.canonicalClaim,
      evidenceMessageIds: evidence,
      cardFieldPath: row.cardFieldPath,
      lorebookEntryId: row.lorebookEntryId,
      confidence: row.confidence,
      status: row.status,
      firstSeenRun: row.firstSeenRun,
      repeatCount: row.repeatCount,
      lastConfirmedRun: row.lastConfirmedRun,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }
}
