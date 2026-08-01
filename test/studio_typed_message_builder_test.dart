import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/studio_brief_deduper.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/studio_message_builder.dart';
import 'package:glaze_flutter/core/llm/studio_prompt_text.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  final builder = StudioMessageBuilder(
    const StudioPromptText(),
    StudioBriefDeduper(StudioBriefParser((_) {})),
  );
  const context = StudioContext(
    slots: {
      StudioContextSlot.characterCard: [
        PromptMessage(role: 'system', content: 'Typed character card'),
      ],
      StudioContextSlot.summary: [
        PromptMessage(role: 'system', content: 'Typed summary'),
      ],
      StudioContextSlot.memory: [
        PromptMessage(role: 'system', content: 'Typed memory'),
      ],
    },
    history: [
      PromptMessage(role: 'user', content: 'First', isHistory: true),
      PromptMessage(role: 'assistant', content: 'Second', isHistory: true),
    ],
    sessionVars: {},
    globalVars: {},
    macroContext: MacroContext(
      charName: 'Lucy',
      charId: 'char',
      sessionId: 'session',
      reasoningStart: '<api-think>',
      reasoningEnd: '</api-think>',
    ),
    diagnostics: StudioContextDiagnostics(),
  );
  const config = StudioConfig(sessionId: 'session');

  test('routes known block kinds through typed slots in Studio order', () {
    final messages = builder.buildAgentMessages(
      agent: const StudioAgent(id: 'final'),
      context: context,
      config: config,
      studioPreset: const StudioPreset(
        id: 'studio',
        blocks: [
          StudioPresetBlock(
            id: 'memory',
            type: StudioBlockType.context,
            contextSlot: StudioContextSlot.memory,
            content: 'ignored ordinary-shaped fallback',
            section: 'final',
            order: 3,
          ),
          StudioPresetBlock(
            id: 'character',
            type: StudioBlockType.context,
            contextSlot: StudioContextSlot.characterCard,
            section: 'final',
            order: 1,
          ),
          StudioPresetBlock(
            id: 'summary',
            type: StudioBlockType.context,
            contextSlot: StudioContextSlot.summary,
            section: 'final',
            order: 2,
          ),
          StudioPresetBlock(
            id: 'history',
            type: StudioBlockType.history,
            section: 'final',
            order: 4,
          ),
        ],
      ),
      priorBriefs: const [],
      isFinalResponse: true,
    );

    expect(messages.map((message) => message['content']), [
      'Typed character card',
      'Typed summary',
      'Typed memory',
      'First',
      'Second',
    ]);
    expect(
      messages.map((message) => message['content']).join('\n'),
      isNot(contains('ordinary-shaped fallback')),
    );
  });

  test('instructions expand Studio macros', () {
    final messages = builder.buildAgentMessages(
      agent: const StudioAgent(id: 'final'),
      context: context,
      config: config,
      studioPreset: const StudioPreset(
        id: 'studio',
        blocks: [
          StudioPresetBlock(
            id: 'custom',
            role: 'user',
            content:
                'Write for {{char}} using {{reasoningPrefix}}thought{{reasoningSuffix}}',
            section: 'final',
          ),
        ],
      ),
      priorBriefs: const [],
      isFinalResponse: true,
    );

    expect(messages, [
      {
        'role': 'system',
        'content': 'Write for Lucy using <api-think>thought</api-think>',
      },
    ]);
  });

  test('static and dynamic groups are explicit typed projections', () {
    final messages = builder.buildAgentMessages(
      agent: const StudioAgent(id: 'tracker', contextSize: 1),
      context: context,
      config: config,
      studioPreset: const StudioPreset(
        id: 'studio',
        blocks: [
          StudioPresetBlock(
            id: 'static',
            type: StudioBlockType.context,
            contextSlot: StudioContextSlot.staticContext,
            section: 'pregen',
            order: 1,
          ),
          StudioPresetBlock(
            id: 'dynamic',
            type: StudioBlockType.context,
            contextSlot: StudioContextSlot.dynamicContext,
            section: 'pregen',
            order: 2,
          ),
          StudioPresetBlock(
            id: 'history',
            type: StudioBlockType.history,
            section: 'pregen',
            order: 3,
          ),
        ],
      ),
      priorBriefs: const [],
      isFinalResponse: false,
    );

    expect(messages.map((message) => message['content']), [
      'Typed character card',
      'Typed summary',
      'Typed memory',
      'Second',
    ]);
  });
}
