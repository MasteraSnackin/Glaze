import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/llm/transport/llm_protocol_platform_support.dart';
import '../../core/models/api_config.dart';
import '../../core/llm/embedding_request_gate.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../core/utils/sync_deletion_tracker.dart';

final activeApiPresetIdProvider = StateProvider<String?>((ref) => null);

final _activeIdInitializedProvider = Provider<bool>((ref) => false);

/// Resolves a saved selection without allowing a desktop-only protocol to
/// become active on an unsupported platform.
///
/// Persisted configs remain in [configs] so sync and backups are lossless. The
/// availability predicate is injectable to keep the selection policy directly
/// testable without pretending the test host is another operating system.
ApiConfig? resolveAvailableApiConfig(
  List<ApiConfig> configs,
  String? selectedId, {
  bool Function(String protocol)? isProtocolAvailable,
}) {
  final isAvailable =
      isProtocolAvailable ??
      LlmProtocolPlatformSupport.isAvailableOnCurrentPlatform;
  final available = configs
      .where((config) => isAvailable(config.protocol))
      .toList(growable: false);
  if (available.isEmpty) return null;
  if (selectedId == null) return available.first;
  final selected = configs
      .where((config) => config.id == selectedId)
      .firstOrNull;
  if (selected == null) return available.first;
  return isAvailable(selected.protocol) ? selected : null;
}

final activeApiConfigProvider = Provider<ApiConfig?>((ref) {
  final list = ref.watch(apiListProvider).value;
  final id = ref.watch(activeApiPresetIdProvider);
  if (list == null || list.isEmpty) return null;
  return resolveAvailableApiConfig(list, id);
});

final apiListProvider = AsyncNotifierProvider<ApiListNotifier, List<ApiConfig>>(
  ApiListNotifier.new,
);

class ApiListNotifier extends AsyncNotifier<List<ApiConfig>> {
  @override
  Future<List<ApiConfig>> build() async {
    final configs = await ref.watch(apiConfigRepoProvider).getAll();
    final initialized = ref.read(_activeIdInitializedProvider);
    if (!initialized) {
      final prefs = await ref.read(sharedPreferencesProvider.future);
      final savedId = prefs.getString('activeApiConfigId');
      if (savedId != null) {
        final resolved = resolveAvailableApiConfig(configs, savedId);
        final savedConfigStillExists = configs.any(
          (config) => config.id == savedId,
        );
        // Keep an unavailable desktop-only selection selected so the active
        // provider remains null. Replacing it with an unrelated HTTP provider
        // could send a prompt to, and incur charges from, the wrong service.
        ref.read(activeApiPresetIdProvider.notifier).state =
            resolved?.id ?? (savedConfigStillExists ? savedId : null);
      }
    }
    return configs;
  }

  Future<void> put(ApiConfig config) async {
    await ref.read(apiConfigRepoProvider).put(config);
    ref.invalidateSelf();
  }

  void setEmbeddingEnabled(String id, bool enabled) {
    EmbeddingRequestGate.setEnabled(enabled);
    final configs = state.value;
    if (configs == null) return;
    state = AsyncData([
      for (final config in configs)
        if (config.id == id)
          config.copyWith(embeddingEnabled: enabled)
        else
          config,
    ]);
  }

  Future<void> remove(String id) async {
    await ref.read(apiConfigRepoProvider).delete(id);
    await SyncDeletionTracker.record('api_presets', id);
    ref.invalidateSelf();
  }
}
