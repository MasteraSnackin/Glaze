import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/context_calculator.dart';
import '../../../core/llm/lorebook_activation.dart';
import '../../../core/llm/prompt_isolate.dart';
import '../providers/prompt_build_providers.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/models/persona.dart';
import '../../../core/models/preset.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/preset_resolution.dart';
import '../../../core/state/summary_providers.dart';
import '../../../core/state/studio_feature_provider.dart';
import '../../extensions/providers/extension_presets_provider.dart';
import '../../extensions/providers/extensions_settings_provider.dart';
import '../../image_gen/image_gen_provider.dart';
import '../../settings/api_list_provider.dart';
import '../chat_provider.dart';
import '../state/cached_token_breakdown.dart';
import '../state/token_breakdown_cache.dart';
import '../widgets/magic_drawer_models.dart';

class MagicDrawerStatsService {
  final WidgetRef _ref;

  MagicDrawerStatsService(this._ref);

  bool _isCalculating = false;
  bool _pendingRecalc = false;
  String? _pendingCharId;
  MagicDrawerStats? _pendingBase;

  /// Awaits [future], swallowing failures into `null` so one broken read
  /// cannot take down the whole parallel batch in [computeStats].
  Future<T?> _guarded<T>(Future<T> future, String label) async {
    try {
      return await future;
    } catch (e) {
      debugPrint('[MagicDrawer] $label error: $e');
      return null;
    }
  }

  Future<String?> _resolveStudioPresetName() async {
    final studioPreset = await _ref
        .read(studioPresetRepoProvider)
        .getById(await _ref.read(activeStudioPresetProvider.future));
    return studioPreset?.name;
  }

