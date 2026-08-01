import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/state/pipeline_settings_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../presets/widgets/preset_dashboard_card.dart';
import '../studio_preset_stats.dart';

/// Collapsible "Agents" card, sitting between the agentic preset's dashboard
/// and its blocks: which agents run is what the blocks are addressed to, so it
/// is read first. Lists the fixed controller slots with an on/off switch each;
/// tapping a name opens its (read-only) spec card.
class StudioAgentsPanel extends ConsumerWidget {
  final StudioPreset preset;

  /// Expansion is owned by the screen so the dashboard's agent button can
  /// toggle this panel too.
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final void Function(String specId, bool enabled) onToggle;

  const StudioAgentsPanel({
    super.key,
    required this.preset,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = studioPresetEnabledAgentCount(preset);
    final total = StudioControllerOntology.specs.length;

    return PresetCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggleExpanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Icon(
                    Icons.smart_toy_outlined,
                    size: 16,
                    color: context.cs.onSurface.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'studio_agents'.tr(),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$enabled / $total',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more,
                      color: context.cs.onSurfaceVariant,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0x33808080), width: 1),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final spec in StudioControllerOntology.specs) ...[
                    _agentTile(context, spec),
                    // Post Clean owns the post-processing context control:
                    // hidden while the agent is off, since the value only
                    // matters once something runs in that phase.
                    if (spec.id == 'post_clean' &&
                        studioAgentEnabled(preset, spec))
                      _postContextSetting(context, ref),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// How many trailing chat messages a post-processing agent is handed (the
  /// last turn plus the response it has to edit).
  ///
  /// The value is global — `StudioAgentSettings.studioPostControllerContextSize`
  /// applies to every agent whose phase is `post_processing`, which today is
  /// Post Clean *and* Трекер. It is shown here because Post Clean is the one
  /// the setting was written for.
  Widget _postContextSetting(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
      pipelineSettingsProvider.select(
        (p) => p.studioAgent.studioPostControllerContextSize,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 0, 4, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'studio_post_context_label'.tr(),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'studio_post_context_desc'.tr(),
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final value in const [1, 2, 3, 5])
                ChoiceChip(
                  label: Text('$value'),
                  selected: current == value,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (_) => unawaited(_savePostContext(ref, value)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _savePostContext(WidgetRef ref, int value) {
    final pipeline = ref.read(pipelineSettingsProvider);
    return ref
        .read(pipelineSettingsProvider.notifier)
        .save(
          pipeline.copyWith(
            studioAgent: pipeline.studioAgent.copyWith(
              studioPostControllerContextSize: value,
            ),
          ),
        );
  }

  Widget _agentTile(BuildContext context, StudioControllerSpec spec) {
    final isOn = studioAgentEnabled(preset, spec);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      secondary: Icon(
        spec.lockedOn
            ? Icons.lock_outline
            : spec.isFinal
            ? Icons.star_outline
            : Icons.smart_toy_outlined,
        color: spec.isFinal ? context.cs.primary : null,
      ),
      title: GestureDetector(
        onTap: () => showStudioAgentCard(context, spec),
        child: Text(spec.name, style: const TextStyle(fontSize: 14)),
      ),
      subtitle: GestureDetector(
        onTap: () => showStudioAgentCard(context, spec),
        child: Text(
          spec.purpose,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
      ),
      value: isOn,
      onChanged: spec.lockedOn ? null : (v) => onToggle(spec.id, v),
    );
  }
}

/// Read-only card describing a controller slot. The instructions are fixed by
/// [StudioControllerOntology] (§4 — agent identity is pinned to its spec), so
/// this sheet only explains what the agent does.
void showStudioAgentCard(BuildContext context, StudioControllerSpec spec) {
  GlazeBottomSheet.show<void>(
    context,
    title: spec.name,
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.55,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardRow(
              context,
              Icons.badge_outlined,
              'studio_agent_purpose'.tr(),
              spec.purpose,
            ),
            const SizedBox(height: 16),
            _cardRow(
              context,
              Icons.arrow_forward_rounded,
              'studio_agent_lane_owns'.tr(),
              spec.laneOwns,
            ),
            const SizedBox(height: 16),
            _cardRow(
              context,
              Icons.block_rounded,
              'studio_agent_lane_skip'.tr(),
              spec.laneSkip,
            ),
            const SizedBox(height: 16),
            _cardRow(
              context,
              Icons.terminal_rounded,
              'studio_agent_output_contract'.tr(),
              spec.outputContract,
            ),
            const SizedBox(height: 20),
            Text(
              'studio_agent_fixed_hint'.tr(),
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _cardRow(
  BuildContext context,
  IconData icon,
  String label,
  String body,
) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, size: 16, color: context.cs.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.cs.primary,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(body, style: const TextStyle(fontSize: 13, height: 1.4)),
    ],
  );
}
