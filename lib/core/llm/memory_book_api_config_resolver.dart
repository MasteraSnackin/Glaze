import '../models/api_config.dart';
import '../models/memory_book_api_settings.dart';
import 'transport/llm_protocol_platform_support.dart';

/// Resolves the saved connection used by Memory Book draft generation without
/// changing the chat's globally active connection.
class MemoryBookApiConfigResolver {
  final List<ApiConfig> apiConfigs;
  final ApiConfig? activeConfig;

  const MemoryBookApiConfigResolver({
    required this.apiConfigs,
    this.activeConfig,
  });

  ApiConfig? resolve(MemoryBookApiSettings settings) {
    if (settings.apiConfigId.isNotEmpty) {
      final selected = apiConfigs
          .where((config) => config.id == settings.apiConfigId)
          .firstOrNull;
      if (selected != null) {
        return LlmProtocolPlatformSupport.isAvailableOnCurrentPlatform(
              selected.protocol,
            )
            ? selected
            : null;
      }
    }
    final fallback = activeConfig;
    if (fallback == null ||
        !LlmProtocolPlatformSupport.isAvailableOnCurrentPlatform(
          fallback.protocol,
        )) {
      return null;
    }
    return fallback;
  }
}
