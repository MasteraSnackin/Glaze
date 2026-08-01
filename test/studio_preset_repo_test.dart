import 'dart:convert';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  late AppDatabase db;
  late StudioPresetRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = StudioPresetRepo(db);
  });
  tearDown(() => db.close());

  test('round-trips complete preset runtime payload', () async {
    const preset = StudioPreset(
      id: 'studio_direct_loom_v1',
      name: 'Direct Loom v1',
      executionMode: StudioExecutionMode.direct,
      agentEnabled: {'continuity': false, 'narrative': false, 'final': true},
      agents: [
        StudioAgent(id: 'continuity', controllerId: 'continuity'),
        StudioAgent(id: 'final', controllerId: 'final'),
      ],
      expensiveApiConfigId: 'expensive',
      cheapApiConfigId: 'cheap',
      cleanerApiConfigId: 'cleaner',
      maxFinalHistoryMessages: 17,
    );

    await repo.upsert(preset);
    final restored = await repo.getById(preset.id);

    expect(restored?.executionMode, StudioExecutionMode.direct);
    expect(restored?.agentEnabled, preset.agentEnabled);
    expect(restored?.agents, preset.agents);
    expect(restored?.expensiveApiConfigId, 'expensive');
    expect(restored?.cheapApiConfigId, 'cheap');
    expect(restored?.cleanerApiConfigId, 'cleaner');
    expect(restored?.maxFinalHistoryMessages, 17);
  });

  test('unknown persisted execution mode safely falls back to legacy', () {
    expect(
      StudioExecutionMode.fromWireName('future-topology'),
      StudioExecutionMode.legacy,
    );
  });

  test('reads legacy block rows and upserts canonical JSON', () async {
    await db
        .into(db.studioPresetRows)
        .insert(
          StudioPresetRowsCompanion.insert(
            presetId: 'legacy',
            name: 'Legacy',
            blocksJson: Value(
              jsonEncode([
                {
                  'id': 'continuity_task',
                  'kind': 'tracker_instruction',
                  'content': 'Track it',
                  'section': 'pregen',
                },
              ]),
            ),
          ),
        );

    final preset = await repo.getById('legacy');
    expect(preset?.blocks.single.targetAgentId, 'continuity');

    await repo.upsert(preset!);
    final row = await (db.select(
      db.studioPresetRows,
    )..where((table) => table.presetId.equals('legacy'))).getSingle();
    final block = (jsonDecode(row.blocksJson) as List).single as Map;
    expect(block['type'], 'instruction');
    expect(block.containsKey('kind'), isFalse);
  });
}
