import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/studio_controller_ontology.dart';
import '../../core/models/studio_config.dart';
import '../../core/models/studio_preset_block_groups.dart';
import '../../core/state/db_provider.dart';
import '../../core/utils/id_generator.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/generic_editor.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../studio/studio_agent_toggle.dart';
import '../studio/studio_preset_stats.dart';
import '../studio/widgets/studio_preset_group_tile.dart';

/// Full editor for a single agentic (Studio) preset. Rendered inline inside the
/// [PresetListScreen] SheetView (like the plain preset editor). Layout, top to
/// bottom: a stats plaque (agent count + calls/turn), the agent enable/disable
/// list with descriptions, then the preset's prompt blocks. Editing a block
/// opens the shared [GenericEditor] full-body inline, mirroring the plain
/// preset editor.
class StudioPresetEditorBody extends ConsumerStatefulWidget {
  final String presetId;
  final VoidCallback onClose;

  const StudioPresetEditorBody({
    super.key,
    required this.presetId,
    required this.onClose,
  });

  @override
  ConsumerState<StudioPresetEditorBody> createState() =>
      StudioPresetEditorBodyState();
}

class StudioPresetEditorBodyState
    extends ConsumerState<StudioPresetEditorBody> {
  StudioPreset? _preset;
  bool _loading = true;
  String _point = 'pregen';
  String? _editingBlockId;
  Timer? _saveTimer;

  /// Injection points and their labels, in pipeline order (§5).
  static const _points = <(String, String)>[
    ('pregen', 'Pre-generation'),
    ('final', 'Final'),
    ('cleaner', 'Post-processing'),
    ('ledger', 'Трекер'),
    ('specificAgent', 'Specific agent'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void deactivate() {
    _flushSave();
    super.deactivate();
  }

  @override
  void dispose() {
    _flushSave();
    super.dispose();
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

  /// Closes the inline block editor if open; returns true when it handled back.
  bool handleBack() {
    if (_editingBlockId != null) {
      _flushSave();
      setState(() => _editingBlockId = null);
      return true;
    }
    return false;
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Persists [next] immediately (used for discrete edits: toggles, add/delete).
  Future<void> _persistNow(StudioPreset next) async {
    final stamped = next.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _preset = stamped);
    await ref.read(studioPresetRepoProvider).upsert(stamped);
    ref.invalidate(studioPresetListProvider);
  }

  /// Updates in memory now and debounces the write (used while typing content).
  void _persistDebounced(StudioPreset next) {
    setState(
      () => _preset = next.copyWith(
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _flushSave);
  }

  void _flushSave() {
    if (_saveTimer?.isActive != true) return;
    _saveTimer!.cancel();
    final preset = _preset;
    if (preset == null) return;
    // ref is still valid in deactivate(); dispose() flush is a best-effort.
    unawaited(ref.read(studioPresetRepoProvider).upsert(preset));
    ref.invalidate(studioPresetListProvider);
  }

  // ── Agent toggles ──────────────────────────────────────────────────────────

  Future<void> _toggleAgent(String specId, bool value) async {
    final preset = _preset;
    if (preset == null) return;
    await _persistNow(applyStudioAgentToggle(preset, specId, value));
  }

  // ── Block ops ──────────────────────────────────────────────────────────────

  List<StudioPresetBlock> get _pointBlocks =>
      (_preset?.blocks ?? const <StudioPresetBlock>[])
          .where((b) => b.injectionPoint == _point)
          .toList()
        ..sort((a, b) => a.order.compareTo(b.order));

  Future<void> _toggleBlock(StudioPresetBlock block, bool enabled) async {
    final preset = _preset;
    if (preset == null) return;
    await _persistNow(
      preset.copyWith(
        blocks: updateStudioPresetBlockRespectingGroups(
          preset.blocks,
          block.copyWith(enabled: enabled),
        ),
      ),
    );
  }

  Future<void> _selectExclusive(
    StudioPresetBlockGroup group,
    String selectedId,
  ) async {
    final preset = _preset;
    if (preset == null) return;
    await _persistNow(
      preset.copyWith(
        blocks: selectExclusiveStudioBlock(preset.blocks, group, selectedId),
      ),
    );
  }

  void _onBlockChanged(StudioPresetBlock updated) {
    final preset = _preset;
    if (preset == null) return;
    _persistDebounced(
      preset.copyWith(
        blocks: updateStudioPresetBlockRespectingGroups(preset.blocks, updated),
      ),
    );
  }

  Future<void> _addBlock() async {
    final preset = _preset;
    if (preset == null) return;
    final maxOrder = preset.blocks.fold<int>(
      -1,
      (m, b) => b.order > m ? b.order : m,
    );
    // New blocks carry no legacy `kind`/`section`, so the §5 migrator never
    // rewrites their explicit mode/injectionPoint.
    final draft = StudioPresetBlock(
      id: generateId(),
      title: 'New Block',
      kind: '',
      section: '',
      role: 'system',
      mode: 'direct',
      injectionPoint: _point,
      order: maxOrder + 1,
    );
    await _persistNow(preset.copyWith(blocks: [...preset.blocks, draft]));
    if (mounted) setState(() => _editingBlockId = draft.id);
  }

  Future<void> _deleteBlock(StudioPresetBlock block) async {
    final preset = _preset;
    if (preset == null) return;
    final ok = await GlazeBottomSheet.show<bool>(
      context,
      title: 'Delete Block',
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description:
            'Delete "${block.title.isNotEmpty ? block.title : block.id}"?',
      ),
      items: [
        BottomSheetItem(
          label: 'Delete',
          centered: true,
          isDestructive: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'Cancel',
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (ok != true) return;
    await _persistNow(
      preset.copyWith(
        blocks: preset.blocks
            .where((b) => b.id != block.id)
            .toList(growable: false),
      ),
    );
    if (mounted && _editingBlockId == block.id) {
      setState(() => _editingBlockId = null);
    }
  }

  // ── Agent detail card ────────────────────────────────────────────────────

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
              _cardRow(Icons.block_rounded, 'Not Your Lane (skip)', spec.laneSkip),
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
                  color: context.cs.onSurfaceVariant,
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

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final preset = _preset;
    if (preset == null) {
      return const Center(child: Text('Preset not found'));
    }

    final editing = _editingBlockId == null
        ? null
        : preset.blocks.where((b) => b.id == _editingBlockId).firstOrNull;
    if (editing != null) {
      return _StudioBlockEditorInline(
        key: ValueKey(editing.id),
        block: editing,
        agentOptions: _agentOptions,
        onChanged: _onBlockChanged,
        onDelete: () => _deleteBlock(editing),
      );
    }

    final blockGroups = groupStudioPresetBlocks(_pointBlocks);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _StatsPlaque(preset: preset),
        const SizedBox(height: 20),
        _sectionHeader(context, 'Agents'),
        const SizedBox(height: 4),
        ...StudioControllerOntology.specs.map(
          (spec) => _agentTile(context, preset, spec),
        ),
        const SizedBox(height: 20),
        _sectionHeader(context, 'Prompt Blocks'),
        const SizedBox(height: 8),
        _pointChips(context),
        const SizedBox(height: 8),
        if (blockGroups.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No blocks for this injection point',
                style: TextStyle(color: context.cs.onSurfaceVariant),
              ),
            ),
          )
        else
          ...blockGroups.map((group) => _blockRow(context, group)),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _addBlock,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Block'),
          ),
        ),
      ],
    );
  }

  /// Agent dropdown options — the pre-gen controllers (they produce briefs and
  /// receive specific-agent blocks). The final and post-processing agents are
  /// excluded.
  List<Map<String, dynamic>> get _agentOptions => [
    for (final spec in StudioControllerOntology.specs)
      if (!spec.isFinal && spec.phase != 'post_processing')
        {'label': spec.name, 'value': spec.id},
  ];

  Widget _sectionHeader(BuildContext context, String label) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        color: context.cs.onSurfaceVariant,
      ),
    );
  }

  Widget _agentTile(
    BuildContext context,
    StudioPreset preset,
    StudioControllerSpec spec,
  ) {
    final isOn = studioAgentEnabled(preset, spec);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(
        spec.lockedOn
            ? Icons.lock_outline
            : spec.isFinal
            ? Icons.star_outline
            : Icons.smart_toy_outlined,
        color: spec.isFinal ? context.cs.primary : null,
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
      onChanged: spec.lockedOn ? null : (v) => _toggleAgent(spec.id, v),
    );
  }

  Widget _pointChips(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: _points.map((point) {
        final count = (_preset?.blocks ?? const <StudioPresetBlock>[])
            .where((b) => b.injectionPoint == point.$1)
            .length;
        return FilterChip(
          label: Text('${point.$2} ($count)'),
          selected: point.$1 == _point,
          onSelected: (_) => setState(() => _point = point.$1),
        );
      }).toList(growable: false),
    );
  }

  Widget _blockRow(BuildContext context, StudioPresetBlockGroup group) {
    if (group.header != null) {
      return StudioPresetGroupTile(
        group: group,
        onSelectExclusive: (id) => _selectExclusive(group, id),
        onToggle: _toggleBlock,
        onEdit: (block) => setState(() => _editingBlockId = block.id),
        onDelete: _deleteBlock,
      );
    }
    final block = group.standalone!;
    return ListTile(
      key: ValueKey('block_${block.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text(
        block.title.isNotEmpty ? block.title : block.id,
        style: block.enabled
            ? null
            : const TextStyle(decoration: TextDecoration.lineThrough),
      ),
      subtitle: Text(
        _blockSubtitle(block),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Switch(
        value: block.enabled,
        onChanged: block.locked ? null : (v) => _toggleBlock(block, v),
      ),
      onTap: () => setState(() => _editingBlockId = block.id),
      onLongPress: () => _deleteBlock(block),
    );
  }

  String _blockSubtitle(StudioPresetBlock block) {
    final mode = switch (block.mode) {
      'pregenBrief' => 'Pregen Brief',
      'agentResponse' => 'Agent response',
      '' => 'Context',
      _ => 'Direct',
    };
    if (block.injectionPoint == 'specificAgent' &&
        block.targetAgentId.isNotEmpty) {
      return '$mode → ${StudioControllerOntology.byId(block.targetAgentId).name}';
    }
    return mode;
  }
}

