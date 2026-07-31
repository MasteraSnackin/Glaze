import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/api_list_provider.dart';
import '../llm/card_rewrite_slot_resolver.dart';
import '../models/api_config.dart';
import '../services/card_rewriter/manual_rewrite_service.dart';
import 'db_provider.dart';

/// Phase-4B writer lane: the manual card-rewrite LLM orchestration service.
///
/// Wired here (not in `db_provider.dart`) because model resolution reads
/// `apiListProvider`, which itself imports `db_provider.dart`.
///
/// The rewrite model slot has no persisted setting yet (dedicated settings UI
/// is a later, designer-owned phase): by default the resolver receives an
/// empty slot id and fails explicitly, surfacing the durable job failure
/// `rewriteModelNotConfigured` — there is NO silent fallback to the active
/// chat config. Until then the slot can be wired localization-free via build
/// defines (an existing wiring mechanism in this codebase, e.g. `APP_VERSION`
/// / `buildChannel`): `--dart-define=GLAZE_CARD_REWRITE_API_CONFIG_ID=<id>`
/// plus optionally `--dart-define=GLAZE_CARD_REWRITE_MODEL=<model>`.
final manualRewriteServiceProvider = Provider<ManualRewriteService>((ref) {
  final service = ManualRewriteService(
    db: ref.watch(appDbProvider),
    jobRepo: ref.watch(manualRewriteJobRepoProvider),
    characterRepo: ref.watch(characterRepoProvider),
    canonLoader: ref.watch(effectiveCanonContextLoaderProvider),
    resolveModel: () async {
      await ref.read(apiListProvider.future);
      final apiConfigs =
          ref.read(apiListProvider).value ?? const <ApiConfig>[];
      return CardRewriteSlotResolver.resolve(
        apiConfigs: apiConfigs,
        apiConfigId: const String.fromEnvironment(
          'GLAZE_CARD_REWRITE_API_CONFIG_ID',
        ),
        modelOverride: const String.fromEnvironment(
          'GLAZE_CARD_REWRITE_MODEL',
        ),
      );
    },
  );
  ref.onDispose(service.dispose);
  return service;
});
