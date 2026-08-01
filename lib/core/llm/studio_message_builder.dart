import '../models/studio_config.dart';
import 'history_assembler.dart';
import 'studio_brief_deduper.dart';
import 'studio_controller_ontology.dart';
import 'studio_prompt_text.dart';
import 'studio_stage_brief.dart';
import 'studio/studio_brief_macro_renderer.dart';
import 'studio/studio_history_limiter.dart';
import 'studio/studio_runtime_block_expander.dart';
import 'studio/studio_context.dart';

/// Builds the per-agent, batch, and final-generator message lists for the
/// Studio chat-time pipeline. Extracted from `MemoryStudioService` (plan §2.7).
///
/// Thin orchestrator — delegates block expansion to [StudioRuntimeBlockExpander],
/// history trimming to [StudioHistoryLimiter], and brief-macro rendering to
/// [StudioBriefMacroRenderer].
class StudioMessageBuilder {
  final StudioPromptText _promptText;
  final StudioBriefDeduper _briefDeduper;
  late final StudioBriefMacroRenderer _briefMacroRenderer =
      StudioBriefMacroRenderer(_briefDeduper);
  late final StudioRuntimeBlockExpander _blockExpander =
      StudioRuntimeBlockExpander(_briefMacroRenderer);

  StudioMessageBuilder(this._promptText, this._briefDeduper);

  List<Map<String, dynamic>> buildAgentMessages({
    required StudioAgent agent,
    required StudioContext context,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required List<StudioStageBrief> priorBriefs,
    required bool isFinalResponse,
    String mainResponse = '',
    int finalContextOverride = 0,
    int reasoningHistoryCount = 0,
  }) {
    final point = _blockExpander.injectionPointForRun(agent, isFinalResponse);
    final spec = StudioControllerOntology.specForAgent(agent);
    final specId = spec?.id;
    final isPostProc = agent.phase == 'post_processing';
    final blocks =
        studioPreset.blocks
            .where((b) => b.enabled)
            .where((b) => !_blockExpander.isRuntimeComputedBlock(b))
            .where((b) {
              if (b.injectionPoint == 'specificAgent') {
                return !isFinalResponse &&
                    !isPostProc &&
                    b.targetAgentId == specId;
              }
              return b.injectionPoint == point;
            })
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    final hasExplicitBriefMacros =
        isFinalResponse &&
        blocks.any(
          (block) => _briefMacroRenderer.hasStudioBriefMacro(block.content),
        );
    final messages = <Map<String, dynamic>>[];

    for (final block in blocks) {
      // Empty mode marks a context slot — resolved by its canonical id.
      if (block.mode.isEmpty) {
        final blockId = block.id;
        if (blockId == 'static_context') {
          messages.addAll(context.staticContext.map((m) => m.toApiMap()));
        } else if (blockId == 'chat_history') {
          final history = isFinalResponse
              ? StudioHistoryLimiter.limitFinalHistory(
                  context.history,
                  studioPreset,
                  pipelineOverride: finalContextOverride,
                  reasoningHistoryCount: reasoningHistoryCount,
                )
              : StudioHistoryLimiter.limitTrackerHistory(
                  context.history,
                  agent.contextSize,
                );
          if (isFinalResponse &&
              (reasoningHistoryCount == -1 || reasoningHistoryCount > 0)) {
            messages.addAll(
              _historyWithReasoning(history, reasoningHistoryCount),
            );
          } else {
            messages.addAll(history.map((m) => m.toApiMap()));
          }
        } else if (blockId == 'dynamic_context') {
          messages.addAll(context.dynamicContext.map((m) => m.toApiMap()));
        } else {
          final slot = _slotForBlockId(blockId);
          if (slot != null) {
            messages.addAll(
              context.messagesFor(slot).map((m) => m.toApiMap()),
            );
          } else {
            final content = _blockExpander
                .expandStudioBlockContent(
                  block.content,
                  context: context,
                  priorBriefs: priorBriefs,
                  preset: studioPreset,
                )
                .trim();
            if (content.isNotEmpty) {
              messages.add({
                'role': _blockExpander.normalizeInstructionRole(block.role),
                'content': content,
              });
            }
          }
        }
        continue;
      }
      switch (block.mode) {
        case 'direct':
          final control = StringBuffer()
            ..writeln(
              _blockExpander
                  .expandStudioBlockContent(
                    block.content,
                    context: context,
                    priorBriefs: priorBriefs,
                    preset: studioPreset,
                  )
                  .trim(),
            );
          if (!isFinalResponse) {
            if (spec != null) {
              control
                ..writeln()
                ..writeln(_promptText.intermediateRuntimeEnvelope(spec, agent));
            }
          }
          if (isFinalResponse &&
              (hasExplicitBriefMacros || priorBriefs.isNotEmpty)) {
            control
              ..writeln()
              ..writeln(_promptText.finalBriefUsageNote());
          }
          if (isFinalResponse) {
            final styleContract = _promptText.finalHardStyleContract(
              studioPreset,
            );
            if (styleContract.isNotEmpty) {
              control
                ..writeln()
                ..writeln(styleContract);
            }
          }
          _addInstructionMessage(messages, block.role, control.toString());
          break;
        case 'pregenBrief':
          if (!isFinalResponse || hasExplicitBriefMacros) break;
          final sanitized = priorBriefs
              .where((brief) => brief.brief.trim().isNotEmpty)
              .map(
                (brief) =>
                    _briefDeduper.sanitizePriorBriefForFinal(brief, studioPreset),
              )
              .toList();
          final deduped = _briefDeduper.dedupePriorBriefs(sanitized);
          messages.addAll(
            deduped
                .where((brief) => brief.brief.trim().isNotEmpty)
                .map(
                  (brief) => {
                    'role': _blockExpander.normalizeInstructionRole(block.role),
                    'content':
                        'Studio agent brief: ${brief.agentName}\n${brief.brief}',
                  },
                ),
          );
          break;
        case 'agentResponse':
          break;
      }
    }

    if (mainResponse.trim().isNotEmpty) {
      messages.add({
        'role': 'user',
        'content':
            '<assistant_response>\n${mainResponse.trim()}\n</assistant_response>\n\n'
            'The text above inside <assistant_response> is the generator\'s '
            'current reply. Edit, rewrite, or fix it according to your '
            'instructions. Output ONLY the final rewritten reply (no '
            'explanations, no <assistant_response> wrapper, no markdown '
            'fences). If no edit is needed, output the text verbatim.',
      });
    }
    return messages;
  }

