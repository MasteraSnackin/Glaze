import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

void main() {
  late AppDatabase db;
  late LedgerRawTrackerStateReader reader;
  late TrackerRepo trackers;
  late TrackerSnapshotRepo snapshots;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    reader = LedgerRawTrackerStateReader(db);
    trackers = TrackerRepo(db);
    snapshots = TrackerSnapshotRepo(db);
  });
  tearDown(() => db.close());

  test(
    'reads committed Ledger snapshot and only live canon controls',
    () async {
      await snapshots.upsertTrackers(
        sessionId: 'session',
        messageId: 'message',
        swipeId: 0,
        agentSwipeId: 0,
        committed: true,
        trackers: const [
          Tracker(sessionId: 'session', name: 'world:time', scope: 'ledger'),
          Tracker(sessionId: 'session', name: 'chat:value', scope: 'chat'),
        ],
      );
      await trackers.upsertValue(
        'session',
        'canon_override:world:time',
        'night',
        scope: 'ledger',
      );
      await trackers.upsertValue(
        'session',
        'canon_lock:world:place',
        'true',
        scope: 'ledger',
      );
      await trackers.upsertValue(
        'session',
        'world:uncommitted',
        'ignored',
        scope: 'ledger',
      );

      final state = await db.transaction(() => reader.read('session'));

      expect(state.committedTrackers.map((item) => item.name), ['world:time']);
      expect(state.manualControls.map((item) => item.name), [
        'canon_lock:world:place',
        'canon_override:world:time',
      ]);
    },
  );
}
