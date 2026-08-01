/// One-way, idempotent migration of legacy [StudioPresetBlock]s (the old
/// `kind` + `section` model) to the target model (`mode` + `injectionPoint` +
/// `targetAgentId`), per `STUDIO_UX_ANALYSIS.md` §5.
///
/// Applied at the single repo choke point ([StudioPresetRepo] normalization),
/// so it covers reads, writes, imports and the seeded default. Migrated blocks
/// have their `kind`/`section` cleared, which makes the transform a no-op on
/// re-run (blocks the editor creates carry no `kind`, so they are never
/// re-derived and their explicit `mode`/`injectionPoint` survive).
library;

import 'studio_config.dart';

/// Block kind that only carried the generic "you are an intermediate agent"
/// envelope — the agent now emits that itself (§3/§4), so these are dropped.
const _agentInstructionKind = 'agent_instruction';

/// Sections whose backing services were deleted — dead data (§5).
const _deadSections = {'build', 'brief_parser'};

/// Legacy `tracker_instruction` alias keyword → controller `specId`. Ordered;
/// first substring match on the block's `id`/`title` wins. Lifted verbatim
/// from the routing heuristics being removed
/// (`StudioRuntimeBlockExpander.trackerInstructionAppliesToAgent`).
/// Legacy context-slot kinds. Migrated to an empty `mode` (the runtime then
/// resolves them by their canonical `id`) with `id` pinned to the kind name.
const _contextKinds = {
  'static_context',
  'chat_history',
  'dynamic_context',
  'char_card',
  'char_personality',
  'user_persona',
  'scenario',
  'example_dialogue',
  'authors_note',
  'memory',
};

const _agentAliases = <(String, String)>[
  ('continuity', 'continuity'),
  ('agency', 'agency'),
  ('character', 'agency'),
  ('dialogue', 'dialogue'),
  ('guard', 'guard'),
  ('loop', 'guard'),
  ('prose', 'guard'),
  ('world', 'world'),
  ('npc', 'world'),
  ('meta', 'meta'),
  ('ooc', 'meta'),
  ('lumia', 'meta'),
];

/// True if any block still carries a legacy `kind` (the migration signal).
bool studioPresetBlocksNeedMigration(List<StudioPresetBlock> blocks) =>
    blocks.any((b) => b.kind.isNotEmpty);

/// Migrates [blocks] to the target model. Returns the same list instance when
/// nothing needs migrating.
List<StudioPresetBlock> migrateStudioPresetBlocksToV2(
  List<StudioPresetBlock> blocks,
) {
  if (!studioPresetBlocksNeedMigration(blocks)) return blocks;
  final out = <StudioPresetBlock>[];
  for (final b in blocks) {
    if (b.kind.isEmpty) {
      out.add(b); // already migrated / editor-created — preserve as-is.
      continue;
    }
    if (b.kind == _agentInstructionKind) continue;
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
  switch (b.kind) {
    case 'previous_agents':
      return b.copyWith(
        mode: 'pregenBrief',
        injectionPoint: injection,
        kind: '',
        section: '',
      );
    case 'tracker_instruction':
      // Routed to a single controller: injection point "specific agent" with
      // the resolved target. A block matching no live controller gets an empty
      // target, which reaches no agent — matching the old heuristic's silence.
      return b.copyWith(
        mode: 'direct',
        injectionPoint: 'specificAgent',
        targetAgentId: _aliasFor(b),
        kind: '',
        section: '',
      );
    case 'group_open':
      return b.copyWith(
        groupBoundary: 'open',
        mode: '',
        injectionPoint: injection,
        kind: '',
        section: '',
      );
    case 'group_close':
      return b.copyWith(
        groupBoundary: 'close',
        mode: '',
        injectionPoint: injection,
        kind: '',
        section: '',
      );
    default:
      if (_contextKinds.contains(b.kind)) {
        // Context slot: empty `mode` marks it for id-based resolution at
        // runtime; the id is pinned to the canonical kind name.
        return b.copyWith(
          id: b.kind,
          mode: '',
          injectionPoint: injection,
          kind: '',
          section: '',
        );
      }
      // custom_text / slot / instruction — emits its own content ('direct').
      return b.copyWith(
        mode: 'direct',
        injectionPoint: injection,
        kind: '',
        section: '',
      );
  }
}

String _aliasFor(StudioPresetBlock b) {
  final text = '${b.id}\n${b.title}'.toLowerCase();
  for (final (keyword, specId) in _agentAliases) {
    if (text.contains(keyword)) return specId;
  }
  return '';
}
