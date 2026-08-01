import '../macro_engine.dart';
import '../studio_stage_brief.dart';
import '../studio_controller_ontology.dart';
import '../../models/studio_config.dart';
import 'studio_brief_macro_renderer.dart';
import 'studio_context.dart';

/// Chat-time Studio block expansion + block filtering + role normalization.
/// Extracted from `StudioMessageBuilder` (plan Phase 5b).
///
/// This is distinct from build-time block expansion, which handles
/// `{{setvar}}`/`{{getvar}}`/`{{trim}}` at preset-routing time. This class
/// expands `{{char}}`, `{{user}}`, `{{studio_*_brief}}` and all other
/// chat-time macros inside block content at generation time.
///
/// Deps: [StudioBriefMacroRenderer] for `{{studio_*_brief}}` macros.
class StudioRuntimeBlockExpander {
  final StudioBriefMacroRenderer _briefMacroRenderer;

  StudioRuntimeBlockExpander(this._briefMacroRenderer);

  String expandStudioBlockContent(
    String content, {
    required StudioContext context,
    List<StudioStageBrief> priorBriefs = const [],
    StudioConfig? config,
  }) {
    if (!content.contains('{')) return content;
    final studioExpanded = _briefMacroRenderer.replaceStudioBriefMacros(
      content,
      priorBriefs: priorBriefs,
      config: config,
    );
    return replaceMacros(studioExpanded, context.macroContext).text;
  }

  /// Returns the pipeline section for this run: `final` for the generator,
  /// `cleaner` for post-processing trackers, `pregen` for pre-gen trackers.
  String sectionForRun(StudioAgent agent, bool isFinalResponse) {
    if (isFinalResponse) return 'final';
    if (agent.phase == 'post_processing') return 'cleaner';
    return 'pregen';
  }

  /// True if [block] has a runtime-computed ID (its content is injected by
  /// the pipeline, not by the preset).
  bool isRuntimeComputedBlock(StudioPresetBlock block) {
    return const {
      'runtime_envelope',
      'brief_usage_note',
      'hard_style_contract',
      'beauty_shard_contract',
    }.contains(block.id);
  }

  /// Targeted instructions apply only to their exact controller id.
  bool blockAppliesToAgent(
    StudioPresetBlock block,
    StudioAgent agent,
    bool isFinalResponse,
  ) {
    if (block.type != StudioBlockType.instruction ||
        block.targetAgentId == null) {
      return true;
    }
    return block.targetAgentId ==
        StudioControllerOntology.targetIdForAgent(agent);
  }

  bool trackerInstructionAppliesToAgent(
    StudioPresetBlock block,
    StudioAgent agent,
  ) =>
      block.type == StudioBlockType.instruction &&
      block.targetAgentId == StudioControllerOntology.targetIdForAgent(agent);

  /// Normalize the role of a preset/shard INSTRUCTION block (not a chat
  /// history message). Instruction blocks are always forced to `system` so
  /// the model treats them as authoritative directives, not user dialogue.
  String normalizeInstructionRole(String role) {
    return 'system';
  }
}
