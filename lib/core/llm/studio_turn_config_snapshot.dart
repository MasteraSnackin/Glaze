import '../models/api_config.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import 'aux_llm_client.dart';
import 'studio_slot_resolver.dart';

/// Immutable Studio configuration captured once for a chat generation turn.
class StudioTurnConfigSnapshot {
  final StudioConfig? config;
  final StudioPreset? preset;
  final PipelineSettings pipelineSettings;
  final List<ApiConfig> apiConfigs;
  final ApiConfig? activeApiConfig;

  StudioTurnConfigSnapshot({
    required this.config,
    required this.preset,
    required PipelineSettings pipelineSettings,
    required this.apiConfigs,
    required this.activeApiConfig,
  }) : pipelineSettings = config?.enabled == true && preset != null
           ? pipelineSettings.copyWith(
               studioAgent: preset.runtime.agents,
               cleaner: preset.runtime.cleaner,
               ledger: preset.runtime.ledger,
             )
           : pipelineSettings;

  bool get enabled => config != null && preset != null;

  AuxApiConfig resolveCleanerConfig({
    required String errorLabel,
    bool? useResponsesApi,
  }) {
    return StudioSlotResolver.resolve(
      apiConfigs: apiConfigs,
      apiConfigId: preset?.cleanerApiConfigId ?? '',
      fallback: activeApiConfig,
      errorLabel: errorLabel,
      modelOverride: pipelineSettings.cleaner.postCleanerModel,
      extraRequestParameterOverrides:
          pipelineSettings.cleaner.postCleanerExtraRequestParameters,
      useResponsesApi: useResponsesApi,
    );
  }

  /// The Ledger's own API slot, falling back to the post-processing (cleaner)
  /// slot when neither the slot nor the model override is set — which is where
  /// the Ledger ran before it had a slot of its own, so an untouched install
  /// behaves exactly as before.
  AuxApiConfig resolveLedgerConfig({
    required String errorLabel,
    bool? useResponsesApi,
  }) {
    final slotId = config?.ledgerApiConfigId ?? '';
    final model = pipelineSettings.ledger.studioLedgerModel;
    if (slotId.isEmpty && model.isEmpty) {
      return resolveCleanerConfig(
        errorLabel: errorLabel,
        useResponsesApi: useResponsesApi,
      );
    }
    return StudioSlotResolver.resolve(
      apiConfigs: apiConfigs,
      apiConfigId: slotId.isNotEmpty
          ? slotId
          : (config?.cleanerApiConfigId ?? ''),
      fallback: activeApiConfig,
      errorLabel: errorLabel,
      modelOverride: model.isNotEmpty
          ? model
          : pipelineSettings.cleaner.postCleanerModel,
      extraRequestParameterOverrides:
          pipelineSettings.cleaner.postCleanerExtraRequestParameters,
      useResponsesApi: useResponsesApi,
    );
  }
}
