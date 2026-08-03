import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_observation_repo.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';

void main() {
  late AppDatabase db;
  late CardEvolutionObservationRepo repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CardEvolutionObservationRepo(db);
  });
  tearDown(() => db.close());

  test('insert and find by scope key', () async {
    await repo.insertObservation(_observation());
    final found = await repo.findByScopeKey(
      'session',
      'character.preference.X',
    );
    expect(found, isNotNull);
    expect(found!.status, 'active');
    expect(found.repeatCount, 1);
    expect(found.lastConfirmedRun, isNull);
    expect(found.evidenceMessageIds, ['msg:1', 'msg:2']);
  });

  test('confirm bumps repeat count and last confirmed run', () async {
    await repo.insertObservation(_observation());
    await repo.confirmObservation(
      id: 'obs-1',
      runOrdinal: 2,
      confidence: 0.8,
      now: 20,
    );
    final found = await repo.findByScopeKey(
      'session',
      'character.preference.X',
    );
    expect(found!.repeatCount, 2);
    expect(found.lastConfirmedRun, 2);
    expect(found.confidence, 0.8);
    expect(found.updatedAt, 20);
  });

  test('promote flips status and excludes from active', () async {
    await repo.insertObservation(_observation());
    await repo.promoteObservation('obs-1', now: 20);
    expect(await repo.getActiveObservations('session'), isEmpty);
    final promoted = await repo.getPromotedObservations('session');
    expect(promoted, hasLength(1));
    expect(promoted.first.status, 'promoted');
  });

  test('expire flips status and excludes from active', () async {
    await repo.insertObservation(_observation());
    await repo.expireObservation('obs-1', now: 20);
    expect(await repo.getActiveObservations('session'), isEmpty);
  });

  test('consume flips promoted to consumed', () async {
    await repo.insertObservation(_observation());
    await repo.promoteObservation('obs-1', now: 20);
    await repo.consumeObservation('obs-1', now: 30);
    expect(await repo.getPromotedObservations('session'), isEmpty);
  });

  test('getPromotable filters by repeat count and confidence', () async {
    await repo.insertObservation(_observation(repeatCount: 2, confidence: 0.6));
    await repo.insertObservation(
      _observation(
        id: 'obs-2',
        scopeKey: 'character.attitude.Y',
        repeatCount: 3,
        confidence: 0.8,
      ),
    );
    final promotable = await repo.getPromotableObservations(
      'session',
      minRepeatCount: 3,
      minConfidence: 0.7,
    );
    expect(promotable, hasLength(1));
    expect(promotable.first.id, 'obs-2');
  });

  test('getExpiryCandidates filters by last confirmed run gap', () async {
    await repo.insertObservation(_observation(lastConfirmedRun: 1));
    await repo.insertObservation(
      _observation(
        id: 'obs-2',
        scopeKey: 'character.attitude.Y',
        lastConfirmedRun: 5,
      ),
    );
    final expired = await repo.getExpiryCandidates(
      'session',
      currentRunOrdinal: 6,
      expiryRuns: 4,
    );
    expect(expired, hasLength(1));
    expect(expired.first.id, 'obs-1');
  });

  test('unique key collision on insert throws', () async {
    await repo.insertObservation(_observation());
    await expectLater(
      repo.insertObservation(_observation()),
      throwsA(isA<Object>()),
    );
  });
}

CardEvolutionObservation _observation({
  String id = 'obs-1',
  String scopeKey = 'character.preference.X',
  int repeatCount = 1,
  double confidence = 0.5,
  int? lastConfirmedRun,
}) => CardEvolutionObservation(
  id: id,
  sessionId: 'session',
  characterId: 'character',
  runOrdinal: 1,
  semanticScopeKey: scopeKey,
  observedChange: 'Alice is becoming more trusting',
  canonicalClaim: 'Alice has become more trusting over time',
  evidenceMessageIds: const ['msg:1', 'msg:2'],
  cardFieldPath: 'personality',
  confidence: confidence,
  status: 'active',
  firstSeenRun: 1,
  repeatCount: repeatCount,
  lastConfirmedRun: lastConfirmedRun,
  createdAt: 10,
  updatedAt: 10,
);
