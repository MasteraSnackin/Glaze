import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/api_config.dart';

/// How the API presets sheet is ordered. Mirrors the Presets list's own modes.
///
/// [manual] is the sheet's own order: rows are dragged into place and the
/// resulting sequence is persisted, so switching to another mode and back
/// restores it unchanged. It is the default, and with nothing dragged yet it
/// leaves the repository's order — the one the sheet has always shown —
/// untouched.
enum ApiPresetSortMode { alphabetical, dateAdded, manual }

extension ApiPresetSortModeInfo on ApiPresetSortMode {
  String get wireName => name;

  static ApiPresetSortMode fromWireName(String? value) =>
      ApiPresetSortMode.values.where((m) => m.wireName == value).firstOrNull ??
      ApiPresetSortMode.manual;

  IconData get icon => switch (this) {
    ApiPresetSortMode.alphabetical => Icons.sort_by_alpha_rounded,
    ApiPresetSortMode.dateAdded => Icons.schedule_rounded,
    ApiPresetSortMode.manual => Icons.drag_indicator_rounded,
  };

  String get label => switch (this) {
    ApiPresetSortMode.alphabetical => 'sort_alphabetical'.tr(),
    ApiPresetSortMode.dateAdded => 'sort_date'.tr(),
    ApiPresetSortMode.manual => 'sort_manual'.tr(),
  };

  /// Extra line shown under the option in the sort picker. Only the manual mode
  /// has one — it is the only mode whose behaviour is not obvious from its name.
  String? get hint =>
      this == ApiPresetSortMode.manual ? 'sort_manual_hint'.tr() : null;
}

/// Sort mode plus the manual order, persisted together in SharedPreferences.
class ApiPresetSortState {
  final ApiPresetSortMode mode;

  /// Preset ids in their manual order. Presets absent from the list keep their
  /// incoming order behind the ones listed here.
  final List<String> manualOrder;

  const ApiPresetSortState({
    this.mode = ApiPresetSortMode.manual,
    this.manualOrder = const [],
  });

  ApiPresetSortState copyWith({
    ApiPresetSortMode? mode,
    List<String>? manualOrder,
  }) => ApiPresetSortState(
    mode: mode ?? this.mode,
    manualOrder: manualOrder ?? this.manualOrder,
  );
}

/// Whether the presets sheet has dragging armed, from the chip next to the sort
/// picker. Ephemeral UI state — the sheet arms it while it is open and drops it
/// on close, so a long press means "select" the rest of the time.
final apiPresetReorderArmedProvider = StateProvider<bool>((ref) => false);

const _kSortModeKey = 'apiPresetListSortMode';
const _kManualOrderKey = 'apiPresetListManualOrder';

final apiPresetSortProvider =
    AsyncNotifierProvider<ApiPresetSortNotifier, ApiPresetSortState>(
      ApiPresetSortNotifier.new,
    );

class ApiPresetSortNotifier extends AsyncNotifier<ApiPresetSortState> {
  @override
  Future<ApiPresetSortState> build() async {
    final prefs = await SharedPreferences.getInstance();
    return ApiPresetSortState(
      mode: ApiPresetSortModeInfo.fromWireName(prefs.getString(_kSortModeKey)),
      manualOrder: _decodeOrder(prefs.getString(_kManualOrderKey)),
    );
  }

  static List<String> _decodeOrder(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setMode(ApiPresetSortMode mode) async {
    final current = state.value ?? const ApiPresetSortState();
    if (current.mode == mode) return;
    state = AsyncData(current.copyWith(mode: mode));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSortModeKey, mode.wireName);
  }

  Future<void> setManualOrder(List<String> order) async {
    final current = state.value ?? const ApiPresetSortState();
    state = AsyncData(current.copyWith(manualOrder: order));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kManualOrderKey, jsonEncode(order));
  }
}

/// Text a preset is sorted by: its own name, or the model it talks to when it
/// has none — the same fallback the sheet uses to label the row.
String apiPresetSortName(ApiConfig config) =>
    config.name.isNotEmpty ? config.name : config.model;

/// When the preset was added, for "date added" sorting.
///
/// API presets carry no creation timestamp of their own, but one created in the
/// app gets `DateTime.now().millisecondsSinceEpoch` as its id — so that is its
/// creation time. Presets that arrived through an import bring ids of their own
/// with no stamp to read; they fall behind the timestamped ones, in the order
/// the repository returned them.
int _createdAt(ApiConfig config) => int.tryParse(config.id) ?? 0;

/// Sorts [configs] according to [state], leaving the caller's list untouched.
///
/// Every mode is a stable sort over the incoming order, so presets that compare
/// equal (same name, same stamp, or both missing from the manual order) stay in
/// the order the repository returned them in.
List<ApiConfig> sortApiConfigs(
  List<ApiConfig> configs,
  ApiPresetSortState state,
) {
  final ranks = <String, int>{};
  if (state.mode == ApiPresetSortMode.manual) {
    for (var i = 0; i < state.manualOrder.length; i++) {
      ranks[state.manualOrder[i]] = i;
    }
  }

  // Decorate with the incoming index so the comparator can fall back to it —
  // List.sort is not stable on its own.
  final indexed = [
    for (var i = 0; i < configs.length; i++) (index: i, config: configs[i]),
  ];

  int compare(
    ({int index, ApiConfig config}) a,
    ({int index, ApiConfig config}) b,
  ) {
    final result = switch (state.mode) {
      ApiPresetSortMode.alphabetical => apiPresetSortName(
        a.config,
      ).toLowerCase().compareTo(apiPresetSortName(b.config).toLowerCase()),
      // Newest first, matching "date added" everywhere else in the app.
      ApiPresetSortMode.dateAdded => _createdAt(
        b.config,
      ).compareTo(_createdAt(a.config)),
      ApiPresetSortMode.manual => (ranks[a.config.id] ?? ranks.length).compareTo(
        ranks[b.config.id] ?? ranks.length,
      ),
    };
    return result != 0 ? result : a.index.compareTo(b.index);
  }

  indexed.sort(compare);
  return [for (final e in indexed) e.config];
}
