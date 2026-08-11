import '../../core/llm/studio_controller_ontology.dart';
import '../../core/models/studio_config.dart';
import '../../core/models/studio_preset_block_groups.dart';

/// Toggles a Studio agent on/off in [preset], cascading dependency rules.
///
/// Locked-on agents (e.g. the final responder) are immutable. Disabling an
/// agent that others depend on (`requiresSpecId`) also disables the dependents,
/// remembering their prior state in [StudioPreset.agentEnabledBeforeDependencyOff]
/// so re-enabling the requirement restores them.
///
/// When a controller has a macro-block (`{{studio_<specId>_brief}}`) inside an
/// exclusive folder, toggling the controller also manages that block:
/// - ON: the macro-block becomes the sole enabled child (radio-button), and
///   the previously enabled sibling id is saved in
///   [StudioPreset.agentBlockRestoreState] for later restore.
/// - OFF: the macro-block is disabled and the saved sibling is re-enabled.
StudioPreset applyStudioAgentToggle(
  StudioPreset preset,
  String specId,
  bool enabled,
) {
  final spec = StudioControllerOntology.specs
      .where((s) => s.id == specId)
      .firstOrNull;
  if (spec == null || spec.lockedOn) return preset;
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

  // Controller radio-folder: manage the macro-block inside an exclusive group.
  var blocks = preset.blocks;
  final restoreState = Map<String, String>.from(preset.agentBlockRestoreState);

  final macroBlock = findControllerMacroBlock(blocks, specId);
  if (macroBlock != null) {
    final group = findGroupForBlock(blocks, macroBlock.id);
    if (group != null && group.exclusive) {
      // Exclusive folder: radio-button behavior.
      if (enabled) {
        // Save the currently enabled sibling (if any) before selecting the
        // macro-block as the sole enabled child.
        final currentEnabled = enabledChildInGroup(group);
        if (currentEnabled != null && currentEnabled != macroBlock.id) {
          restoreState[specId] = currentEnabled;
        }
        blocks = selectExclusiveStudioBlock(blocks, group, macroBlock.id);
      } else {
        // Disable the macro-block and restore the previously enabled sibling.
        blocks = blocks
            .map(
              (block) => block.id == macroBlock.id
                  ? block.copyWith(enabled: false)
                  : block,
            )
            .toList(growable: false);
        final savedId = restoreState.remove(specId);
        if (savedId != null) {
          blocks = blocks
              .map(
                (block) => block.id == savedId
                    ? block.copyWith(enabled: true)
                    : block,
              )
              .toList(growable: false);
        }
      }
    } else {
      // No exclusive folder: simply toggle the macro-block on/off.
      blocks = blocks
          .map(
            (block) => block.id == macroBlock.id
                ? block.copyWith(enabled: enabled)
                : block,
          )
          .toList(growable: false);
    }
  }

  return preset.copyWith(
    agentEnabled: updated,
    agentEnabledBeforeDependencyOff: restored,
    blocks: blocks,
    agentBlockRestoreState: restoreState,
  );
}
