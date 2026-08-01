import 'dart:convert';

import 'package:drift/drift.dart';

import '../../application/sync_repo_interfaces.dart';
import '../../models/studio_config.dart';
import '../../models/studio_agent_codec.dart';
import '../../models/studio_preset_block_migration.dart';
import '../../models/studio_preset_codec.dart';
import '../app_db.dart';

class StudioPresetRepo implements SyncStudioPresetStore {
  final AppDatabase db;

  const StudioPresetRepo(this.db);

  static const _runtimeComputedBlockIds = {
    'runtime_envelope',
    'brief_usage_note',
    'hard_style_contract',
    'beauty_shard_contract',
  };

  @override
  Future<StudioPreset?> getById(String id) async {
    final row = await (db.select(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return _rowToModel(row);
  }

  Future<StudioPreset?> getDefault() => getById('default');

  /// Ensures the built-in `default` Studio preset exists and returns it.
  ///
  /// Fresh installs build the schema through `onCreate`, which (unlike the
  /// `onUpgrade` migration that seeds it) leaves `studio_preset_rows` empty.
  /// Without a seeded preset there is nothing to clone, so "Add Agentic
  /// Preset" would silently no-op. Idempotent — a no-op once the row exists.
  Future<StudioPreset> ensureDefaultSeeded() async {
    final existing = await getById('default');
    if (existing != null) return existing;
    final blocks = defaultStudioPresetSeedBlocks()
        .map(StudioPresetBlock.fromJson)
        .toList();
    final preset = StudioPreset(
      id: 'default',
      name: 'Default Studio Preset',
      blocks: blocks,
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await upsert(preset);
    return preset;
  }

  @override
  Future<List<StudioPreset>> getAll() async {
    final rows = await db.select(db.studioPresetRows).get();
    return rows.map(_rowToModel).toList();
  }

  @override
  Future<void> put(StudioPreset preset) => upsert(preset);

  Future<void> upsert(StudioPreset preset) async {
    final normalized = _normalizePreset(preset);
    await db
        .into(db.studioPresetRows)
        .insertOnConflictUpdate(
          StudioPresetRowsCompanion.insert(
            presetId: normalized.id,
            name: normalized.name,
            blocksJson: Value(
              jsonEncode(normalized.blocks.map((b) => b.toJson()).toList()),
            ),
            agentsJson: Value(StudioAgentCodec.encodeAgents(normalized.agents)),
            expensiveApiConfigId: Value(normalized.expensiveApiConfigId),
            cheapApiConfigId: Value(normalized.cheapApiConfigId),
            cleanerApiConfigId: Value(normalized.cleanerApiConfigId),
            maxFinalHistoryMessages: Value(normalized.maxFinalHistoryMessages),
            agentEnabledJson: Value(jsonEncode(normalized.agentEnabled)),
            runtimeSettingsJson: Value(
              jsonEncode(StudioPresetCodec.encodeRuntime(normalized.runtime)),
            ),
            updatedAt: Value(normalized.updatedAt),
          ),
        );
  }

  @override
  Future<void> delete(String id) => deleteById(id);

  Future<void> deleteById(String id) async {
    await (db.delete(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals(id))).go();
  }

  StudioPreset _rowToModel(StudioPresetRow row) {
    List<StudioPresetBlock> blocks;
    try {
      final list = jsonDecode(row.blocksJson) as List<dynamic>;
      blocks = list
          .map(
            (e) => StudioPresetCodec.canonicalizeBlock(
              Map<String, dynamic>.from(e as Map),
            ).block,
          )
          .toList();
    } catch (_) {
      blocks = [];
    }
    Map<String, bool> agentEnabled;
    try {
      agentEnabled = (jsonDecode(row.agentEnabledJson) as Map<String, dynamic>)
          .map((key, value) => MapEntry(key, value == true));
    } catch (_) {
      agentEnabled = const {};
    }
    List<StudioAgent> agents;
    try {
      agents = StudioAgentCodec.decodeAgentsJson(row.agentsJson);
    } catch (_) {
      agents = const [];
    }
    var runtime = const StudioRuntimeSettings();
    try {
      final decoded = jsonDecode(row.runtimeSettingsJson);
      if (decoded is Map && decoded.isNotEmpty) {
        runtime = StudioPresetCodec.decodePreset({
          'id': row.presetId,
          'agents': const <dynamic>[],
          'runtime': decoded,
        }).preset.runtime;
      }
    } catch (_) {
      // Runtime settings are independent of the preset's blocks and agents.
    }
    return _normalizePreset(
      StudioPreset(
        id: row.presetId,
        name: row.name,
        blocks: blocks,
        agents: agents,
        expensiveApiConfigId: row.expensiveApiConfigId,
        cheapApiConfigId: row.cheapApiConfigId,
        cleanerApiConfigId: row.cleanerApiConfigId,
        maxFinalHistoryMessages: row.maxFinalHistoryMessages,
        agentEnabled: agentEnabled,
        runtime: runtime,
        updatedAt: row.updatedAt,
      ),
    );
  }

  StudioPreset _normalizePreset(StudioPreset preset) {
    // Migrate legacy kind/section blocks to the mode/injectionPoint model
    // (STUDIO_UX_ANALYSIS §5) at the single repo choke point — covers reads,
    // writes, imports and the seeded default. Idempotent once migrated.
    final migrated = migrateStudioPresetBlocksToV2(preset.blocks);
    final blocks = migrated
        .where((block) => !_runtimeComputedBlockIds.contains(block.id))
        .toList();
    final agents = StudioAgentCodec.decodeAgentsJson(
      StudioAgentCodec.encodeAgents(preset.agents),
    );
    if (identical(migrated, preset.blocks) &&
        blocks.length == preset.blocks.length &&
        agents.length == preset.agents.length) {
      return preset;
    }
    return preset.copyWith(blocks: blocks, agents: agents);
  }
}
