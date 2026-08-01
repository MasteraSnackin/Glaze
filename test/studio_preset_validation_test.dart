import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_validation.dart';

void main() {
  test('accepts a canonical typed preset', () {
    const preset = StudioPreset(
      id: 'valid',
      blocks: [
        StudioPresetBlock(id: 'rules', content: 'Write clearly.'),
        StudioPresetBlock(
          id: 'memory',
          type: StudioBlockType.context,
          contextSlot: StudioContextSlot.memory,
        ),
        StudioPresetBlock(id: 'history', type: StudioBlockType.history),
        StudioPresetBlock(
          id: 'briefs',
          type: StudioBlockType.priorBriefs,
          section: 'final',
        ),
      ],
    );

    expect(StudioPresetValidator.validate(preset), isEmpty);
  });

  test('rejects ambiguous source and target semantics', () {
    const preset = StudioPreset(
      id: 'invalid',
      blocks: [
        StudioPresetBlock(
          id: 'context',
          type: StudioBlockType.context,
          targetAgentId: 'continuity',
        ),
        StudioPresetBlock(
          id: 'instruction',
          content: 'Rules',
          contextSlot: StudioContextSlot.summary,
          targetAgentId: 'unknown',
        ),
      ],
    );

    final issues = StudioPresetValidator.validate(preset);

    expect(StudioPresetValidator.hasErrors(issues), isTrue);
    expect(
      issues.map((issue) => issue.message),
      containsAll([
        'Context source is required.',
        'Context blocks cannot target an agent.',
        'Instruction blocks cannot select context.',
        'Unknown target agent "unknown".',
      ]),
    );
  });

  test('reports duplicate ids and ignored source-block content', () {
    const preset = StudioPreset(
      id: 'warnings',
      blocks: [
        StudioPresetBlock(id: 'same', content: 'First'),
        StudioPresetBlock(
          id: 'same',
          type: StudioBlockType.history,
          content: 'Ignored',
        ),
      ],
    );

    final issues = StudioPresetValidator.validate(preset);

    expect(
      issues.where(
        (issue) => issue.severity == StudioPresetValidationSeverity.error,
      ),
      hasLength(1),
    );
    expect(
      issues.where(
        (issue) => issue.severity == StudioPresetValidationSeverity.warning,
      ),
      hasLength(1),
    );
  });
}
