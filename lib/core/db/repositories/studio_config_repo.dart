import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/studio_config.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';
import '../../application/sync_repo_interfaces.dart';

class StudioConfigRepo implements SyncStudioConfigStore {
  final AppDatabase db;

  const StudioConfigRepo(this.db);

  Future<StudioConfig?> getBySessionId(String sessionId) async {
    final row = await (db.select(
      db.studioConfigRows,
    )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
    if (row == null) {
      // No session-specific config — fall back to the first global profile
      // so new sessions inherit Studio settings without a dialog prompt.
      final profiles = await getProfiles();
      if (profiles.isEmpty) return null;
      final profile = profiles.first;
      // Bind the session to the profile so future lookups are direct.
      await _upsertRow(
        profile.copyWith(
          sessionId: sessionId,
          profileId: profile.profileId,
          enabled: profile.enabled,
        ),
      );
      return profile.copyWith(sessionId: sessionId);
    }
    final binding = _rowToModel(row);
    final profileId = binding.profileId;
    if (profileId.isEmpty || profileId == binding.sessionId) {
      return binding;
    }
    final profile = await getByProfileId(profileId);
    return profile?.copyWith(
          sessionId: binding.sessionId,
          enabled: binding.enabled,
          profileId: profile.profileId.isNotEmpty
              ? profile.profileId
              : profileId,
        ) ??
        binding;
  }

  Future<StudioConfig?> getByProfileId(String profileId) async {
    final row =
        await (db.select(db.studioConfigRows)..where(
              (t) =>
                  t.profileId.equals(profileId) & t.sessionId.equals(profileId),
            ))
            .getSingleOrNull();
    if (row != null) return _rowToModel(row);
    final fallback = await (db.select(
      db.studioConfigRows,
    )..where((t) => t.profileId.equals(profileId))).getSingleOrNull();
    return fallback == null ? null : _rowToModel(fallback);
  }

  /// True if any Studio config row (session binding or profile) has ever been
  /// enabled. Used to migrate pre-existing Studio users onto the global
  /// Experimental Features master switch without losing their setup.
  Future<bool> hasAnyEnabledConfig() async {
    final row =
        await (db.select(db.studioConfigRows)
              ..where((t) => t.enabled.equals(true))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  Future<List<StudioConfig>> getProfiles() async {
    final rows = await db.select(db.studioConfigRows).get();
    final byProfile = <String, StudioConfig>{};
    for (final row in rows) {
      final config = _rowToModel(row);
      final id = config.profileId.isNotEmpty
          ? config.profileId
          : config.sessionId;
      final existing = byProfile[id];
      if (existing == null || config.sessionId == id) {
        byProfile[id] = config.copyWith(profileId: id);
      }
    }
    final profiles = byProfile.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return profiles;
  }

  @override
  Future<List<StudioConfig>> getAll() => getProfiles();

  @override
  Future<StudioConfig?> getById(String id) => getByProfileId(id);

  @override
  Future<void> put(StudioConfig config) => upsert(config);

  @override
  Future<void> delete(String id) async {
    await (db.delete(
      db.studioConfigRows,
    )..where((t) => t.profileId.equals(id))).go();
  }

  Future<void> bindSessionToProfile({
    required String sessionId,
    required String profileId,
    bool enabled = true,
  }) async {
    final profile = await getByProfileId(profileId);
    if (profile == null) return;
    await upsert(
      profile.copyWith(
        sessionId: sessionId,
        profileId: profileId,
        enabled: enabled,
        createdAt: currentTimestampSeconds(),
        updatedAt: currentTimestampSeconds(),
      ),
    );
  }

  Future<void> upsert(StudioConfig config) async {
    await _upsertRow(config);
    final profileId = config.profileId.isNotEmpty
        ? config.profileId
        : config.sessionId;
    if (profileId != config.sessionId) {
      await _upsertRow(
        config.copyWith(sessionId: profileId, profileId: profileId),
      );
    }
  }

  Future<void> _upsertRow(StudioConfig config) {
    return db
        .into(db.studioConfigRows)
        .insertOnConflictUpdate(
          StudioConfigRowsCompanion.insert(
            sessionId: config.sessionId,
            profileId: Value(
              config.profileId.isNotEmpty ? config.profileId : config.sessionId,
            ),
            profileName: Value(config.profileName),
            enabled: Value(config.enabled),
            broadcastBlocksJson: Value(jsonEncode(config.broadcastBlocks)),
            createdAt: Value(config.createdAt),
            updatedAt: Value(currentTimestampSeconds()),
          ),
        );
  }

  Future<void> deleteBySessionId(String sessionId) {
    return (db.delete(
      db.studioConfigRows,
    )..where((t) => t.sessionId.equals(sessionId))).go();
  }

  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
  }) async {
    final source = await getBySessionId(fromSessionId);
    if (source == null) return;
    // A branch needs only its session binding. Do not route through upsert(),
    // which would also rewrite the shared profile row and its updatedAt.
    await _upsertRow(
      source.copyWith(
        sessionId: toSessionId,
        profileId: source.profileId.isNotEmpty
            ? source.profileId
            : source.sessionId,
        createdAt: currentTimestampSeconds(),
        updatedAt: currentTimestampSeconds(),
      ),
    );
  }

  StudioConfig _rowToModel(StudioConfigRow row) {
    List<String> broadcastBlocks;
    try {
      broadcastBlocks = (jsonDecode(row.broadcastBlocksJson) as List<dynamic>)
          .whereType<String>()
          .toList(growable: false);
    } catch (_) {
      broadcastBlocks = const [];
    }

    return StudioConfig(
        sessionId: row.sessionId,
        profileId: row.profileId.isNotEmpty ? row.profileId : row.sessionId,
        profileName: row.profileName,
        enabled: row.enabled,
        broadcastBlocks: broadcastBlocks,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );
  }
}
