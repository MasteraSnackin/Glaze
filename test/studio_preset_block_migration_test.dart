import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_migration.dart';

void main() {
  group('migrateStudioPresetBlocksToV2', () {
    test('maps previous_agents → pregenBrief and clears legacy fields', () {
      final out = migrateStudioPresetBlocksToV2(const [
        StudioPresetBlock(
          id: 'previous_agents',
          kind: 'previous_agents',
          section: 'final',
        ),
      ]);
      expect(out, hasLength(1));
      expect(out.single.mode, 'pregenBrief');
      expect(out.single.injectionPoint, 'final');
      expect(out.single.kind, isEmpty);
      expect(out.single.section, isEmpty);
    });

    test('routes tracker_instruction to its controller via targetAgentId', () {
      final out = migrateStudioPresetBlocksToV2(const [
        StudioPresetBlock(
          id: 'continuity_task',
          kind: 'tracker_instruction',
          section: 'pregen',
        ),
        StudioPresetBlock(
          id: 'agency_task',
          kind: 'tracker_instruction',
          section: 'pregen',
        ),
        StudioPresetBlock(
          id: 'guard_task',
          title: 'Anti-Loop & Prose Guard',
          kind: 'tracker_instruction',
          section: 'pregen',
        ),
      ]);
      expect(out.map((b) => b.injectionPoint), everyElement('specificAgent'));
      expect(out.map((b) => b.targetAgentId), ['continuity', 'agency', 'guard']);
      expect(out.map((b) => b.mode), everyElement('direct'));
    });

    test('custom_text keeps its section as the injection point', () {
      final out = migrateStudioPresetBlocksToV2(const [
        StudioPresetBlock(id: 'a', kind: 'custom_text', section: 'pregen'),
        StudioPresetBlock(id: 'b', kind: 'custom_text', section: 'final'),
        StudioPresetBlock(id: 'c', kind: 'custom_text', section: 'cleaner'),
        StudioPresetBlock(id: 'd', kind: 'custom_text', section: 'ledger'),
      ]);
      expect(out.map((b) => b.injectionPoint), [
        'pregen',
        'final',
        'cleaner',
        'ledger',
      ]);
      expect(out.map((b) => b.mode), everyElement('direct'));
    });

    test('drops agent_instruction and dead build/brief_parser sections', () {
      final out = migrateStudioPresetBlocksToV2(const [
        StudioPresetBlock(
          id: 'env',
          kind: 'agent_instruction',
          section: 'pregen',
        ),
        StudioPresetBlock(id: 'r', kind: 'custom_text', section: 'build'),
        StudioPresetBlock(
          id: 'p',
          kind: 'custom_text',
          section: 'brief_parser',
        ),
        StudioPresetBlock(id: 'keep', kind: 'custom_text', section: 'pregen'),
      ]);
      expect(out.map((b) => b.id), ['keep']);
    });

    test('group boundaries move to the groupBoundary field with empty mode', () {
      final out = migrateStudioPresetBlocksToV2(const [
        StudioPresetBlock(id: 'o', kind: 'group_open', section: 'pregen'),
        StudioPresetBlock(id: 'c', kind: 'group_close', section: 'pregen'),
      ]);
      expect(out[0].groupBoundary, 'open');
      expect(out[1].groupBoundary, 'close');
      expect(out.map((b) => b.mode), everyElement(''));
    });

    test('context kinds get an empty mode and a canonical id', () {
      final out = migrateStudioPresetBlocksToV2(const [
        StudioPresetBlock(id: 'hist_block', kind: 'chat_history', section: 'final'),
      ]);
      expect(out.single.id, 'chat_history');
      expect(out.single.mode, isEmpty);
      expect(out.single.injectionPoint, 'final');
    });

    test('is idempotent and leaves editor-created blocks untouched', () {
      const legacy = [
        StudioPresetBlock(
          id: 'continuity_task',
          kind: 'tracker_instruction',
          section: 'pregen',
        ),
        // Editor-created block: kind/section cleared, explicit new fields
        // (mirrors what StudioPresetEditorBody._addBlock produces).
        StudioPresetBlock(
          id: 'custom',
          kind: '',
          section: '',
          mode: 'direct',
          injectionPoint: 'final',
        ),
      ];
      final once = migrateStudioPresetBlocksToV2(legacy);
      final twice = migrateStudioPresetBlocksToV2(once);
      expect(studioPresetBlocksNeedMigration(once), isFalse);
      expect(twice, same(once)); // no-op on the second pass
      final custom = once.firstWhere((b) => b.id == 'custom');
      expect(custom.injectionPoint, 'final');
      expect(custom.mode, 'direct');
    });
  });
}
