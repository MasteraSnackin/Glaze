import '../models/api_config.dart';
import '../models/memory_book_api_settings.dart';

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
      if (selected != null) return selected;
    }
    return activeConfig;
  }
}
