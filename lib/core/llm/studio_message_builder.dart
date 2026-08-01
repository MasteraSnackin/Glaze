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
    final section = _blockExpander.sectionForRun(agent, isFinalResponse);
    final blocks =
        studioPreset.blocks
            .where((block) => block.enabled && block.section == section)
            .where((block) => !_blockExpander.isRuntimeComputedBlock(block))
            .where(
              (block) => _blockExpander.blockAppliesToAgent(
                block,
                agent,
                isFinalResponse,
              ),
            )
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    final hasExplicitBriefMacros =
        isFinalResponse &&
        blocks.any(
          (block) => _briefMacroRenderer.hasStudioBriefMacro(block.content),
        );
    final messages = <Map<String, dynamic>>[];

    for (final block in blocks) {
      if (block.type == StudioBlockType.instruction) {
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
          control
            ..writeln()
            ..writeln(_promptText.intermediateRuntimeEnvelope(agent));
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
        continue;
      }
      if (block.type == StudioBlockType.priorBriefs) {
        if (!isFinalResponse || hasExplicitBriefMacros) continue;
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
        continue;
      }
      if (block.type == StudioBlockType.history) {
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
        messages.addAll(
          isFinalResponse &&
                  (reasoningHistoryCount == -1 || reasoningHistoryCount > 0)
              ? _historyWithReasoning(history, reasoningHistoryCount)
              : history.map((message) => message.toApiMap()),
        );
        continue;
      }
      if (block.type == StudioBlockType.context) {
        final slot = block.contextSlot;
        if (slot == null) continue;
        messages.addAll(
          context.messagesFor(slot).map((message) => message.toApiMap()),
        );
        continue;
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
    final blocks =
        studioPreset.blocks
            .where((block) => block.enabled && block.section == 'pregen')
            .where(
              (block) =>
                  block.type == StudioBlockType.instruction &&
                  (block.targetAgentId == null ||
                      block.targetAgentId ==
                          StudioControllerOntology.targetIdForAgent(agent)),
            )
            .where((block) => !_blockExpander.isRuntimeComputedBlock(block))
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
    buffer.writeln(_promptText.intermediateRuntimeEnvelope(agent));
    return buffer.toString().trim();
  }

  /// Role text for the `<role>` element: the shared role/instruction text
  /// from the preset's non-`agent_instruction` blocks.
  String batchRoleText(
    StudioConfig config,
    StudioPreset studioPreset,
    StudioContext context,
  ) {
    final blocks =
        studioPreset.blocks
            .where((block) => block.enabled && block.section == 'pregen')
            .where((block) => block.type == StudioBlockType.instruction)
            .where((block) => block.targetAgentId == null)
            .where((block) => !_blockExpander.isRuntimeComputedBlock(block))
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
