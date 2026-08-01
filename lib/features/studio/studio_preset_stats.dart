import '../../core/llm/studio_controller_ontology.dart';
import '../../core/models/studio_config.dart';

/// Shared, presentation-only estimates for an agentic (Studio) preset. Used by
/// both the preset list card and the Studio preset editor so their stat plaques
/// never drift apart.

/// Rough token estimate for all of the preset's block content (~4 chars/token).
int studioPresetTokenEstimate(StudioPreset preset) {
  var total = 0;
  for (final block in preset.blocks) {
    total += block.content.length ~/ 4;
  }
  return total;
}

/// Estimated LLM requests per turn (upper bound): the enabled pre-gen
/// controllers batch into one request, the final responder is one, Post Clean
/// is two passes (audit + rewrite) and the Ledger/Трекер is one — each counted
/// only when enabled.
int studioPresetRequestCount(StudioPreset preset) {
  var count = 1; // final responder
  var pregenEnabled = false;
  for (final spec in StudioControllerOntology.specs) {
    if (spec.isFinal) continue;
    if (!studioAgentEnabled(preset, spec)) continue;
    if (spec.id == 'post_clean') {
      count += 2;
    } else if (spec.id == 'ledger') {
      count += 1;
    } else {
      pregenEnabled = true; // pre-gen controllers share one batch request
    }
  }
  if (pregenEnabled) count += 1;
  return count;
}

/// Whether [spec] is on for [preset]. Agents default to on when the preset
/// carries no explicit toggle, and locked-on agents are always on.
bool studioAgentEnabled(StudioPreset preset, StudioControllerSpec spec) {
  if (spec.lockedOn) return true;
  return preset.agentEnabled[spec.id] ?? true;
}

/// Number of enabled agents (controllers + final + post-processing).
int studioPresetEnabledAgentCount(StudioPreset preset) {
  var count = 0;
  for (final spec in StudioControllerOntology.specs) {
    if (studioAgentEnabled(preset, spec)) count++;
  }
  return count;
}
