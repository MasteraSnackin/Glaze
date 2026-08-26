import '../models/api_config.dart';
import 'agent_runner.dart' show ResolvedAgentConfig;
import 'transport/llm_protocol_platform_support.dart';

/// Single home for the studio/agent API-config resolution policies.
///
/// With the Studio unbound from user presets, per-agent model overrides are
/// gone. The 3 API Config slots (expensive/cheap/cleaner) on StudioConfig
/// replace them. This resolver maps a slot id to an [ApiConfig].
class StudioApiConfigResolver {
  final List<ApiConfig> apiConfigs;
  final ApiConfig? activeConfig;

  const StudioApiConfigResolver({required this.apiConfigs, this.activeConfig});

  /// Resolve the [ApiConfig] used to RUN trackers / agents: the studio's
  /// [apiConfigId] if it resolves to a saved config, otherwise the active
  /// chat config. Returns `null` when neither is available.
  ApiConfig? resolveRunConfig(String apiConfigId) {
    if (apiConfigId.isNotEmpty) {
      final byRunId = apiConfigs
          .where((config) => config.id == apiConfigId)
          .firstOrNull;
      if (byRunId != null) {
        return LlmProtocolPlatformSupport.isAvailableOnCurrentPlatform(
              byRunId.protocol,
            )
            ? byRunId
            : null;
      }
    }
    return _availableFallback;
  }

  /// Resolve an [ApiConfig] by its id from the saved list, falling back to
  /// the active chat config. Returns `null` when neither is available.
  ApiConfig? resolveById(String configId) {
    if (configId.isNotEmpty) {
      final match = apiConfigs
          .where((config) => config.id == configId)
          .firstOrNull;
      if (match != null) {
        return LlmProtocolPlatformSupport.isAvailableOnCurrentPlatform(
              match.protocol,
            )
            ? match
            : null;
      }
    }
    return _availableFallback;
  }

  ApiConfig? get _availableFallback {
    final fallback = activeConfig;
    if (fallback == null ||
        !LlmProtocolPlatformSupport.isAvailableOnCurrentPlatform(
          fallback.protocol,
        )) {
      return null;
    }
    return fallback;
  }

  /// Resolve a single agent's full [ResolvedAgentConfig] using the run API
  /// config + optional model override (from PipelineSettings, not per-agent).
  ResolvedAgentConfig resolveAgentConfig(
    ApiConfig current,
    String apiConfigId,
    String modelOverride,
  ) {
    final resolved = resolveRunConfig(apiConfigId);
    if (apiConfigId.isNotEmpty &&
        apiConfigs.any(
          (config) =>
              config.id == apiConfigId &&
              !LlmProtocolPlatformSupport.isAvailableOnCurrentPlatform(
                config.protocol,
              ),
        )) {
      throw StateError(
        'Studio API config "$apiConfigId" is unavailable on this platform.',
      );
    }
    final active = resolved ?? current;
    if (!LlmProtocolPlatformSupport.isAvailableOnCurrentPlatform(
      active.protocol,
    )) {
      throw StateError(
        'Studio API config "${active.id}" is unavailable on this platform.',
      );
    }
    return ResolvedAgentConfig.fromApiConfig(
      active,
      modelOverride: modelOverride,
    );
  }
}
