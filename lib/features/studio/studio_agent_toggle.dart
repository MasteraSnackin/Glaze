import '../../core/llm/studio_controller_ontology.dart';
import '../../core/models/studio_config.dart';

/// Toggles a Studio agent on/off in [preset], cascading dependency rules.
///
/// Locked-on agents (e.g. the final responder) are immutable. Disabling an
/// agent that others depend on (`requiresSpecId`) also disables the dependents,
/// remembering their prior state in [StudioPreset.agentEnabledBeforeDependencyOff]
/// so re-enabling the requirement restores them.
StudioPreset applyStudioAgentToggle(
  StudioPreset preset,
  String specId,
  bool enabled,
) {
  final spec = StudioControllerOntology.byId(specId);
  if (spec.lockedOn) return preset;
  final updated = Map<String, bool>.from(preset.agentEnabled)
    ..[specId] = enabled;
  final restored = Map<String, bool>.from(
    preset.agentEnabledBeforeDependencyOff,
  );

  if (!enabled) {
    for (final s in StudioControllerOntology.specs) {
      if (s.requiresSpecId == specId) {
        restored[s.id] = updated[s.id] ?? true;
        updated[s.id] = false;
      }
    }
  } else {
    for (final s in StudioControllerOntology.specs) {
      if (s.requiresSpecId == specId && restored.containsKey(s.id)) {
        updated[s.id] = restored[s.id]!;
        restored.remove(s.id);
      }
    }
  }

  return preset.copyWith(
    agentEnabled: updated,
    agentEnabledBeforeDependencyOff: restored,
  );
}
