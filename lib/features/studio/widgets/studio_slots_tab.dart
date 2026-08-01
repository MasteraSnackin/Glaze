import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/api_config.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/studio_default_profile_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
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
  final EdgeInsets padding;

  const StudioSlotsTab({
    super.key,
    required this.controller,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 40),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configs = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    final profile = ref.watch(studioDefaultProfileProvider).value;
    final pipeline = ref.watch(pipelineSettingsProvider);

    return ListView(
      controller: controller,
      padding: padding,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
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

  /// Slot API bindings live on the Studio profile new sessions inherit; the
  /// profile row is created on the first edit, never just by opening the tab.
  Future<void> _saveProfile(
    WidgetRef ref,
    StudioConfig Function(StudioConfig) mutate,
  ) async {
    final repo = ref.read(studioConfigRepoProvider);
    final profile = await repo.ensureDefaultProfile();
    await repo.upsert(
      mutate(profile).copyWith(
        updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    ref.invalidate(studioDefaultProfileProvider);
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.cs.outline),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: context.cs.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              _valueRow(
                context,
                label: 'studio_slot_api'.tr(),
                value: _apiName(configs, apiConfigId),
                muted: apiConfigId.isEmpty,
                onTap: () => _pickApiConfig(
                  context,
                  configs: configs,
                  selectedId: apiConfigId,
                  onSelected: onApiConfigChanged,
                ),
              ),
              _valueRow(
                context,
                label: 'studio_slot_model'.tr(),
                value: model.isEmpty ? 'studio_slot_model_auto'.tr() : model,
                muted: model.isEmpty,
                onTap: () => _editModel(
                  context,
                  title: 'studio_slot_model'.tr(),
                  value: model,
                  onChanged: onModelChanged,
                ),
              ),
              if (extraLabel != null && onExtraChanged != null) ...[
                _valueRow(
                  context,
                  label: extraLabel,
                  value: (extraValue ?? '').isEmpty
                      ? 'studio_slot_model_auto'.tr()
                      : extraValue!,
                  muted: (extraValue ?? '').isEmpty,
                  onTap: () => _editModel(
                    context,
                    title: extraLabel,
                    value: extraValue ?? '',
                    onChanged: onExtraChanged,
                  ),
                ),
                if (extraDescription != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      extraDescription,
                      style: TextStyle(
                        fontSize: 11,
                        color: context.cs.onSurfaceVariant.withValues(
                          alpha: 0.8,
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _valueRow(
    BuildContext context, {
    required String label,
    required String value,
    required bool muted,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: muted
                        ? context.cs.onSurfaceVariant
                        : context.cs.primary,
                  ),
                ),
              ),
              Icon(
                Icons.keyboard_arrow_right_rounded,
                size: 18,
                color: context.cs.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
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
