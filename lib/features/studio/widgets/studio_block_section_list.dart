import 'package:flutter/material.dart';

import '../../../core/models/studio_config.dart';
import '../../../core/models/studio_preset_block_groups.dart';
import '../../../core/models/studio_preset_block_reorder.dart';
import '../../../shared/theme/app_colors.dart';
import 'studio_block_row.dart';

/// The agentic preset's whole block list: every injection point rendered at
/// once, one section per stage, in the pipeline order given by [sections].
///
/// It is a single [ReorderableListView] rather than one list per section, so a
/// block can be dragged across a section header — the section a row lands in
/// becomes its injection point, and [onReorder] reports the resulting
/// placements. Section headers themselves carry no drag handle and never move.
class StudioBlockSectionList extends StatelessWidget {
  /// Every block in the preset. Sections filter this by injection point.
  final List<StudioPresetBlock> blocks;

  /// `(injectionPoint, label)` pairs, rendered top to bottom.
  final List<(String, String)> sections;

  final ValueChanged<List<StudioPresetRowPlacement>> onReorder;
  final ValueChanged<StudioPresetBlock> onEdit;
  final void Function(StudioPresetBlock block, bool enabled) onToggle;
  final void Function(StudioPresetBlockGroup group, String blockId)
  onSelectExclusive;
  final ValueChanged<StudioPresetBlock> onDelete;

  const StudioBlockSectionList({
    super.key,
    required this.blocks,
    required this.sections,
    required this.onReorder,
    required this.onEdit,
    required this.onToggle,
    required this.onSelectExclusive,
    required this.onDelete,
  });

  /// Flattens the sections into the list's items: a header per stage, then the
  /// grouped rows addressed to it, or a placeholder when it holds nothing.
  List<_StudioListRow> _rows() {
    final rows = <_StudioListRow>[];
    for (final (point, label) in sections) {
      final sectionBlocks =
          blocks.where((b) => b.injectionPoint == point).toList()
            ..sort((a, b) => a.order.compareTo(b.order));
      rows.add(
        _StudioListRow.header(point, label: label, count: sectionBlocks.length),
      );
      final entries = groupStudioPresetBlocks(sectionBlocks);
      if (entries.isEmpty) {
        rows.add(_StudioListRow.placeholder(point));
        continue;
      }
      for (final entry in entries) {
        rows.add(_StudioListRow.block(point, entry));
      }
    }
    return rows;
  }

  void _handleReorder(int oldIndex, int newIndex) {
    final rows = _rows();
    if (oldIndex < 0 || oldIndex >= rows.length) return;
    // Headers and placeholders have no drag handle; guard anyway so a stray
    // reorder can never rewrite the list from a non-block row.
    if (rows[oldIndex].entry == null) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = [...rows];
    moved.insert(newIndex, moved.removeAt(oldIndex));

    // Walk the reordered list and hand each row the section it now sits under.
    // A row dropped above the very first header belongs to that first section.
    var current = sections.first.$1;
    final placements = <StudioPresetRowPlacement>[];
    for (final row in moved) {
      if (row.isHeader) {
        current = row.point;
        continue;
      }
      final entry = row.entry;
      if (entry == null) continue; // placeholder
      placements.add(
        StudioPresetRowPlacement(entry: entry, injectionPoint: current),
      );
    }
    onReorder(placements);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: rows.length,
      // TODO: migrate to onReorderItem (newIndex semantics differ — see Flutter changelog).
      // ignore: deprecated_member_use
      onReorder: _handleReorder,
      itemBuilder: (context, i) => _buildRow(context, rows, i),
    );
  }

  Widget _buildRow(BuildContext context, List<_StudioListRow> rows, int i) {
    final row = rows[i];
    if (row.isHeader) {
      return StudioBlockSectionHeader(
        key: ValueKey('studio_section_${row.point}'),
        label: row.label!,
        count: row.count,
        isFirst: i == 0,
      );
    }
    final entry = row.entry;
    if (entry == null) {
      return Padding(
        key: ValueKey('studio_section_empty_${row.point}'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text(
          'No blocks',
          style: TextStyle(
            fontSize: 13,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }
    // The row before a header (or at the very end) drops its rule: the next
    // section header draws one, and the "Add Block" row closes the card.
    final isLast = i == rows.length - 1 || rows[i + 1].isHeader;
    if (entry.header != null) {
      return StudioBlockGroupRow(
        key: ValueKey('studio_group_${entry.header!.id}'),
        group: entry,
        dragIndex: i,
        isLast: isLast,
        onSelectExclusive: (id) => onSelectExclusive(entry, id),
        onToggle: onToggle,
        onEdit: onEdit,
        onDelete: onDelete,
      );
    }
    final block = entry.standalone!;
    return StudioBlockRow(
      key: ValueKey('studio_block_${block.id}'),
      block: block,
      dragIndex: i,
      isLast: isLast,
      onEdit: () => onEdit(block),
      onToggle: (v) => onToggle(block, v),
      onLongPress: () => onDelete(block),
    );
  }
}

/// One item of the flat list: a section header, a section's empty placeholder,
/// or a draggable block row.
class _StudioListRow {
  final String point;
  final String? label;
  final int count;
  final StudioPresetBlockGroup? entry;

  const _StudioListRow.header(
    this.point, {
    required this.label,
    required this.count,
  }) : entry = null;

  const _StudioListRow.placeholder(this.point)
    : label = null,
      count = 0,
      entry = null;

  const _StudioListRow.block(this.point, this.entry) : label = null, count = 0;

  bool get isHeader => label != null;
}
