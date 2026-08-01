import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/studio_config.dart';
import '../../core/models/studio_preset_block_groups.dart';
import '../../core/models/studio_preset_block_reorder.dart';
import '../../core/state/db_provider.dart';
import '../../core/utils/id_generator.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../settings/app_settings_provider.dart';
import '../studio/studio_agent_toggle.dart';
import '../studio/studio_preset_stats.dart';
import '../studio/widgets/studio_agents_panel.dart';
import '../studio/widgets/studio_block_editor_inline.dart';
import '../studio/widgets/studio_block_row.dart';
import '../studio/widgets/studio_preset_options_sheet.dart';
import 'studio_preset_export.dart';
import 'widgets/preset_dashboard_card.dart';

/// Full editor for a single agentic (Studio) preset, rendered inline inside the
/// [PresetListScreen] SheetView.
///
/// Same shape as the plain [PresetEditorBody]: one dashboard card holding the
/// identity + overflow menu, the stat badges, and the reorderable block list
/// with its "Add Block" row. Editing a block replaces the body with the shared
/// [GenericEditor], and back returns to the dashboard.
///
/// Two agentic-only sections sit between the badges and the list, in the order
/// the pipeline reads them: the collapsible agent list (which stages run at
/// all), then the injection-point filter (blocks are addressed to different
/// stages per §5, so the list shows one stage at a time).
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
  bool _agentsExpanded = false;
  Timer? _saveTimer;

  final ScrollController _scrollController = ScrollController();
  double? _savedScrollOffset;

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
    _scrollController.dispose();
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
      _restoreScrollAfterFrame();
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

  // ── Scroll position across the inline editor ───────────────────────────────

  void _saveScrollOffset() {
    if (_scrollController.hasClients) {
      _savedScrollOffset = _scrollController.offset;
    }
  }

  void _restoreScrollAfterFrame() {
    if (_savedScrollOffset == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _savedScrollOffset == null ||
          !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(
        _savedScrollOffset!.clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        ),
      );
      _savedScrollOffset = null;
    });
  }

  void _openBlock(StudioPresetBlock block) {
    // The grouper synthesizes a "Tense" header that has no stored block — it
    // has nothing to edit, so tapping it is a no-op rather than an editor that
    // opens onto nothing.
    final preset = _preset;
    if (preset == null || !preset.blocks.any((b) => b.id == block.id)) return;
    _saveScrollOffset();
    setState(() => _editingBlockId = block.id);
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
    if (mounted) _openBlock(draft);
  }

  Future<void> _deleteBlock(StudioPresetBlock block) async {
    final preset = _preset;
    if (preset == null) return;
    final ok = await confirmStudioDelete(
      context,
      title: 'Delete Block',
      description:
          'Delete "${block.title.isNotEmpty ? block.title : block.id}"?',
    );
    if (!ok) return;
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

  // ── Reordering ─────────────────────────────────────────────────────────────

  void _onReorder(int oldIndex, int newIndex) {
    final preset = _preset;
    if (preset == null) return;
    final entries = groupStudioPresetBlocks(_pointBlocks);
    if (oldIndex < 0 || oldIndex >= entries.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final reordered = [...entries];
    reordered.insert(newIndex, reordered.removeAt(oldIndex));
    final blocks = reorderStudioPresetBlocks(
      all: preset.blocks,
      entries: reordered,
    );
    if (identical(blocks, preset.blocks)) return;
    unawaited(_persistNow(preset.copyWith(blocks: blocks)));
  }

  // ── Preset-level actions ───────────────────────────────────────────────────

  void _showRenameDialog() {
    final preset = _preset;
    if (preset == null) return;
    showStudioPresetRename(
      context,
      preset: preset,
      onRename: (name) =>
          unawaited(_persistNow(preset.copyWith(name: name))),
    );
  }

  Future<void> _clonePreset() async {
    final preset = _preset;
    if (preset == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Cloning stays passive on purpose (the plain preset editor behaves the
    // same): the copy is created but the active selection does not move.
    final clone = preset.copyWith(
      id: 'studio_$now',
      name: '${preset.name} (copy)',
      blocks: [...preset.blocks],
      agentEnabled: {...preset.agentEnabled},
      updatedAt: now,
    );
    await ref.read(studioPresetRepoProvider).upsert(clone);
    ref.invalidate(studioPresetListProvider);
    if (mounted) GlazeToast.show(context, 'Preset cloned');
  }

  Future<void> _deletePreset() async {
    final preset = _preset;
    if (preset == null) return;
    final ok = await confirmStudioDelete(
      context,
      title: 'Delete Preset',
      description: 'Delete "${preset.name}"? This cannot be undone.',
    );
    if (!ok) return;
    _saveTimer?.cancel();
    await ref.read(studioPresetRepoProvider).deleteById(preset.id);
    if (!mounted) return;
    ref.invalidate(studioPresetListProvider);
    widget.onClose();
  }

  void _showOptionsMenu() {
    final preset = _preset;
    if (preset == null) return;
    showStudioPresetOptions(
      context,
      preset: preset,
      onRename: _showRenameDialog,
      onClone: () => unawaited(_clonePreset()),
      onExport: () => unawaited(exportStudioPreset(context, preset)),
      onDelete: () => unawaited(_deletePreset()),
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
      return StudioBlockEditorInline(
        key: ValueKey(editing.id),
        block: editing,
        onChanged: _onBlockChanged,
        onDelete: () => _deleteBlock(editing),
      );
    }

    return SingleChildScrollView(
      controller: _scrollController,
      key: const ValueKey('studio_dashboard'),
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top,
        bottom:
            MediaQuery.paddingOf(context).bottom +
            MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDashboard(preset),
          const SizedBox(height: 60),
        ],
      ),
    );
  }

  Widget _buildDashboard(StudioPreset preset) {
    final addBlockAtTop =
        ref.watch(appSettingsProvider).value?.addBlockAtTop ?? false;
    final entries = groupStudioPresetBlocks(_pointBlocks);

    return PresetDashboardCard(
      leading: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          Icons.smart_toy_outlined,
          size: 26,
          color: context.cs.primary,
        ),
      ),
      title: preset.name.isNotEmpty ? preset.name : 'Agentic Preset',
      subtitle: 'agentic preset',
      onTitleTap: _showRenameDialog,
      onMenuTap: _showOptionsMenu,
      utilsLeading: [
        PresetUtilButton(
          icon: Icons.smart_toy_outlined,
          count: studioPresetEnabledAgentCount(preset),
          onTap: () => setState(() => _agentsExpanded = !_agentsExpanded),
        ),
      ],
      utilsTrailing: [
        PresetStatBadge(
          icon: Icons.bolt,
          label: '${studioPresetRequestCount(preset)}/ход',
        ),
        const SizedBox(width: 8),
        PresetStatBadge(
          icon: Icons.description,
          label: '${studioPresetTokenLabel(preset)}t',
        ),
      ],
      // Agents come before the block list: they decide which stages run, and
      // the blocks below are addressed to those stages.
      belowUtils: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StudioAgentsPanel(
            preset: preset,
            expanded: _agentsExpanded,
            onToggleExpanded: () =>
                setState(() => _agentsExpanded = !_agentsExpanded),
            onToggle: _toggleAgent,
          ),
          _buildPointChips(),
        ],
      ),
      blockList: _buildBlockList(entries),
      addBlockAtTop: addBlockAtTop,
      onAddBlock: _addBlock,
    );
  }

  /// Injection-point filter. Each chip carries the number of blocks addressed
  /// to that stage so an empty stage is obvious before tapping it.
  Widget _buildPointChips() {
    final blocks = _preset?.blocks ?? const <StudioPresetBlock>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final point in _points)
            ChoiceChip(
              label: Text(
                '${point.$2} '
                '(${blocks.where((b) => b.injectionPoint == point.$1).length})',
                style: const TextStyle(fontSize: 12),
              ),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              selected: point.$1 == _point,
              onSelected: (_) => setState(() => _point = point.$1),
            ),
        ],
      ),
    );
  }

  Widget _buildBlockList(List<StudioPresetBlockGroup> entries) {
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            'No blocks for this injection point',
            style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
          ),
        ),
      );
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: entries.length,
      // TODO: migrate to onReorderItem (newIndex semantics differ — see Flutter changelog).
      // ignore: deprecated_member_use
      onReorder: _onReorder,
      itemBuilder: (_, i) {
        final entry = entries[i];
        final isLast = i == entries.length - 1;
        if (entry.header != null) {
          return StudioBlockGroupRow(
            key: ValueKey('studio_group_${entry.header!.id}'),
            group: entry,
            dragIndex: i,
            isLast: isLast,
            onSelectExclusive: (id) => _selectExclusive(entry, id),
            onToggle: _toggleBlock,
            onEdit: _openBlock,
            onDelete: _deleteBlock,
          );
        }
        final block = entry.standalone!;
        return StudioBlockRow(
          key: ValueKey('studio_block_${block.id}'),
          block: block,
          dragIndex: i,
          isLast: isLast,
          onEdit: () => _openBlock(block),
          onToggle: (v) => _toggleBlock(block, v),
          onLongPress: () => _deleteBlock(block),
        );
      },
    );
  }
}
