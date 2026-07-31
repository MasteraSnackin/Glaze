import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  late AppDatabase db;
  late StudioPresetRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = StudioPresetRepo(db);
  });
  tearDown(() => db.close());

  test('round-trips agent toggles and per-agent overrides', () async {
    const preset = StudioPreset(
      id: 'studio_direct_loom_v1',
      name: 'Direct Loom v1',
      agentEnabled: {'continuity': false, 'final': true},
    );

    await repo.upsert(preset);
    final restored = await repo.getById(preset.id);

    expect(restored?.agentEnabled, preset.agentEnabled);
    expect(restored?.name, preset.name);
  });
}
