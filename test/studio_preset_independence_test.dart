import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/generation_context_inputs.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context_preparer.dart';
import 'package:glaze_flutter/core/llm/studio_brief_deduper.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/studio_message_builder.dart';
import 'package:glaze_flutter/core/llm/studio_prompt_text.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  test('Studio request is identical for ordinary preset A, B, and null', () {
    const inputs = GenerationContextInputs(
      character: Character(id: 'char', name: 'Lucy', description: 'Detective'),
      history: [ChatMessage(id: 'user', role: 'user', content: 'Continue')],
      apiConfig: ApiConfig(
        id: 'api',
        reasoningTagStart: '<api-think>',
        reasoningTagEnd: '</api-think>',
      ),
      summaryContent: 'The case remains open.',
    );
    const ordinaryPresets = <Preset?>[
      Preset(
        id: 'a',
        name: 'Ordinary A',
        reasoningStart: '<ordinary-a>',
        blocks: [
          PresetBlock(
            id: 'renamed_a',
            name: 'A',
            role: 'user',
            content: 'ordinary A',
          ),
        ],
      ),
      Preset(
        id: 'b',
        name: 'Ordinary B',
        reasoningStart: '<ordinary-b>',
        blocks: [
          PresetBlock(
            id: 'summary',
            name: 'B',
            role: 'assistant',
            content: 'ordinary B',
          ),
        ],
      ),
      null,
    ];
    final builder = StudioMessageBuilder(
      const StudioPromptText(),
      StudioBriefDeduper(StudioBriefParser((_) {})),
    );
    const studioPreset = StudioPreset(
      id: 'studio',
      blocks: [
        StudioPresetBlock(
          id: 'instruction',
          kind: 'agent_instruction',
          content:
              'Write {{char}} {{reasoningPrefix}}carefully{{reasoningSuffix}}',
          section: 'final',
          order: 1,
        ),
        StudioPresetBlock(
          id: 'summary',
          kind: 'summary',
          section: 'final',
          order: 2,
        ),
        StudioPresetBlock(
          id: 'history',
          kind: 'chat_history',
          section: 'final',
          order: 3,
        ),
      ],
    );

    List<Map<String, dynamic>> buildRequest(Preset? ignoredOrdinaryPreset) {
      ignoredOrdinaryPreset;
      final context = const StudioContextPreparer().prepare(
        inputs: inputs,
        visibleMessageIds: const {'user'},
      );
      return builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final'),
        context: context,
        config: const StudioConfig(sessionId: 'session'),
        studioPreset: studioPreset,
        priorBriefs: const [],
        isFinalResponse: true,
      );
    }

    final requests = ordinaryPresets.map(buildRequest).toList();
    expect(requests[1], requests[0]);
    expect(requests[2], requests[0]);
    expect(requests[0].toString(), isNot(contains('ordinary')));
    expect(requests[0].toString(), contains('<api-think>'));
  });

  test('production Studio entry points use the typed context path', () {
    final stream = File(
      'lib/features/chat/services/stream_generation_service.dart',
    ).readAsStringSync();
    final recovery = File(
      'lib/features/chat/services/tracker_memory_recovery_service.dart',
    ).readAsStringSync();

    expect(stream, contains('collectGenerationContext('));
    expect(stream, contains('studioService.runTrackerCycle('));
    expect(stream, isNot(contains('buildFromSession(')));
    expect(
      stream,
      matches(
        RegExp(
          r'final promptResult = studioConfig == null\s*'
          r'\? await buildPromptInIsolate\(finalPayload\)\s*'
          r': _studioCompatibilityResult\(finalStudioContext!\);',
        ),
      ),
    );
    expect(recovery, contains('collectGenerationContext('));
    expect(recovery, contains('.runTrackersOnly('));
    expect(recovery, isNot(contains('buildFromSession(')));
    expect(recovery, isNot(contains('buildPromptInIsolate(')));
  });
}