  Future<MagicDrawerStats> computeStats(String charId) async {
    final chatState = _ref.read(chatProvider(charId)).value;
    final session = chatState?.session;
    final sessionId = session?.id;
    final charRepo = _ref.read(characterRepoProvider);
    final presetRepo = _ref.read(presetRepoProvider);
    final personaRepo = _ref.read(personaRepoProvider);
    final lorebookRepo = _ref.read(lorebookRepoProvider);
    final memoryRepo = _ref.read(memoryBookRepoProvider);
    final chatRepo = _ref.read(chatRepoProvider);
    final summaryService = _ref.read(summaryServiceProvider);
    final activePersonaId = _ref.read(activePersonaIdProvider);
    final chatApi = _ref.read(activeApiConfigProvider);
    final imageGenEnabled =
        _ref.read(imageGenSettingsProvider).value?.enabled == true;
    final extSettings = _ref.read(extensionsSettingsProvider);
    final extPresets = _ref.read(extensionPresetsProvider);
    final cached = _ref.read(cachedTokenBreakdownProvider(charId));
    final activations = _ref.read(lorebookActivationsProvider);

    // Every read below is independent, so all of them are started before the
    // first await. Awaiting them one at a time serialised a dozen DB
    // round-trips and is what kept the drawer behind its spinner on open.
    final characterFuture = _guarded(charRepo.getById(charId), 'character');
    final presetsFuture = _guarded(presetRepo.getAll(), 'presets');
    final personasFuture = _guarded(personaRepo.getAll(), 'personas');
    final lorebooksFuture = _guarded(lorebookRepo.getAll(), 'lorebooks');
    final apiListFuture = _guarded(
      _ref.read(apiListProvider.future),
      'apiList',
    );
    final regexesFuture = _guarded(
      _ref.read(activeRegexesProvider.future),
      'activeRegexesProvider',
    );
    final studioNameFuture = _ref.read(studioFeatureEnabledProvider)
        ? _guarded(_resolveStudioPresetName(), 'active Studio preset')
        : null;
    final summaryFuture = sessionId == null
        ? null
        : _guarded(summaryService.getSummary(sessionId), 'summary');
    final memoryFuture = sessionId == null
        ? null
        : _guarded(memoryRepo.getBySessionId(sessionId), 'memory book');
    // Session count comes from a SQL COUNT — the old
    // `getByCharacterId(charId).length` decoded every message of every
    // session of this character just to read the list length.
    final sessionCountFuture = sessionId == null
        ? null
        : _guarded(chatRepo.countByCharacterId(charId), 'session count');

    await apiListFuture;
    final character = await characterFuture;
    final presets = await presetsFuture ?? const <Preset>[];
    final personas = await personasFuture ?? const <Persona>[];
    final lorebooks = await lorebooksFuture ?? const <Lorebook>[];
    final regexes = await regexesFuture ?? const <PresetRegex>[];

    final activePreset = getEffectivePreset(
      presets,
      charId,
      sessionId,
      _ref.read(activePresetIdProvider),
      _ref.read(presetConnectionsProvider),
    );
    final studioName = studioNameFuture == null
        ? null
        : await studioNameFuture;
    final activePresetDisplayName = studioName ?? activePreset?.name;

    final activePersona = activePersonaId != null
        ? personas.where((p) => p.id == activePersonaId).firstOrNull
        : personas.firstOrNull;

    final summaryContent = summaryFuture == null ? null : await summaryFuture;
    final summaryChars = summaryContent?.length ?? 0;
    final memoryBook = memoryFuture == null ? null : await memoryFuture;
    final memoryEntries = memoryBook?.entries.length ?? 0;
    final sessionCount = sessionCountFuture == null
        ? 0
        : await sessionCountFuture ?? 0;
    final messageCount = session?.messages.length ?? 0;

    final extActivePresetName = extSettings.activePresetId == null
        ? null
        : extPresets
              .where((p) => p.id == extSettings.activePresetId)
              .firstOrNull
              ?.name;

    final approxHistoryTokens = session != null
        ? session.messages
              .where((m) => !m.isHidden && !m.isTyping)
              .fold<int>(0, (sum, m) => sum + (m.content.length / 4).round())
        : 0;

    // Enabled entries across every lorebook active for this character/chat —
    // the same activation rules generation uses. The card used to show
    // `triggeredLorebooks` of the last message instead, which is the number of
    // *books* that fired on one message, not the entries available to the chat.
    final lorebookEntryCount = activeLorebookEntryCount(
      lorebooks: lorebooks,
      charId: charId,
      charWorld: character?.world,
      chatId: sessionId,
      activations: activations,
    );

    return MagicDrawerStats(
      character: character,
      activePreset: activePreset,
      activePresetDisplayName: activePresetDisplayName,
      activePersona: activePersona,
      apiConfig: chatApi,
      session: session,
      sessionCount: sessionCount,
      messageCount: messageCount,
      lorebookEntryCount: lorebookEntryCount,
      memoryEntryCount: memoryEntries,
      regexCount: regexes.length,
      summaryChars: summaryChars,
      promptTokens: cached?.totalTokens ?? 0,
      approximateHistoryTokens: approxHistoryTokens,
      contextSize: chatApi?.contextSize ?? 0,
      characterTokens: (cached?.sourceTokens['description'] ?? 0) > 0
          ? cached!.sourceTokens['description']!
          : (cached?.macroTokens['description'] ?? 0),
      presetTokens: cached?.presetNetTokens ?? 0,
      personaTokens: (cached?.sourceTokens['persona'] ?? 0) > 0
          ? cached!.sourceTokens['persona']!
          : (cached?.macroTokens['persona'] ?? 0),
      summaryTokens: (cached?.sourceTokens['summary'] ?? 0) > 0
          ? cached!.sourceTokens['summary']!
          : (cached?.macroTokens['summary'] ?? 0),
      vectorLoreTokens: cached?.vectorLoreTokens ?? 0,
      keywordLoreTokens:
          ((cached?.sourceTokens['lorebook'] ?? 0) +
          (cached?.macroTokens['lorebooks'] ?? 0)),
      imageGenEnabled: imageGenEnabled,
      summaryContent: summaryContent,
      extBlocksEnabled: extSettings.enabled,
      extBlocksActivePresetName: extActivePresetName,
    );
  }

