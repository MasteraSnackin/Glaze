import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/extra_request_parameter.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/extra_request_parameters_editor.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../studio_injection_points.dart';

/// Which Studio model slot is being configured.
enum StudioSlot { finalGenerator, controller, cleaner, ledger }

/// Snapshot of per-slot generation settings captured in the dialog and applied
/// back to [PipelineSettings] via [applyTo].
///
/// The ledger only exposes temperature / max tokens / timeout — it has no
/// sampling or reasoning overrides in [LedgerSettings] — so the ledger dialog
/// branch hides those groups and [applyTo] writes only those three fields.
class StudioSlotSettings {
  final double temperature;
  final double topP;
  final int topK;
  final double frequencyPenalty;
  final double presencePenalty;
  final bool requestReasoning;
  final bool useResponsesApi;
  final String reasoningEffort;
  final bool omitTemperature;
  final bool omitTopP;
  final bool omitReasoning;
  final bool omitReasoningEffort;
  final int reasoningHistoryCount;
  final bool excludeReasoningFromContextBudget;
  final int maxTokens;
  final int timeoutMs;
  final List<ExtraRequestParameter> extraRequestParameters;

  const StudioSlotSettings({
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.frequencyPenalty,
    required this.presencePenalty,
    required this.requestReasoning,
    required this.useResponsesApi,
    required this.reasoningEffort,
    required this.omitTemperature,
    required this.omitTopP,
    required this.omitReasoning,
    required this.omitReasoningEffort,
    this.reasoningHistoryCount = 0,
    this.excludeReasoningFromContextBudget = false,
    required this.maxTokens,
    required this.timeoutMs,
    required this.extraRequestParameters,
  });

