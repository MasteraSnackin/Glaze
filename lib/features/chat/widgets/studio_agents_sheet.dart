import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/llm/studio_activation_gate.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';

const _beautyPipelineBlockIds = {
  'beauty_extractor',
  'beauty_task',
  'cleaner_beauty',
};

StudioPreset applyStudioAgentToggle(
  StudioPreset preset,
  String specId,
  bool enabled,
) {
  final spec = StudioControllerOntology.byId(specId);
  if (spec.lockedOn) return preset;
  final updated = Map<String, bool>.from(preset.agentEnabled)
    ..[specId] = enabled;
  if (specId != 'beauty') {
    return preset.copyWith(agentEnabled: updated);
  }
  return preset.copyWith(
    agentEnabled: updated,
    blocks: [
      for (final block in preset.blocks)
        _beautyPipelineBlockIds.contains(block.id)
            ? block.copyWith(enabled: enabled)
            : block,
    ],
  );
}

class StudioAgentsSheet extends ConsumerStatefulWidget {
  final String presetId;

  const StudioAgentsSheet({super.key, required this.presetId});

  static Future<void> show(BuildContext context, {required String presetId}) {
    return GlazeBottomSheet.show<void>(
      context,
      title: 'Agents',
      child: StudioAgentsSheet(presetId: presetId),
    );
  }

  @override
  ConsumerState<StudioAgentsSheet> createState() => _StudioAgentsSheetState();
}

class _StudioAgentsSheetState extends ConsumerState<StudioAgentsSheet> {
  StudioPreset? _preset;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final preset = await ref
        .read(studioPresetRepoProvider)
        .getById(widget.presetId);
    if (!mounted) return;
    setState(() {
      _preset = preset;
      _loading = false;
    });
  }

  Future<void> _toggle(String specId, bool value) async {
    if (_preset == null) return;
    final next = applyStudioAgentToggle(
      _preset!,
      specId,
      value,
    ).copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch);
    await ref.read(studioPresetRepoProvider).upsert(next);
    setState(() => _preset = next);
  }

  void _showAgentCard(StudioControllerSpec spec) {
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
              _cardRow(Icons.badge_outlined, 'Purpose', spec.purpose),
              const SizedBox(height: 16),
              _cardRow(
                Icons.arrow_forward_rounded,
                'Your Lane (owns)',
                spec.laneOwns,
              ),
              const SizedBox(height: 16),
              _cardRow(
                Icons.block_rounded,
                'Not Your Lane (skip)',
                spec.laneSkip,
              ),
              const SizedBox(height: 16),
              _cardRow(
                Icons.terminal_rounded,
                'Output Contract',
                spec.outputContract,
              ),
              const SizedBox(height: 20),
              Text(
                'These instructions are fixed and cannot be edited.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardRow(IconData icon, String label, String body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          body,
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_preset == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('Preset not found')),
      );
    }
    final enabledMap = _preset!.agentEnabled;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: StudioControllerOntology.specs.length,
        itemBuilder: (context, index) {
          final spec = StudioControllerOntology.specs[index];
          final allowedByTopology = StudioActivationGate.isControllerAllowed(
            spec.id,
            _preset!.executionMode,
          );
          final isOn = spec.id == 'beauty'
              ? _preset!.blocks
                        .where((block) => block.id == 'beauty_extractor')
                        .firstOrNull
                        ?.enabled ??
                    false
              : enabledMap[spec.id] ?? true;
          return SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 0,
            ),
            secondary: Icon(
              spec.lockedOn ? Icons.lock_outline : spec.isFinal ? Icons.star_outline : Icons.smart_toy_outlined,
              color: spec.isFinal
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: InkWell(
              onTap: () => _showAgentCard(spec),
              child: Text(spec.name),
            ),
            subtitle: InkWell(
              onTap: () => _showAgentCard(spec),
              child: Text(
                spec.purpose,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            value: isOn,
            onChanged: (spec.lockedOn || !allowedByTopology)
                ? null
                : (v) => _toggle(spec.id, v),
          );
        },
      ),
    );
  }
}
