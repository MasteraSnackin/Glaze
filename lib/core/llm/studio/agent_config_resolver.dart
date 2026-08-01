import '../../models/api_config.dart';
import '../../models/pipeline_settings.dart';
import '../../models/studio_config.dart';
import '../agent_runner.dart' show ResolvedAgentConfig;
import '../studio_api_config_resolver.dart';
import '../studio_controller_ontology.dart';
import '../studio_turn_config_snapshot.dart';
import '../transport/extra_request_parameters.dart';

/// Resolves which API config an agent uses.
///
/// With the 3-slot model (v55):
/// - [apiConfigId] — the explicit Studio API slot. Callers pass
///   `cheapApiConfigId` for trackers,
///   `expensiveApiConfigId` for the final generator, `cleanerApiConfigId`
///   for post-processing agents. An empty slot uses the active chat config.
/// - Model overrides are global PipelineSettings values configured from the
///   Studio menu: studioFinalModelOverride for the final generator,
///   postCleanerModel for post-processing trackers, studioControllerModelOverride
///   for pre-gen trackers. The final generator intentionally does not read
///   PipelineSettings.memoryBookApi.generationModel because that field belongs
///   to MemoryBook draft generation.

class AgentConfigResolver {
  final Future<List<ApiConfig>> Function() _loadApiConfigs;
  final ApiConfig? Function() _readActiveApiConfig;
  final PipelineSettings Function() _readPipelineSettings;

  AgentConfigResolver({
    required this._loadApiConfigs,
    required this._readActiveApiConfig,
    required this._readPipelineSettings,
  });

  Future<ResolvedAgentConfig> resolveAgentConfig(
    StudioAgent agent,
    ApiConfig current,
    String sessionId, {
    bool isFinalResponse = false,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) async {
    final apiConfigs = turnConfig?.apiConfigs ?? await _loadApiConfigs();
    final selectedApiConfigId = apiConfigId ?? '';
    final resolver = StudioApiConfigResolver(
      apiConfigs: apiConfigs,
      activeConfig: turnConfig?.activeApiConfig ?? _readActiveApiConfig(),
    );
    final pipeline = turnConfig?.pipelineSettings ?? _readPipelineSettings();
    if (isFinalResponse) {
      return resolver
          .resolveAgentConfig(
            current,
            selectedApiConfigId,
            pipeline.studioAgent.studioFinalModelOverride,
          )
          .copyWithSampling(
            topP: pipeline.studioAgent.studioFinalTopP,
            topK: pipeline.studioAgent.studioFinalTopK,
            frequencyPenalty: pipeline.studioAgent.studioFinalFrequencyPenalty,
            presencePenalty: pipeline.studioAgent.studioFinalPresencePenalty,
            omitTemperature: pipeline.studioAgent.studioFinalOmitTemperature,
            omitTopP: pipeline.studioAgent.studioFinalOmitTopP,
            extraRequestParameters: mergeExtraRequestParameters(
              resolver
                      .resolveRunConfig(selectedApiConfigId)
                      ?.extraRequestParameters ??
                  const [],
              pipeline.studioAgent.studioFinalExtraRequestParameters,
            ),
          );
    } else if (agent.phase == 'post_processing') {
      // Post Clean and the Ledger share this phase but not their model: the
      // Ledger prefers its own override and only then the cleaner's.
      final ledgerModel = pipeline.ledger.studioLedgerModel;
      final postModel =
          StudioControllerOntology.specForAgent(agent)?.id == 'ledger' &&
              ledgerModel.isNotEmpty
          ? ledgerModel
          : pipeline.cleaner.postCleanerModel;
      if (postModel.isNotEmpty) {
        return resolver
            .resolveAgentConfig(
              current,
              selectedApiConfigId,
              postModel,
            )
            .copyWithSampling(
              topP: pipeline.cleaner.postCleanerTopP,
              topK: pipeline.cleaner.postCleanerTopK,
              frequencyPenalty: pipeline.cleaner.postCleanerFrequencyPenalty,
              presencePenalty: pipeline.cleaner.postCleanerPresencePenalty,
              omitTemperature: pipeline.cleaner.postCleanerOmitTemperature,
              omitTopP: pipeline.cleaner.postCleanerOmitTopP,
              extraRequestParameters: mergeExtraRequestParameters(
                resolver
                        .resolveRunConfig(selectedApiConfigId)
                        ?.extraRequestParameters ??
                    const [],
                pipeline.cleaner.postCleanerExtraRequestParameters,
              ),
            );
      }
      return resolver
          .resolveAgentConfig(current, selectedApiConfigId, '')
          .copyWithSampling(
            topP: pipeline.cleaner.postCleanerTopP,
            topK: pipeline.cleaner.postCleanerTopK,
            frequencyPenalty: pipeline.cleaner.postCleanerFrequencyPenalty,
            presencePenalty: pipeline.cleaner.postCleanerPresencePenalty,
            omitTemperature: pipeline.cleaner.postCleanerOmitTemperature,
            omitTopP: pipeline.cleaner.postCleanerOmitTopP,
            extraRequestParameters: mergeExtraRequestParameters(
              resolver
                      .resolveRunConfig(selectedApiConfigId)
                      ?.extraRequestParameters ??
                  const [],
              pipeline.cleaner.postCleanerExtraRequestParameters,
            ),
          );
    } else if (pipeline.studioAgent.studioControllerModelOverride.isNotEmpty) {
      return resolver
          .resolveAgentConfig(
            current,
            selectedApiConfigId,
            pipeline.studioAgent.studioControllerModelOverride,
          )
          .copyWithSampling(
            topP: pipeline.studioAgent.studioControllerTopP,
            topK: pipeline.studioAgent.studioControllerTopK,
            frequencyPenalty:
                pipeline.studioAgent.studioControllerFrequencyPenalty,
            presencePenalty: pipeline.studioAgent.studioControllerPresencePenalty,
            omitTemperature: pipeline.studioAgent.studioControllerOmitTemperature,
            omitTopP: pipeline.studioAgent.studioControllerOmitTopP,
            extraRequestParameters: mergeExtraRequestParameters(
              resolver
                      .resolveRunConfig(selectedApiConfigId)
                      ?.extraRequestParameters ??
                  const [],
              pipeline.studioAgent.studioControllerExtraRequestParameters,
            ),
          );
    }
    return resolver
        .resolveAgentConfig(current, selectedApiConfigId, '')
        .copyWithSampling(
          topP: pipeline.studioAgent.studioControllerTopP,
          topK: pipeline.studioAgent.studioControllerTopK,
          frequencyPenalty: pipeline.studioAgent.studioControllerFrequencyPenalty,
          presencePenalty: pipeline.studioAgent.studioControllerPresencePenalty,
          omitTemperature: pipeline.studioAgent.studioControllerOmitTemperature,
          omitTopP: pipeline.studioAgent.studioControllerOmitTopP,
          extraRequestParameters: mergeExtraRequestParameters(
            resolver
                    .resolveRunConfig(selectedApiConfigId)
                    ?.extraRequestParameters ??
                const [],
            pipeline.studioAgent.studioControllerExtraRequestParameters,
          ),
        );
  }
}
