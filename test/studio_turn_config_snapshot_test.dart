import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/studio/agent_config_resolver.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_agent_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/active_studio_preset_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_agent_providers.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'active preset change does not alter a captured turn snapshot',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container
          .read(studioFeatureEnabledProvider.notifier)
          .setEnabled(true);
      await container
          .read(studioConfigRepoProvider)
          .upsert(
            const StudioConfig(
              sessionId: 'session',
              enabled: true,
              agents: [
                StudioAgent(id: 'continuity', name: 'Continuity', order: 0),
                StudioAgent(id: 'final', name: 'Final', order: 1),
              ],
              cheapApiConfigId: 'old-api',
              cleanerApiConfigId: 'old-api',
              broadcastBlocks: ['old broadcast'],
            ),
          );
      await container
          .read(studioPresetRepoProvider)
          .upsert(
            const StudioPreset(
              id: 'old-preset',
              executionMode: StudioExecutionMode.assisted,
              blocks: [
                StudioPresetBlock(
                  id: 'old-ledger',
                  section: 'ledger',
                  content: 'old ledger instructions',
                ),
              ],
            ),
          );
      await container
          .read(studioPresetRepoProvider)
          .upsert(
            const StudioPreset(
              id: 'new-preset',
              executionMode: StudioExecutionMode.direct,
              blocks: [
                StudioPresetBlock(
                  id: 'new-ledger',
                  section: 'ledger',
                  content: 'new ledger instructions',
                ),
              ],
            ),
          );
      await container
          .read(apiConfigRepoProvider)
          .put(
            const ApiConfig(
              id: 'old-api',
              endpoint: 'https://old.example',
              model: 'old-model',
            ),
          );
      await container
          .read(apiConfigRepoProvider)
          .put(
            const ApiConfig(
              id: 'new-api',
              endpoint: 'https://new.example',
              model: 'new-model',
            ),
          );
      container.invalidate(apiListProvider);
      await container.read(apiListProvider.future);
      await container
          .read(activeStudioPresetProvider.notifier)
          .set('old-preset');
      await container
          .read(pipelineSettingsProvider.notifier)
          .save(
            const PipelineSettings(
              studioAgent: StudioAgentSettings(
                studioTrackerModelOverride: 'old-override',
              ),
            ),
          );

      final snapshot = await container
          .read(memoryStudioServiceProvider)
          .resolveTurnConfig('session');

      await container
          .read(activeStudioPresetProvider.notifier)
          .set('new-preset');
      await container
          .read(studioConfigRepoProvider)
          .upsert(
            snapshot.config!.copyWith(
              cheapApiConfigId: 'new-api',
              cleanerApiConfigId: 'new-api',
              broadcastBlocks: const ['new broadcast'],
            ),
          );
      await container
          .read(pipelineSettingsProvider.notifier)
          .save(
            const PipelineSettings(
              studioAgent: StudioAgentSettings(
                studioTrackerModelOverride: 'new-override',
              ),
            ),
          );

      expect(snapshot.preset!.id, 'old-preset');
      expect(snapshot.preset!.blocks.single.content, 'old ledger instructions');
      expect(snapshot.config!.cheapApiConfigId, 'old-api');
      expect(snapshot.config!.broadcastBlocks, ['old broadcast']);
      expect(
        snapshot.pipelineSettings.studioAgent.studioTrackerModelOverride,
        'old-override',
      );
      final cleanerConfig = snapshot.resolveCleanerConfig(
        errorLabel: 'test-cleaner',
      );
      expect(cleanerConfig.endpoint, 'https://old.example');
      expect(cleanerConfig.model, 'old-model');
    },
  );

  test('AgentRunner resolves downstream API identity from snapshot', () async {
    const oldApi = ApiConfig(
      id: 'old-api',
      endpoint: 'https://old.example',
      model: 'old-model',
    );
    const newApi = ApiConfig(
      id: 'new-api',
      endpoint: 'https://new.example',
      model: 'new-model',
    );
    var currentSettings = const PipelineSettings();
    var currentApis = const [newApi];
    final runner = AgentRunner(
      configResolver: AgentConfigResolver(
        loadApiConfigs: () async => currentApis,
        readActiveApiConfig: () => newApi,
        readPipelineSettings: () => currentSettings,
        readRunApiConfigId: (_) async => 'new-api',
      ),
      readPipelineSettings: () => currentSettings,
    );
    const snapshot = StudioTurnConfigSnapshot(
      config: StudioConfig(
        sessionId: 'session',
        enabled: true,
        cheapApiConfigId: 'old-api',
      ),
      preset: StudioPreset(id: 'old-preset'),
      pipelineSettings: PipelineSettings(
        studioAgent: StudioAgentSettings(
          studioTrackerModelOverride: 'snapshot-model',
        ),
      ),
      apiConfigs: [oldApi],
      activeApiConfig: oldApi,
    );

    currentSettings = const PipelineSettings(
      studioAgent: StudioAgentSettings(
        studioTrackerModelOverride: 'changed-model',
      ),
    );
    currentApis = const [newApi];
    final resolved = await runner.resolveAgentConfig(
      const StudioAgent(id: 'tracker', name: 'Tracker'),
      newApi,
      'session',
      apiConfigId: snapshot.config!.cheapApiConfigId,
      turnConfig: snapshot,
    );

    expect(resolved.endpoint, oldApi.endpoint);
    expect(resolved.model, 'snapshot-model');
  });
}