  Future<MagicDrawerStats> computeTokenStats(
    String charId,
    MagicDrawerStats base,
  ) async {
    final session = base.session;
    final character = base.character;
    final chatApi = base.apiConfig;

    if (session == null || character == null || chatApi == null) return base;

    if (_isCalculating) {
      _pendingRecalc = true;
      _pendingCharId = charId;
      _pendingBase = base;
      return base;
    }

    _isCalculating = true;
    try {
      final visibleCount = session.messages.where((m) => !m.isHidden).length;
      final hash = TokenBreakdownCache.computeHash(
        charId: charId,
        sessionId: session.id,
        messageCount: visibleCount,
        contextSize: chatApi.contextSize,
        maxTokens: chatApi.maxTokens,
        authorsNote: session.authorsNote?.content ?? '',
        summary: base.summaryContent ?? '',
      );

      final cached = TokenBreakdownCache.get(hash);
      if (cached != null) {
        _ref.read(cachedTokenBreakdownProvider(charId).notifier).state = cached;
        return base.copyWith(
          promptTokens: cached.totalTokens,
          characterTokens: (cached.sourceTokens['description'] ?? 0) > 0
              ? cached.sourceTokens['description']!
              : (cached.macroTokens['description'] ?? 0),
          presetTokens: cached.presetNetTokens,
          personaTokens: (cached.sourceTokens['persona'] ?? 0) > 0
              ? cached.sourceTokens['persona']!
              : (cached.macroTokens['persona'] ?? 0),
          summaryTokens: (cached.sourceTokens['summary'] ?? 0) > 0
              ? cached.sourceTokens['summary']!
              : (cached.macroTokens['summary'] ?? 0),
          vectorLoreTokens: cached.vectorLoreTokens,
          keywordLoreTokens:
              (cached.sourceTokens['lorebook'] ?? 0) +
              (cached.macroTokens['lorebooks'] ?? 0),
        );
      }

      final builder = _ref.read(promptPayloadBuilderProvider);
      final inputs = await builder.collectInputs(
        charId: charId,
        session: session,
      );
      final result = await buildFromInputsInIsolate(inputs);
      var breakdown = result.breakdown;

      final lastVectorTokens = _ref.read(lastVectorLoreTokensProvider(charId));
      if (lastVectorTokens > 0 && breakdown.vectorLoreTokens == 0) {
        final newSources = Map<String, int>.from(breakdown.sourceTokens)
          ..['vectorLore'] = lastVectorTokens;
        breakdown = TokenBreakdown(
          sourceTokens: newSources,
          macroTokens: breakdown.macroTokens,
          staticTotal: breakdown.staticTotal,
          historyBudget: breakdown.historyBudget,
          historyTokens: breakdown.historyTokens,
          totalTokens: breakdown.totalTokens + lastVectorTokens,
          cutoffIndex: breakdown.cutoffIndex,
          trimmedHistory: breakdown.trimmedHistory,
          lorebookReserveTokens: breakdown.lorebookReserveTokens,
          memoryTokens: breakdown.memoryTokens,
          vectorLoreTokens: lastVectorTokens,
          fixedTotal: breakdown.fixedTotal + lastVectorTokens,
          remaining: breakdown.remaining - lastVectorTokens,
        );
      }

      final sourceTokens = breakdown.sourceTokens;

      TokenBreakdownCache.set(hash, breakdown);
      _ref.read(cachedTokenBreakdownProvider(charId).notifier).state =
          breakdown;

      return base.copyWith(
        promptTokens: breakdown.totalTokens,
        characterTokens: (sourceTokens['description'] ?? 0) > 0
            ? sourceTokens['description']!
            : (breakdown.macroTokens['description'] ?? 0),
        presetTokens: breakdown.presetNetTokens,
        personaTokens: (sourceTokens['persona'] ?? 0) > 0
            ? sourceTokens['persona']!
            : (breakdown.macroTokens['persona'] ?? 0),
        summaryTokens: (sourceTokens['summary'] ?? 0) > 0
            ? sourceTokens['summary']!
            : (breakdown.macroTokens['summary'] ?? 0),
        vectorLoreTokens: breakdown.vectorLoreTokens,
        keywordLoreTokens:
            (sourceTokens['lorebook'] ?? 0) +
            (breakdown.macroTokens['lorebooks'] ?? 0),
      );
    } catch (e) {
      debugPrint('[MagicDrawer] computeTokenStats error: $e');
      return base;
    } finally {
      _isCalculating = false;
      if (_pendingRecalc) {
        _pendingRecalc = false;
        final cId = _pendingCharId;
        final b = _pendingBase;
        _pendingCharId = null;
        _pendingBase = null;
        if (cId != null && b != null) {
          unawaited(computeTokenStats(cId, b));
        }
      }
    }
  }
}
