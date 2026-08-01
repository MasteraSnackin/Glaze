import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/api_config.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../settings/api_list_provider.dart';
import '../studio_injection_points.dart';

/// The "Agents" tab of the API settings sheet: which API connection and which
/// model each Studio stage runs on.
///
/// Slots mirror the pipeline stages one-to-one, so they carry the same labels
/// as the agentic preset editor's sections. Everything is optional — an empty
/// slot falls back to the chat's own connection, which is the behaviour an
/// untouched install already has.
class StudioSlotsTab extends ConsumerWidget {
  final ScrollController controller;

  const StudioSlotsTab({super.key, required this.controller});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configs = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    final profile = ref.watch(studioPresetProvider).value;
    final pipeline = ref.watch(pipelineSettingsProvider);

    return ListView(
      controller: controller,
      // The sheet injects the header height into padding.top and the nav bar's
      // into padding.bottom, so the list clears both — same as the other tabs.
      // Horizontal insets come from MenuGroup itself.
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 12,
        bottom: MediaQuery.paddingOf(context).bottom + 16,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'studio_slots_hint'.tr(),
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
        ),
        _slot(
          context,
          configs: configs,
          title: studioInjectionPointLabel('pregen'),
          description: 'studio_slot_pregen_desc'.tr(),
          apiConfigId: profile?.cheapApiConfigId ?? '',
          onApiConfigChanged: (id) =>
              _saveProfile(ref, (c) => c.copyWith(cheapApiConfigId: id)),
          model: pipeline.studioAgent.studioControllerModelOverride,
          onModelChanged: (value) => _savePipeline(
            ref,
            (p) => p.copyWith(
              studioAgent: p.studioAgent.copyWith(
                studioControllerModelOverride: value,
              ),
            ),
          ),
        ),
        _slot(
          context,
          configs: configs,
          title: studioInjectionPointLabel('final'),
          description: 'studio_slot_final_desc'.tr(),
          apiConfigId: profile?.expensiveApiConfigId ?? '',
          onApiConfigChanged: (id) =>
              _saveProfile(ref, (c) => c.copyWith(expensiveApiConfigId: id)),
          model: pipeline.studioAgent.studioFinalModelOverride,
          onModelChanged: (value) => _savePipeline(
            ref,
            (p) => p.copyWith(
              studioAgent: p.studioAgent.copyWith(
                studioFinalModelOverride: value,
              ),
            ),
          ),
        ),
        _slot(
          context,
          configs: configs,
          title: studioInjectionPointLabel('cleaner'),
          description: 'studio_slot_cleaner_desc'.tr(),
          apiConfigId: profile?.cleanerApiConfigId ?? '',
          onApiConfigChanged: (id) =>
              _saveProfile(ref, (c) => c.copyWith(cleanerApiConfigId: id)),
          model: pipeline.cleaner.postCleanerModel,
          onModelChanged: (value) => _savePipeline(
            ref,
            (p) => p.copyWith(
              cleaner: p.cleaner.copyWith(postCleanerModel: value),
            ),
          ),
          // The audit pass runs before the rewrite and can use a cheaper model.
          extraLabel: 'studio_slot_audit_model'.tr(),
          extraDescription: 'studio_slot_audit_model_desc'.tr(),
          extraValue: pipeline.cleaner.postCleanerAuditModel,
          onExtraChanged: (value) => _savePipeline(
            ref,
            (p) => p.copyWith(
              cleaner: p.cleaner.copyWith(postCleanerAuditModel: value),
            ),
          ),
        ),
        _slot(
          context,
          configs: configs,
          title: studioInjectionPointLabel('ledger'),
          description: 'studio_slot_ledger_desc'.tr(),
          apiConfigId: profile?.ledgerApiConfigId ?? '',
          onApiConfigChanged: (id) =>
              _saveProfile(ref, (c) => c.copyWith(ledgerApiConfigId: id)),
          model: pipeline.ledger.studioLedgerModel,
          onModelChanged: (value) => _savePipeline(
            ref,
            (p) => p.copyWith(
              ledger: p.ledger.copyWith(studioLedgerModel: value),
            ),
          ),
        ),
      ],
    );
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Slot API bindings live on the default Studio preset new sessions inherit;
  /// the preset row is seeded on the first edit, never just by opening the tab.
  Future<void> _saveProfile(
    WidgetRef ref,
    StudioPreset Function(StudioPreset) mutate,
  ) async {
    final repo = ref.read(studioPresetRepoProvider);
    final preset = await repo.ensureDefaultSeeded();
    await repo.upsert(
      mutate(preset).copyWith(
        updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    ref.invalidate(studioPresetProvider);
  }

  /// Model overrides are global app settings, not per-profile.
  Future<void> _savePipeline(
    WidgetRef ref,
    PipelineSettings Function(PipelineSettings) mutate,
  ) {
    final pipeline = ref.read(pipelineSettingsProvider);
    return ref.read(pipelineSettingsProvider.notifier).save(mutate(pipeline));
  }

  // ── Rows ───────────────────────────────────────────────────────────────────

  /// One stage = one settings group: the stage name as its header, its blurb
  /// as the description, and a row per thing you can point at a provider.
  Widget _slot(
    BuildContext context, {
    required List<ApiConfig> configs,
    required String title,
    required String description,
    required String apiConfigId,
    required ValueChanged<String> onApiConfigChanged,
    required String model,
    required ValueChanged<String> onModelChanged,
    String? extraLabel,
    String? extraDescription,
    String? extraValue,
    ValueChanged<String>? onExtraChanged,
  }) {
    return MenuGroup(
      header: title,
      description: description,
      items: [
        MenuItem(
          label: 'studio_slot_api'.tr(),
          value: _apiName(configs, apiConfigId),
          onTap: () => _pickApiConfig(
            context,
            configs: configs,
            selectedId: apiConfigId,
            onSelected: onApiConfigChanged,
          ),
        ),
        MenuItem(
          label: 'studio_slot_model'.tr(),
          value: model.isEmpty ? 'studio_slot_model_auto'.tr() : model,
          onTap: () => _editModel(
            context,
            title: 'studio_slot_model'.tr(),
            value: model,
            onChanged: onModelChanged,
          ),
        ),
        if (extraLabel != null && onExtraChanged != null)
          MenuItem(
            label: extraLabel,
            subtitle: extraDescription,
            value: (extraValue ?? '').isEmpty
                ? 'studio_slot_model_auto'.tr()
                : extraValue!,
            onTap: () => _editModel(
              context,
              title: extraLabel,
              value: extraValue ?? '',
              onChanged: onExtraChanged,
            ),
          ),
      ],
    );
  }

  String _apiName(List<ApiConfig> configs, String id) {
    if (id.isEmpty) return 'studio_slot_use_chat_api'.tr();
    final config = configs.where((c) => c.id == id).firstOrNull;
    if (config == null) return 'unnamed_entry'.tr();
    if (config.name.isNotEmpty) return config.name;
    if (config.model.isNotEmpty) return config.model;
    return 'unnamed_entry'.tr();
  }

  void _pickApiConfig(
    BuildContext context, {
    required List<ApiConfig> configs,
    required String selectedId,
    required ValueChanged<String> onSelected,
  }) {
    BottomSheetItem radio(String id, String label) => BottomSheetItem(
      label: label,
      icon: selectedId == id
          ? Icons.radio_button_checked
          : Icons.radio_button_off,
      iconColor: selectedId == id
          ? context.cs.primary
          : context.cs.onSurfaceVariant,
      onTap: () {
        Navigator.of(context, rootNavigator: true).pop();
        onSelected(id);
      },
    );

    GlazeBottomSheet.show<void>(
      context,
      title: 'studio_slot_api'.tr(),
      items: [
        radio('', 'studio_slot_use_chat_api'.tr()),
        for (final config in configs)
          radio(
            config.id,
            config.name.isNotEmpty
                ? config.name
                : (config.model.isNotEmpty
                      ? config.model
                      : 'unnamed_entry'.tr()),
          ),
      ],
    );
  }

  void _editModel(
    BuildContext context, {
    required String title,
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    GlazeBottomSheet.show<void>(
      context,
      title: title,
      input: BottomSheetInput(
        placeholder: 'studio_slot_model_hint'.tr(),
        value: value,
        onConfirm: (next) {
          Navigator.of(context, rootNavigator: true).pop();
          onChanged(next.trim());
        },
      ),
    );
  }
}
