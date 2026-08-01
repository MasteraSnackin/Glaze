/// One-way, idempotent migration of legacy [StudioPresetBlock]s (the old
/// `type` + `section` model) to the target model (`mode` + `injectionPoint` +
/// `targetAgentId`), per `STUDIO_UX_ANALYSIS.md` §5.
///
/// Applied at the single repo choke point ([StudioPresetRepo] normalization),
/// so it covers reads, writes, imports and the seeded default. Migrated blocks
/// have their `section` cleared, which makes the transform a no-op on re-run
/// (blocks the editor creates carry no `section`, so they are never re-derived
/// and their explicit `mode`/`injectionPoint` survive).
library;

import 'studio_config.dart';

/// Sections whose backing services were deleted — dead data (§5).
const _deadSections = {'build', 'brief_parser'};

/// True if any block still carries a legacy `section` (the migration signal).
bool studioPresetBlocksNeedMigration(List<StudioPresetBlock> blocks) =>
    blocks.any((b) => b.section.isNotEmpty);

/// Migrates [blocks] to the target model. Returns the same list instance when
/// nothing needs migrating.
List<StudioPresetBlock> migrateStudioPresetBlocksToV2(
  List<StudioPresetBlock> blocks,
) {
  if (!studioPresetBlocksNeedMigration(blocks)) return blocks;
  final out = <StudioPresetBlock>[];
  for (final b in blocks) {
    if (b.section.isEmpty) {
      out.add(b); // already migrated / editor-created — preserve as-is.
      continue;
    }
    if (_deadSections.contains(b.section)) continue;
    out.add(_migrateBlock(b));
  }
  return out;
}

StudioPresetBlock _migrateBlock(StudioPresetBlock b) {
  // section → injectionPoint (1:1); default 'pregen'.
  final injection = switch (b.section) {
    'final' => 'final',
    'cleaner' => 'cleaner',
    'ledger' => 'ledger',
    _ => 'pregen',
  };
  // Group boundary by id suffix (synthesize from normalizeStudioGroupBoundaries).
  if (b.id.endsWith('_group_open')) {
    return b.copyWith(
      groupBoundary: 'open',
      mode: '',
      injectionPoint: injection,
      section: '',
    );
  }
  if (b.id.endsWith('_group_close') || b.id.endsWith('_prefix_close')) {
    return b.copyWith(
      groupBoundary: 'close',
      mode: '',
      injectionPoint: injection,
      section: '',
    );
  }
  switch (b.type) {
    case StudioBlockType.priorBriefs:
      return b.copyWith(
        mode: 'pregenBrief',
        injectionPoint: injection,
        section: '',
      );
    case StudioBlockType.context:
    case StudioBlockType.history:
      // Context slot: empty `mode` marks it for id-based resolution at
      // runtime; the id is already set to the canonical slot name.
      return b.copyWith(
        mode: '',
        injectionPoint: injection,
        section: '',
      );
    case StudioBlockType.instruction:
      // Tracker instructions carry a targetAgentId (set by nightly #194);
      // route them to the specific agent. Regular instructions emit content.
      if (b.targetAgentId != null && b.targetAgentId!.isNotEmpty) {
        return b.copyWith(
          mode: 'direct',
          injectionPoint: 'specificAgent',
          section: '',
        );
      }
      return b.copyWith(
        mode: 'direct',
        injectionPoint: injection,
        section: '',
      );
  }
}