/// Inline block editor built on the shared [GenericEditor] (the same engine the
/// plain preset block editor uses). Fields follow STUDIO_UX_ANALYSIS §5. The two
/// agent dropdowns mean opposite directions, so they are labelled `←`/`→`.
class _StudioBlockEditorInline extends StatelessWidget {
  final StudioPresetBlock block;
  final List<Map<String, dynamic>> agentOptions;
  final ValueChanged<StudioPresetBlock> onChanged;
  final VoidCallback onDelete;

  const _StudioBlockEditorInline({
    super.key,
    required this.block,
    required this.agentOptions,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final config = [
      GenericEditorSection(
        title: null,
        fields: [
          GenericEditorField(
            key: 'title',
            label: 'Title',
            type: 'text',
          ),
          GenericEditorField(
            key: 'role',
            label: 'Role',
            type: 'select',
            options: const [
              {'label': 'System', 'value': 'system'},
              {'label': 'User', 'value': 'user'},
              {'label': 'Assistant', 'value': 'assistant'},
            ],
          ),
          GenericEditorField(
            key: 'mode',
            label: 'Mode',
            type: 'select',
            options: const [
              {'label': 'Direct instruction', 'value': 'direct'},
              {'label': 'Pregen Brief', 'value': 'pregenBrief'},
              {'label': 'Agent response', 'value': 'agentResponse'},
            ],
          ),
          GenericEditorField(
            key: 'sourceAgentId',
            label: '← Take response from agent',
            type: 'select',
            options: agentOptions,
            showIf: (item) => item['mode'] == 'agentResponse',
          ),
          GenericEditorField(
            key: 'injectionPoint',
            label: 'Injection point',
            type: 'select',
            options: const [
              {'label': 'Pre-generation', 'value': 'pregen'},
              {'label': 'Final', 'value': 'final'},
              {'label': 'Post-processing', 'value': 'cleaner'},
              {'label': 'Трекер', 'value': 'ledger'},
              {'label': 'Specific agent', 'value': 'specificAgent'},
            ],
          ),
          GenericEditorField(
            key: 'targetAgentId',
            label: '→ Send to agent',
            type: 'select',
            options: agentOptions,
            showIf: (item) => item['injectionPoint'] == 'specificAgent',
          ),
          GenericEditorField(
            key: 'content',
            label: 'Content',
            type: 'textarea',
            rows: 8,
            expandable: true,
          ),
        ],
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: GenericEditor(
            item: block.toJson(),
            config: config,
            scrollable: true,
            onChanged: (values) => onChanged(StudioPresetBlock.fromJson(values)),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            MediaQuery.paddingOf(context).bottom + 16,
          ),
          child: Material(
            color: const Color(0xFFFF4444).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(12),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.delete_outlined, size: 20, color: Color(0xFFFF4444)),
                    SizedBox(width: 8),
                    Text(
                      'Delete Block',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFFF4444),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Top plaque: agent count and estimated LLM calls per turn.
class _StatsPlaque extends StatelessWidget {
  final StudioPreset preset;

  const _StatsPlaque({required this.preset});

  @override
  Widget build(BuildContext context) {
    final agents = studioPresetEnabledAgentCount(preset);
    final calls = studioPresetRequestCount(preset);
    return GlassSurface(
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.cs.outline, width: 1),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: _stat(
                context,
                icon: Icons.smart_toy_outlined,
                value: '$agents',
                label: agents == 1 ? 'agent' : 'agents',
              ),
            ),
            Container(
              width: 1,
              height: 36,
              color: context.cs.outline.withValues(alpha: 0.4),
            ),
            Expanded(
              child: _stat(
                context,
                icon: Icons.bolt,
                value: '$calls',
                label: 'calls / turn',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(
    BuildContext context, {
    required IconData icon,
    required String value,
    required String label,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: context.cs.primary),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: context.cs.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
        ),
      ],
    );
  }
}