  void _addInstructionMessage(
    List<Map<String, dynamic>> messages,
    String role,
    String content,
  ) {
    final resolved = content.trim();
    if (resolved.isEmpty) return;
    messages.add({
      'role': _blockExpander.normalizeInstructionRole(role),
      'content': resolved,
    });
  }

  StudioContextSlot? _slotForBlockId(String blockId) => switch (blockId) {
    'char_card' => StudioContextSlot.characterCard,
    'char_personality' => StudioContextSlot.characterPersonality,
    'user_persona' => StudioContextSlot.userPersona,
    'scenario' => StudioContextSlot.scenario,
    'example_dialogue' => StudioContextSlot.exampleDialogue,
    'authors_note' => StudioContextSlot.authorsNote,
    'memory' => StudioContextSlot.memory,
    'summary' => StudioContextSlot.summary,
    'lore_before' => StudioContextSlot.loreBefore,
    'lore_after' => StudioContextSlot.loreAfter,
    'lore_macro' => StudioContextSlot.loreMacro,
    'recalled_messages' => StudioContextSlot.recalledMessages,
    'character_knowledge' => StudioContextSlot.characterKnowledge,
    'studio_session_state' => StudioContextSlot.studioSessionState,
    'runtime_dynamic' => StudioContextSlot.runtimeDynamic,
    _ => null,
  };

  List<Map<String, dynamic>> _historyWithReasoning(
    List<PromptMessage> history,
    int reasoningHistoryCount,
  ) {
    final messages = history
        .map<Map<String, dynamic>>((message) => message.toApiMap())
        .toList();
    final includeAll = reasoningHistoryCount == -1;
    var remaining = reasoningHistoryCount;
    for (
      var i = history.length - 1;
      i >= 0 && (includeAll || remaining > 0);
      i--
    ) {
      final message = history[i];
      if (message.role != 'assistant') continue;
      final reasoning = message.reasoningContent?.trim();
      if (reasoning?.isNotEmpty == true) {
        messages[i]['reasoning_content'] = reasoning;
        if (!includeAll) remaining--;
      }
    }
    return messages;
  }

  /// Shared messages for a batch: `static_context` + `dynamic_context` +
  /// `chat_history` (trimmed to [batchContextSize]).
  List<Map<String, dynamic>> buildSharedBatchMessages({
    required StudioContext context,
    required int batchContextSize,
  }) {
    final messages = <Map<String, dynamic>>[
      ...context.staticContext.map((message) => message.toApiMap()),
      ...context.dynamicContext.map((message) => message.toApiMap()),
    ];
    final history = StudioHistoryLimiter.limitTrackerHistory(
      context.history,
      batchContextSize,
    );
    messages.addAll(history.map((message) => message.toApiMap()));
    return messages;
  }

  /// Per-agent task text: the agent's `promptShard` + the preset's
  /// `agent_instruction` block content + the runtime envelope.
  String buildPerAgentTaskText({
    required StudioAgent agent,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required StudioContext context,
  }) {
    final specId = StudioControllerOntology.specForAgent(agent)?.id;
    final blocks =
        studioPreset.blocks
            .where((b) => b.enabled)
            .where((b) {
              if (b.injectionPoint == 'specificAgent') {
                return b.targetAgentId == specId;
              }
              return b.injectionPoint == 'pregen' && b.mode == 'direct';
            })
            .where((b) => !_blockExpander.isRuntimeComputedBlock(b))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    final buffer = StringBuffer();
    for (final block in blocks) {
      final content = _blockExpander
          .expandStudioBlockContent(
            block.content,
            context: context,
            preset: studioPreset,
          )
          .trim();
      if (content.isEmpty) continue;
      buffer
        ..writeln(content)
        ..writeln();
    }
    final spec = StudioControllerOntology.specForAgent(agent);
    if (spec != null) {
      buffer.writeln(_promptText.intermediateRuntimeEnvelope(spec, agent));
    }
    return buffer.toString().trim();
  }

  /// Role text for the `<role>` element: the shared pre-gen instruction text
  /// broadcast to every controller (specific-agent and context blocks excluded).
  String batchRoleText(
    StudioConfig config,
    StudioPreset studioPreset,
    StudioContext context,
  ) {
    final blocks =
        studioPreset.blocks
            .where((b) => b.enabled && b.injectionPoint == 'pregen')
            .where((b) => b.mode == 'direct')
            .where((b) => !_blockExpander.isRuntimeComputedBlock(b))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    final buffer = StringBuffer();
    for (final block in blocks) {
      final content = _blockExpander
          .expandStudioBlockContent(
            block.content,
            context: context,
            preset: studioPreset,
          )
          .trim();
      if (content.isNotEmpty) buffer.writeln(content);
    }
    return buffer.toString().trim();
  }
}
