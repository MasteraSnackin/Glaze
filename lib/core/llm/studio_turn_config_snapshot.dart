import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_config.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import '../state/active_studio_preset_provider.dart';
import '../state/db_provider.dart';
import '../../features/settings/api_list_provider.dart';
import 'aux_llm_client.dart';
import 'studio_activation_gate.dart';
import 'studio_controller_ontology.dart';
import 'studio_slot_resolver.dart';

/// Immutable Studio configuration captured once for a chat generation turn.
class StudioTurnConfigSnapshot {
  final StudioConfig? config;
  final StudioPreset? preset;
  final PipelineSettings pipelineSettings;
  final List<ApiConfig> apiConfigs;
  final ApiConfig? activeApiConfig;

  const StudioTurnConfigSnapshot({
    required this.config,
    required this.preset,
    required this.pipelineSettings,
    required this.apiConfigs,
    required this.activeApiConfig,
  });

  bool get enabled => config != null && preset != null;

  AuxApiConfig resolveCleanerConfig({
    required String errorLabel,
    bool? useResponsesApi,
  }) {
    return StudioSlotResolver.resolve(
      apiConfigs: apiConfigs,
      apiConfigId: config?.cleanerApiConfigId ?? '',
      fallback: activeApiConfig,
      errorLabel: errorLabel,
      modelOverride: pipelineSettings.cleaner.postCleanerModel,
      extraRequestParameterOverrides:
          pipelineSettings.cleaner.postCleanerExtraRequestParameters,
      useResponsesApi: useResponsesApi,
    );
  }

  static Future<StudioTurnConfigSnapshot> resolve(
    Ref ref,
    String sessionId,
  ) async {
    final pipelineSettings = ref.read(pipelineSettingsProvider);
    if (!ref.read(studioFeatureEnabledProvider)) {
      return StudioTurnConfigSnapshot(
        config: null,
        preset: null,
        pipelineSettings: pipelineSettings,
        apiConfigs: const [],
        activeApiConfig: ref.read(activeApiConfigProvider),
      );
    }

    await ref.read(apiListProvider.future);
    final apiConfigs = List<ApiConfig>.unmodifiable(
      ref.read(apiListProvider).value ?? const <ApiConfig>[],
    );
    final activeApiConfig = ref.read(activeApiConfigProvider);

    StudioConfig? effectiveConfig;
    StudioPreset? preset;
    final storedConfig = await ref
        .read(studioConfigRepoProvider)
        .getBySessionId(sessionId);
    if (storedConfig?.enabled == true) {
      final presetRepo = ref.read(studioPresetRepoProvider);
      final presetId = await ref.read(activeStudioPresetProvider.future);
      preset =
          (await presetRepo.getById(presetId)) ??
          (await presetRepo.getDefault());
      if (preset != null) {
        final agentEnabled = preset.agentEnabled;
        final beautyPipelineEnabled = preset.blocks.any(
          (block) => block.id == 'beauty_task' && block.enabled,
        );
        final agents = storedConfig!.agents.map((agent) {
          final specId = StudioControllerOntology.specForAgent(agent).id;
          final disableBeauty = specId == 'beauty' && !beautyPipelineEnabled;
          return agentEnabled[specId] == false || disableBeauty
              ? agent.copyWith(enabled: false)
              : agent;
        }).toList();
        final gated =
            StudioActivationGate.applyExecutionMode(
                agents,
                preset.executionMode,
              ).where((agent) => agent.enabled).toList()
              ..sort((a, b) => a.order.compareTo(b.order));
        if (gated.isNotEmpty) {
          effectiveConfig = storedConfig.copyWith(agents: gated);
        }
      }
    }

    return StudioTurnConfigSnapshot(
      config: effectiveConfig,
      preset: preset,
      pipelineSettings: pipelineSettings,
      apiConfigs: apiConfigs,
      activeApiConfig: activeApiConfig,
    );
  }
}
