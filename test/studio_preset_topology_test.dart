import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_topology.dart';

void main() {
  const source = StudioPreset(
    id: 'source',
    name: 'Source',
    blocks: [
      StudioPresetBlock(
        id: 'continuity_task_universal',
        targetAgentId: 'continuity',
        content: 'Authored continuity task.',
      ),
      StudioPresetBlock(id: 'agency_task', targetAgentId: 'agency'),
      StudioPresetBlock(
        id: 'cleaner_beauty',
        section: 'cleaner',
        enabled: false,
      ),
      StudioPresetBlock(
        id: 'optional_style',
        section: 'final',
        enabled: false,
        content: 'Optional authored style.',
      ),
      StudioPresetBlock(
        id: 'mixed_briefs',
        section: 'final',
        content:
            'Keep this independent instruction.\n{{STUDIO_AGENT_BRIEFS}}\n'
            '{{studio_tracker_briefs}}',
      ),
      StudioPresetBlock(
        id: 'final_response_shape_contract',
        section: 'final',
        content: 'Authored final contract.',
      ),
    ],
  );

  test('direct preset has no pregen tasks and keeps cleaner beauty', () {
    final preset = prepareStudioPresetForMode(
      source,
      id: 'direct',
      name: 'Direct',
      mode: StudioExecutionMode.direct,
      updatedAt: 1,
    );

    expect(preset.blocks.where((b) => b.targetAgentId != null), isEmpty);
    expect(
      preset.blocks.any(
        (b) => b.content.toLowerCase().contains(
          RegExp(r'\{\{studio_.+_briefs?\}\}'),
        ),
      ),
      isFalse,
    );
    expect(
      preset.blocks.firstWhere((b) => b.id == 'mixed_briefs').content,
      'Keep this independent instruction.\n\n',
    );
    expect(
      preset.blocks.firstWhere((b) => b.id == 'cleaner_beauty').enabled,
      isTrue,
    );
    expect(
      preset.blocks.firstWhere((b) => b.id == 'optional_style').enabled,
      isFalse,
    );
    expect(
      preset.blocks
          .firstWhere((b) => b.id == 'final_response_shape_contract')
          .content,
      'Authored final contract.',
    );
    expect(preset.agentEnabled['final'], isTrue);
    expect(preset.agentEnabled['continuity'], isFalse);
  });

  test('assisted preset includes continuity', () {
    final preset = prepareStudioPresetForMode(
      source,
      id: 'assisted',
      name: 'Assisted',
      mode: StudioExecutionMode.assisted,
      updatedAt: 1,
    );

    expect(
      preset.blocks
          .where((b) => b.targetAgentId != null)
          .map((b) => b.targetAgentId),
      ['continuity'],
    );
    expect(preset.agentEnabled['continuity'], isTrue);
    expect(preset.agentEnabled['meta'], isFalse);
    expect(
      preset.blocks.firstWhere((b) => b.id == 'cleaner_beauty').enabled,
      isTrue,
    );
    expect(
      preset.blocks
          .firstWhere((b) => b.id == 'continuity_task_universal')
          .content,
      'Authored continuity task.',
    );
    expect(
      preset.blocks
          .firstWhere((b) => b.id == 'final_response_shape_contract')
          .content,
      'Authored final contract.',
    );
  });
}
