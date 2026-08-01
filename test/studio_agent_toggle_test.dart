import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/chat/widgets/studio_agents_sheet.dart';

void main() {
  group('StudioAgentsSheet agent toggle', () {
    const preset = StudioPreset(
      id: 'p1',
      blocks: [
        StudioPresetBlock(id: 'continuity_task', section: 'pregen'),
        StudioPresetBlock(id: 'cleaner_beauty', section: 'cleaner'),
      ],
    );

    test('disabling an agent updates agentEnabled map', () {
      final result = applyStudioAgentToggle(preset, 'continuity', false);

      expect(result.agentEnabled['continuity'], isFalse);
      expect(result.blocks.every((block) => block.enabled), isTrue);
    });

    test('lockedOn spec (final) cannot be toggled off', () {
      final result = applyStudioAgentToggle(preset, 'final', false);

      expect(result, same(preset));
    });

    test('enabling an agent updates agentEnabled map', () {
      final disabled = preset.copyWith(agentEnabled: {'continuity': false});
      final result = applyStudioAgentToggle(disabled, 'continuity', true);

      expect(result.agentEnabled['continuity'], isTrue);
    });
  });
}
