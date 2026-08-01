import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_codec.dart';

void main() {
  test('canonicalizes persisted block arrays and rejects malformed shapes', () {
    final encoded = StudioPresetCodec.canonicalizeBlocksJson(
      jsonEncode([
        {'id': 'history', 'kind': 'chat_history'},
      ]),
    );
    final decoded = jsonDecode(encoded) as List;
    expect(decoded.single['type'], 'history');
    expect(decoded.single, isNot(contains('kind')));
    expect(
      () => StudioPresetCodec.canonicalizeBlocksJson('{}'),
      throwsFormatException,
    );
  });

  test('canonicalizes legacy blocks and writes no kind', () {
    final result = StudioPresetCodec.decodePreset({
      'id': 'legacy',
      'name': 'Legacy',
      'blocks': [
        {
          'id': 'continuity_task_universal',
          'name': 'Continuity task',
          'kind': 'tracker_instruction',
          'content': 'Track continuity',
          'section': 'pregen',
        },
        {'id': 'history', 'kind': 'chat_history'},
        {'id': 'static', 'kind': 'static_context'},
        {'id': 'memory', 'kind': 'memory'},
        {'id': 'briefs', 'kind': 'previous_agents'},
      ],
    });

    expect(result.warnings, isEmpty);
    expect(result.preset.blocks[0].targetAgentId, 'continuity');
    expect(result.preset.blocks[0].title, 'Continuity task');
    expect(result.preset.blocks[1].type, StudioBlockType.history);
    expect(
      result.preset.blocks[2].contextSlot,
      StudioContextSlot.staticContext,
    );
    expect(result.preset.blocks[3].contextSlot, StudioContextSlot.memory);
    expect(result.preset.blocks[4].type, StudioBlockType.priorBriefs);
    final canonical = StudioPresetCodec.canonicalizePresetJson({
      'id': 'legacy',
      'blocks': [
        {'id': 'history', 'kind': 'chat_history'},
      ],
    });
    for (final block in canonical['blocks'] as List<dynamic>) {
      expect(block as Map<String, dynamic>, isNot(contains('kind')));
    }
  });

  test('unresolved and ambiguous tracker aliases fail closed', () {
    for (final json in [
      {'id': 'mystery', 'kind': 'tracker_instruction', 'content': 'Task'},
      {
        'id': 'continuity_dialogue',
        'kind': 'tracker_instruction',
        'content': 'Task',
      },
    ]) {
      final result = StudioPresetCodec.canonicalizeBlock(json);
      expect(result.block.enabled, isFalse);
      expect(result.block.targetAgentId, isNull);
      expect(result.warning, isNotNull);
    }
  });

  test(
    'unknown content is preserved and unknown blank blocks are disabled',
    () {
      final content = StudioPresetCodec.canonicalizeBlock({
        'id': 'future',
        'kind': 'future_kind',
        'content': 'Keep me',
        'role': 'user',
        'locked': true,
        'order': 9,
        'section': 'final',
      });
      final blank = StudioPresetCodec.canonicalizeBlock({
        'id': 'blank',
        'kind': 'future_kind',
      });

      expect(content.block.type, StudioBlockType.instruction);
      expect(content.block.content, 'Keep me');
      expect(content.block.role, 'user');
      expect(content.block.locked, isTrue);
      expect(content.block.order, 9);
      expect(content.block.section, 'final');
      expect(blank.block.enabled, isFalse);
      expect(blank.warning, isNotNull);
    },
  );

  test('canonicalization is idempotent', () {
    final once = StudioPresetCodec.canonicalizeBlockJson({
      'id': 'dynamic',
      'kind': 'dynamic_context',
      'enabled': true,
    });
    final twice = StudioPresetCodec.canonicalizeBlockJson(once);

    expect(twice, once);
  });

  test('canonicalizes imported agents and defaults runtime fields', () {
    final decoded = StudioPresetCodec.decodePreset({
      'id': 'imported',
      'agents': [
        {'id': 'agent_session_continuity_123', 'sourceBlockNames': 'legacy'},
        {'id': 'unknown', 'enabled': true},
      ],
    });

    expect(decoded.preset.agents[0].controllerId, 'continuity');
    expect(decoded.preset.agents[1].enabled, isFalse);
    expect(decoded.preset.maxFinalHistoryMessages, 30);
    expect(decoded.preset.expensiveApiConfigId, isEmpty);
    final canonical = StudioPresetCodec.canonicalizePresetJson({
      'id': 'imported',
      'agents': [
        {'id': 'agent_session_continuity_123'},
      ],
    });
    expect((canonical['agents'] as List).single['controllerId'], 'continuity');
  });

  test('missing agents gets preset-scoped defaults but explicit empty stays empty', () {
    final missing = StudioPresetCodec.decodePreset({
      'id': 'legacy-preset',
      'updatedAt': 42,
    }).preset;
    final explicit = StudioPresetCodec.decodePreset({
      'id': 'explicit-empty',
      'agents': <dynamic>[],
    }).preset;

    expect(missing.agents, isNotEmpty);
    expect(missing.agents.every((agent) => agent.id.contains('legacy-preset')), isTrue);
    expect(explicit.agents, isEmpty);
  });
}
