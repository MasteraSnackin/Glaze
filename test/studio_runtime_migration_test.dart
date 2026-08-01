import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/studio_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/models/cleaner_settings.dart';
import 'package:glaze_flutter/core/models/ledger_settings.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_agent_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'migrates legacy global runtime once without overwriting presets',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final presetRepo = StudioPresetRepo(db);
      final configRepo = StudioConfigRepo(db);
      addTearDown(db.close);

      await presetRepo.upsert(const StudioPreset(id: 'empty'));
      await presetRepo.upsert(
        const StudioPreset(
          id: 'configured',
          runtime: StudioRuntimeSettings(
            agents: StudioAgentSettings(
              studioTrackerModelOverride: 'configured-model',
            ),
          ),
        ),
      );
      await configRepo.upsert(
        const StudioConfig(
          sessionId: 'older',
          broadcastBlocks: [],
          updatedAt: 10,
        ),
      );
      await configRepo.upsert(
        const StudioConfig(
          sessionId: 'newer',
          broadcastBlocks: ['newer broadcast'],
          updatedAt: 20,
        ),
      );

      const legacyPipeline = PipelineSettings(
        studioAgent: StudioAgentSettings(
          studioTrackerModelOverride: 'legacy-model',
        ),
        cleaner: CleanerSettings(postCleanerModel: 'legacy-cleaner'),
        ledger: LedgerSettings(studioLedgerMaxTokens: 456),
      );
      await migrateLegacyStudioPresetRuntime(
        prefs: prefs,
        pipeline: legacyPipeline,
        loadPresets: presetRepo.getAll,
        loadConfigs: configRepo.getAll,
        savePreset: presetRepo.upsert,
      );

      final migrated = await presetRepo.getById('empty');
      expect(migrated?.runtime.agents, legacyPipeline.studioAgent);
      expect(migrated?.runtime.cleaner, legacyPipeline.cleaner);
      expect(migrated?.runtime.ledger, legacyPipeline.ledger);
      expect(migrated?.runtime.broadcastBlocks, ['newer broadcast']);
      expect(
        (await presetRepo.getById(
          'configured',
        ))?.runtime.agents.studioTrackerModelOverride,
        'configured-model',
      );

      await migrateLegacyStudioPresetRuntime(
        prefs: prefs,
        pipeline: const PipelineSettings(
          studioAgent: StudioAgentSettings(
            studioTrackerModelOverride: 'must-not-overwrite',
          ),
        ),
        loadPresets: presetRepo.getAll,
        loadConfigs: configRepo.getAll,
        savePreset: presetRepo.upsert,
      );
      expect(
        (await presetRepo.getById(
          'empty',
        ))?.runtime.agents.studioTrackerModelOverride,
        'legacy-model',
      );
    },
  );

  test('does not complete migration before presets exist', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var saves = 0;

    await migrateLegacyStudioPresetRuntime(
      prefs: prefs,
      pipeline: const PipelineSettings(),
      loadPresets: () async => const [],
      loadConfigs: () async => const [],
      savePreset: (_) async {
        saves++;
      },
    );

    expect(prefs.getBool('studioPresetRuntimeMigrationV1'), isNull);
    expect(saves, 0);
  });
}
