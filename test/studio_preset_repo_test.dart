import 'dart:convert';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/models/cleaner_settings.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_agent_settings.dart';

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
      agentEnabled: {'continuity': false, 'final': true},
      agents: [
        StudioAgent(id: 'continuity', controllerId: 'continuity'),
        StudioAgent(id: 'final', controllerId: 'final'),
      ],
      expensiveApiConfigId: 'expensive',
      cheapApiConfigId: 'cheap',
      cleanerApiConfigId: 'cleaner',
      maxFinalHistoryMessages: 17,
      runtime: StudioRuntimeSettings(
        agents: StudioAgentSettings(
          studioFinalExtraRequestParameters: [
            ExtraRequestParameter(key: 'custom', value: '{"nested":true}'),
          ],
        ),
        cleaner: CleanerSettings(postCleanerMaxTokens: 1234),
        broadcastBlocks: ['\uFEFFfirst\r\nline', 'second\nline'],
      ),
    );

    await repo.upsert(preset);
    final restored = await repo.getById(preset.id);

    expect(restored?.agentEnabled, preset.agentEnabled);
    expect(restored?.agents, preset.agents);
    expect(restored?.expensiveApiConfigId, 'expensive');
    expect(restored?.cheapApiConfigId, 'cheap');
    expect(restored?.cleanerApiConfigId, 'cleaner');
    expect(restored?.maxFinalHistoryMessages, 17);
    expect(restored?.runtime, preset.runtime);
    expect(restored?.runtime.broadcastBlocks, preset.runtime.broadcastBlocks);
    expect(restored?.name, preset.name);
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

  test(
    'empty and malformed runtime JSON default without damaging payload',
    () async {
      for (final entry in {'empty': '{}', 'malformed': '{not-json'}.entries) {
        await db
            .into(db.studioPresetRows)
            .insert(
              StudioPresetRowsCompanion.insert(
                presetId: entry.key,
                name: entry.key,
                blocksJson: Value(
                  jsonEncode([
                    {'id': 'history', 'kind': 'chat_history'},
                  ]),
                ),
                agentsJson: Value(
                  jsonEncode([
                    {'id': 'agent_${entry.key}_continuity_1'},
                  ]),
                ),
                runtimeSettingsJson: Value(entry.value),
              ),
            );

        final restored = await repo.getById(entry.key);
        expect(restored?.runtime, const StudioRuntimeSettings());
        expect(restored?.blocks.single.type, StudioBlockType.history);
        expect(restored?.agents.single.controllerId, 'continuity');
      }
    },
  );
}
