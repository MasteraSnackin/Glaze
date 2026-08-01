import 'studio_config.dart';
import 'studio_preset_block_groups.dart';

/// One block row of the editor in its final on-screen position: the group it
/// renders and the section it now sits in. Dropping a row under a different
/// section header is how a block is re-targeted, so the injection point travels
/// with the placement rather than with the block it came from.
class StudioPresetRowPlacement {
  final StudioPresetBlockGroup entry;
  final String injectionPoint;

  const StudioPresetRowPlacement({
    required this.entry,
    required this.injectionPoint,
  });
}

/// Every block a dashboard row owns, in the order it must be emitted.
///
/// A section row carries its opening tag, header, children and closing tag as
/// one unit, so dragging a section moves — and re-targets — the whole thing.
List<StudioPresetBlock> studioPresetEntryBlocks(StudioPresetBlockGroup entry) {
  if (entry.header == null) return [entry.standalone!];
  return [
    if (entry.openingBoundary case final block?) block,
    entry.header!,
    ...entry.children,
    if (entry.closingBoundary case final block?) block,
  ];
}

/// Rewrites `order` — and `injectionPoint` where a row changed section — so the
/// preset's blocks follow the row order in [rows].
///
/// Only the slots currently held by those rows are permuted: any block the
/// grouper did not surface, such as an orphaned boundary tag, keeps the
/// position it already had, so a drag can never silently drop or relocate it.
/// Returns [all] unchanged when the rows and the slots they claim do not line
/// up.
List<StudioPresetBlock> reorderStudioPresetBlocks({
  required List<StudioPresetBlock> all,
  required List<StudioPresetRowPlacement> rows,
}) {
  final existingIds = {for (final block in all) block.id};
  final flattened = <StudioPresetBlock>[];
  for (final row in rows) {
    for (final block in studioPresetEntryBlocks(row.entry)) {
      // The grouper synthesizes a "Tense" header that has no stored block; it
      // owns no slot and must not enter the permutation.
      if (!existingIds.contains(block.id)) continue;
      flattened.add(
        block.injectionPoint == row.injectionPoint
            ? block
            : block.copyWith(injectionPoint: row.injectionPoint),
      );
    }
  }
  final movedIds = {for (final block in flattened) block.id};
  if (movedIds.length != flattened.length) return all;

  final sorted = [...all]..sort((a, b) => a.order.compareTo(b.order));
  final slots = <int>[
    for (var i = 0; i < sorted.length; i++)
      if (movedIds.contains(sorted[i].id)) i,
  ];
  if (slots.length != flattened.length) return all;

  for (var i = 0; i < slots.length; i++) {
    sorted[slots[i]] = flattened[i];
  }
  return [
    for (var i = 0; i < sorted.length; i++) sorted[i].copyWith(order: i),
  ];
}