  PipelineSettings applyTo(PipelineSettings pipeline, StudioSlot slot) {
    switch (slot) {
      case StudioSlot.finalGenerator:
        return pipeline.copyWith(
          studioAgent: pipeline.studioAgent.copyWith(
            studioFinalTemperature: temperature,
            studioFinalTopP: topP,
            studioFinalTopK: topK,
            studioFinalFrequencyPenalty: frequencyPenalty,
            studioFinalPresencePenalty: presencePenalty,
            studioFinalRequestReasoning: requestReasoning,
            studioFinalUseResponsesApi: useResponsesApi,
            studioFinalReasoningEffort: reasoningEffort,
            studioFinalOmitTemperature: omitTemperature,
            studioFinalOmitTopP: omitTopP,
            studioFinalOmitReasoning: omitReasoning,
            studioFinalOmitReasoningEffort: omitReasoningEffort,
            studioFinalReasoningHistoryCount: reasoningHistoryCount,
            studioFinalExcludeReasoningFromContextBudget:
                excludeReasoningFromContextBudget,
            studioFinalMaxTokens: maxTokens,
            studioFinalTimeoutMs: timeoutMs,
            studioFinalExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.controller:
        return pipeline.copyWith(
          studioAgent: pipeline.studioAgent.copyWith(
            studioControllerTemperature: temperature,
            studioControllerTopP: topP,
            studioControllerTopK: topK,
            studioControllerFrequencyPenalty: frequencyPenalty,
            studioControllerPresencePenalty: presencePenalty,
            studioControllerRequestReasoning: requestReasoning,
            studioControllerUseResponsesApi: useResponsesApi,
            studioControllerReasoningEffort: reasoningEffort,
            studioControllerOmitTemperature: omitTemperature,
            studioControllerOmitTopP: omitTopP,
            studioControllerOmitReasoning: omitReasoning,
            studioControllerOmitReasoningEffort: omitReasoningEffort,
            studioControllerMaxTokens: maxTokens,
            studioControllerTimeoutMs: timeoutMs,
            studioControllerExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.cleaner:
        return pipeline.copyWith(
          cleaner: pipeline.cleaner.copyWith(
            postCleanerTemperature: temperature,
            postCleanerTopP: topP,
            postCleanerTopK: topK,
            postCleanerFrequencyPenalty: frequencyPenalty,
            postCleanerPresencePenalty: presencePenalty,
            postCleanerRequestReasoning: requestReasoning,
            postCleanerUseResponsesApi: useResponsesApi,
            postCleanerReasoningEffort: reasoningEffort,
            postCleanerOmitTemperature: omitTemperature,
            postCleanerOmitTopP: omitTopP,
            postCleanerOmitReasoning: omitReasoning,
            postCleanerOmitReasoningEffort: omitReasoningEffort,
            postCleanerMaxTokens: maxTokens,
            postCleanerTimeoutMs: timeoutMs,
            postCleanerExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.ledger:
        return pipeline.copyWith(
          ledger: pipeline.ledger.copyWith(
            studioLedgerTemperature: temperature,
            studioLedgerMaxTokens: maxTokens,
            studioLedgerTimeoutMs: timeoutMs,
          ),
        );
    }
  }
}

/// Per-slot advanced generation settings (temperature, tokens, timeout,
/// Responses API, reasoning, extra request parameters).
///
/// Presented via [showModalBottomSheet] with [SheetView]; pops a
/// [StudioSlotSettings] the caller applies through the pipeline notifier.
class StudioSlotSettingsDialog extends StatefulWidget {
  final StudioSlot slot;
  final PipelineSettings pipeline;

  const StudioSlotSettingsDialog({
    super.key,
    required this.slot,
    required this.pipeline,
  });

  @override
  State<StudioSlotSettingsDialog> createState() =>
      _StudioSlotSettingsDialogState();
}

class _StudioSlotSettingsDialogState extends State<StudioSlotSettingsDialog> {
  late double _temperature;
  late double _topP;
  late int _topK;
  late double _frequencyPenalty;
  late double _presencePenalty;
  late bool _requestReasoning;
  late bool _useResponsesApi;
  late String _reasoningEffort;
  late bool _omitTemperature;
  late bool _omitTopP;
  late bool _omitReasoning;
  late bool _omitReasoningEffort;
  late bool _excludeReasoningFromContextBudget;
  late TextEditingController _reasoningHistoryCountCtrl;
  late TextEditingController _maxTokensCtrl;
  late TextEditingController _timeoutCtrl;
  late List<ExtraRequestParameter> _extraRequestParameters;

  bool get _isLedger => widget.slot == StudioSlot.ledger;

  @override
  void initState() {
    super.initState();
    final p = widget.pipeline;
    switch (widget.slot) {
      case StudioSlot.finalGenerator:
        final a = p.studioAgent;
        _temperature = a.studioFinalTemperature;
        _topP = a.studioFinalTopP;
        _topK = a.studioFinalTopK;
        _frequencyPenalty = a.studioFinalFrequencyPenalty;
        _presencePenalty = a.studioFinalPresencePenalty;
        _requestReasoning = a.studioFinalRequestReasoning;
        _useResponsesApi = a.studioFinalUseResponsesApi;
        _reasoningEffort = a.studioFinalReasoningEffort;
        _omitTemperature = a.studioFinalOmitTemperature;
        _omitTopP = a.studioFinalOmitTopP;
        _omitReasoning = a.studioFinalOmitReasoning;
        _omitReasoningEffort = a.studioFinalOmitReasoningEffort;
        _excludeReasoningFromContextBudget =
            a.studioFinalExcludeReasoningFromContextBudget;
        _reasoningHistoryCountCtrl = TextEditingController(
          text: '${a.studioFinalReasoningHistoryCount}',
        );
        _maxTokensCtrl = TextEditingController(
          text: a.studioFinalMaxTokens > 0 ? '${a.studioFinalMaxTokens}' : '',
        );
        _timeoutCtrl = TextEditingController(
          text: a.studioFinalTimeoutMs > 0
              ? '${a.studioFinalTimeoutMs ~/ 1000}'
              : '',
        );
        _extraRequestParameters = a.studioFinalExtraRequestParameters;
      case StudioSlot.controller:
        final a = p.studioAgent;
        _temperature = a.studioControllerTemperature;
        _topP = a.studioControllerTopP;
        _topK = a.studioControllerTopK;
        _frequencyPenalty = a.studioControllerFrequencyPenalty;
        _presencePenalty = a.studioControllerPresencePenalty;
        _requestReasoning = a.studioControllerRequestReasoning;
        _useResponsesApi = a.studioControllerUseResponsesApi;
        _reasoningEffort = a.studioControllerReasoningEffort;
        _omitTemperature = a.studioControllerOmitTemperature;
        _omitTopP = a.studioControllerOmitTopP;
        _omitReasoning = a.studioControllerOmitReasoning;
        _omitReasoningEffort = a.studioControllerOmitReasoningEffort;
        _excludeReasoningFromContextBudget = false;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _maxTokensCtrl = TextEditingController(
          text: a.studioControllerMaxTokens > 0
              ? '${a.studioControllerMaxTokens}'
              : '',
        );
        _timeoutCtrl = TextEditingController(
          text: a.studioControllerTimeoutMs > 0
              ? '${a.studioControllerTimeoutMs ~/ 1000}'
              : '',
        );
        _extraRequestParameters = a.studioControllerExtraRequestParameters;
      case StudioSlot.cleaner:
        final c = p.cleaner;
        _temperature = c.postCleanerTemperature;
        _topP = c.postCleanerTopP;
        _topK = c.postCleanerTopK;
        _frequencyPenalty = c.postCleanerFrequencyPenalty;
        _presencePenalty = c.postCleanerPresencePenalty;
        _requestReasoning = c.postCleanerRequestReasoning;
        _useResponsesApi = c.postCleanerUseResponsesApi;
        _reasoningEffort = c.postCleanerReasoningEffort;
        _omitTemperature = c.postCleanerOmitTemperature;
        _omitTopP = c.postCleanerOmitTopP;
        _omitReasoning = c.postCleanerOmitReasoning;
        _omitReasoningEffort = c.postCleanerOmitReasoningEffort;
        _excludeReasoningFromContextBudget = false;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _maxTokensCtrl = TextEditingController(
          text: c.postCleanerMaxTokens > 0 ? '${c.postCleanerMaxTokens}' : '',
        );
        _timeoutCtrl = TextEditingController(
          text: c.postCleanerTimeoutMs > 0
              ? '${c.postCleanerTimeoutMs ~/ 1000}'
              : '',
        );
        _extraRequestParameters = c.postCleanerExtraRequestParameters;
      case StudioSlot.ledger:
        final l = p.ledger;
        // Ledger temperature defaults to -1 (use 0.2); clamp into the 0-2
        // slider range. Saving writes the concrete value.
        _temperature = l.studioLedgerTemperature.clamp(0.0, 2.0);
        _topP = 0.9;
        _topK = 0;
        _frequencyPenalty = 0;
        _presencePenalty = 0;
        _requestReasoning = false;
        _useResponsesApi = false;
        _reasoningEffort = 'auto';
        _omitTemperature = false;
        _omitTopP = false;
        _omitReasoning = true;
        _omitReasoningEffort = true;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _maxTokensCtrl = TextEditingController(
          text: l.studioLedgerMaxTokens > 0 ? '${l.studioLedgerMaxTokens}' : '',
        );
        _timeoutCtrl = TextEditingController(
          text: l.studioLedgerTimeoutMs > 0
              ? '${l.studioLedgerTimeoutMs ~/ 1000}'
              : '',
        );
        _extraRequestParameters = const [];
    }
  }

  @override
  void dispose() {
    _maxTokensCtrl.dispose();
    _timeoutCtrl.dispose();
    _reasoningHistoryCountCtrl.dispose();
    super.dispose();
  }

  String get _slotTitle {
    final String point = switch (widget.slot) {
      StudioSlot.finalGenerator => 'final',
      StudioSlot.controller => 'pregen',
      StudioSlot.cleaner => 'cleaner',
      StudioSlot.ledger => 'ledger',
    };
    return '${studioInjectionPointLabel(point)} ${'studio_slot_settings_title'.tr()}';
  }

  String _reasoningEffortLabel(String effort) => switch (effort) {
    'auto' => 'reasoning_effort_auto'.tr(),
    'min' => 'reasoning_effort_min'.tr(),
    'low' => 'reasoning_effort_low'.tr(),
    'medium' => 'reasoning_effort_medium'.tr(),
    'high' => 'reasoning_effort_high'.tr(),
    'max' => 'reasoning_effort_max'.tr(),
    _ => effort,
  };

  Future<void> _openReasoningEffortSelector() async {
    const options = ['auto', 'min', 'low', 'medium', 'high', 'max'];
    await GlazeBottomSheet.show<void>(
      context,
      title: 'label_reasoning_effort'.tr(),
      items: options.map((option) {
        final active = option == _reasoningEffort;
        return BottomSheetItem(
          label: _reasoningEffortLabel(option),
          icon: active ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => _reasoningEffort = option);
          },
        );
      }).toList(),
    );
  }

  void _save() {
    final maxTokens = int.tryParse(_maxTokensCtrl.text.trim()) ?? 0;
    final reasoningHistoryCount =
        int.tryParse(_reasoningHistoryCountCtrl.text.trim()) ?? 0;
    final seconds = int.tryParse(_timeoutCtrl.text.trim()) ?? 0;
    final timeoutMs = seconds > 0 ? seconds * 1000 : 0;
    Navigator.of(context, rootNavigator: true).pop(
      StudioSlotSettings(
        temperature: _temperature,
        topP: _topP,
        topK: _topK,
        frequencyPenalty: _frequencyPenalty,
        presencePenalty: _presencePenalty,
        requestReasoning: _requestReasoning,
        useResponsesApi: _useResponsesApi,
        reasoningEffort: _reasoningEffort,
        omitTemperature: _omitTemperature,
        omitTopP: _omitTopP,
        omitReasoning: _omitReasoning,
        omitReasoningEffort: _omitReasoningEffort,
        reasoningHistoryCount: reasoningHistoryCount < -1
            ? 0
            : reasoningHistoryCount,
        excludeReasoningFromContextBudget: _excludeReasoningFromContextBudget,
        maxTokens: maxTokens,
        timeoutMs: timeoutMs,
        extraRequestParameters: _extraRequestParameters,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: _slotTitle,
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check, size: 22),
          tooltip: 'studio_slot_settings_save'.tr(),
          onPressed: _save,
        ),
      ],
      body: ListView(
        children: [
          const SizedBox(height: 8),
          MenuGroup(
            compact: true,
            header: 'studio_slot_settings_generation'.tr(),
            items: [
              MenuRangeItem(
                label: 'studio_slot_settings_temperature'.tr(),
                value: _temperature,
                min: 0,
                max: 2,
                divisions: 200,
                editableValue: true,
                included: !_omitTemperature,
                onIncludedChanged: (v) => setState(() => _omitTemperature = !v),
                onChanged: (v) => setState(() => _temperature = v),
              ),
              if (!_isLedger) ...[
                MenuRangeItem(
                  label: 'studio_slot_settings_top_p'.tr(),
                  value: _topP,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  editableValue: true,
                  included: !_omitTopP,
                  onIncludedChanged: (v) => setState(() => _omitTopP = !v),
                  onChanged: (v) => setState(() => _topP = v),
                ),
                MenuRangeItem(
                  label: 'studio_slot_settings_top_k'.tr(),
                  value: _topK.toDouble(),
                  min: 0,
                  max: 200,
                  divisions: 200,
                  editableValue: true,
                  decimalPlaces: 0,
                  onChanged: (v) => setState(() => _topK = v.round()),
                ),
                MenuRangeItem(
                  label: 'studio_slot_settings_frequency_penalty'.tr(),
                  value: _frequencyPenalty,
                  min: -2,
                  max: 2,
                  divisions: 80,
                  editableValue: true,
                  onChanged: (v) => setState(() => _frequencyPenalty = v),
                ),
                MenuRangeItem(
                  label: 'studio_slot_settings_presence_penalty'.tr(),
                  value: _presencePenalty,
                  min: -2,
                  max: 2,
                  divisions: 80,
                  editableValue: true,
                  onChanged: (v) => setState(() => _presencePenalty = v),
                ),
              ],
              MenuFieldItem(
                label: 'studio_slot_settings_max_tokens'.tr(),
                controller: _maxTokensCtrl,
                placeholder: '0',
                keyboardType: TextInputType.number,
              ),
              MenuFieldItem(
                label: 'studio_slot_settings_timeout'.tr(),
                controller: _timeoutCtrl,
                placeholder: '0',
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          if (!_isLedger) ...[
            ExtraRequestParametersEditor(
              parameters: _extraRequestParameters,
              title: 'extra_request_parameters'.tr(),
              description: 'extra_request_parameters_studio_desc'.tr(),
              keyLabel: 'extra_request_parameter_key'.tr(),
              valueLabel: 'extra_request_parameter_value'.tr(),
              addLabel: 'extra_request_parameter_add'.tr(),
              onChanged: (parameters) {
                _extraRequestParameters = parameters;
              },
            ),
            const SizedBox(height: 8),
            MenuGroup(
              compact: true,
              header: 'studio_slot_settings_reasoning'.tr(),
              items: [
                MenuSwitchItem(
                  label: 'label_use_responses_api'.tr(),
                  description: 'desc_use_responses_api'.tr(),
                  value: _useResponsesApi,
                  onChanged: (value) =>
                      setState(() => _useResponsesApi = value),
                ),
                MenuSwitchItem(
                  label: 'studio_slot_settings_request_reasoning'.tr(),
                  description: 'studio_slot_settings_request_reasoning_desc'
                      .tr(),
                  included: !_omitReasoning,
                  onIncludedChanged: (v) => setState(() => _omitReasoning = !v),
                  value: _requestReasoning,
                  onChanged: (v) => setState(() => _requestReasoning = v),
                ),
                MenuSelectorItem(
                  label: 'label_reasoning_effort'.tr(),
                  currentValue: _reasoningEffortLabel(_reasoningEffort),
                  included: !_omitReasoningEffort,
                  onIncludedChanged: (v) =>
                      setState(() => _omitReasoningEffort = !v),
                  onTap: _openReasoningEffortSelector,
                ),
                if (widget.slot == StudioSlot.finalGenerator)
                  MenuFieldItem(
                    label: 'studio_slot_settings_reasoning_history_count'.tr(),
                    controller: _reasoningHistoryCountCtrl,
                    placeholder: '0',
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                  ),
                if (widget.slot == StudioSlot.finalGenerator)
                  MenuSwitchItem(
                    label: 'label_exclude_reasoning_from_budget'.tr(),
                    description: 'desc_exclude_reasoning_from_budget'.tr(),
                    value: _excludeReasoningFromContextBudget,
                    onChanged: (v) =>
                        setState(() => _excludeReasoningFromContextBudget = v),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _save,
            child: Text('studio_slot_settings_save'.tr()),
          ),
        ],
      ),
    );
  }
}
