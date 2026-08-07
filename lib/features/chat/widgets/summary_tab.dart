import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/summary_service.dart';
import '../../../core/models/preset.dart';
import '../../../core/state/preset_resolution.dart';
import '../../../core/state/summary_providers.dart';
import '../../../shared/widgets/generic_editor.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../presets/preset_list_provider.dart';
import '../chat_provider.dart';
import '../services/summary_generation_service.dart';

/// Summary tab of the Memory sheet.
///
/// Edits three stores at once through a single [GenericEditor]:
/// - `content` and `prompt` — session-scoped, kept in the summary repo (the
///   same store the prompt builder reads, so a manual edit injects like a
///   generated one).
/// - `role` / `insertionMode` / `depth` — per-preset settings on the effective
///   preset's `summary` block. They used to be reachable only from the preset
///   editor, which is what the old hint in this sheet pointed at.
/// - `autoInterval` — global, in shared preferences.
class SummaryTab extends ConsumerStatefulWidget {
  final String charId;

  const SummaryTab({super.key, required this.charId});

  @override
  ConsumerState<SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends ConsumerState<SummaryTab> {
  late Map<String, dynamic> _localItem;
  bool _isGenerating = false;
  Object? _error;

  /// Null until the effective preset has been resolved, or when it carries no
  /// `summary` block — the block settings section stays hidden in both cases.
  String? _presetId;

  /// Last values written (or loaded). Guards against the no-op save that the
  /// editor schedules when [_load] pushes values into its controllers: that
  /// write would stamp the summary row with the current message count and
  /// silently restart the auto-summary countdown just because the sheet was
  /// opened.
  Map<String, dynamic> _savedItem = const {};

  // Captured while the element is active so _performSave can still read
  // providers when invoked from GenericEditor.dispose() (e.g. the sheet is
  // swipe-dismissed with a pending debounced edit) — by then ref.read throws
  // "Looking up a deactivated widget's ancestor is unsafe". Mirrors
  // AuthorsNoteSheet.
  late final ProviderContainer _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context);
  }

  @override
  void initState() {
    super.initState();
    _localItem = {'content': ''};
    _load();
  }

  Future<void> _load() async {
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    if (session == null) return;
    final service = ref.read(summaryServiceProvider);
    final content = await service.getSummaryContent(session.id);
    final prompt = await service.getSummaryPrompt(session.id);
    final autoInterval = await ref.read(summaryAutoIntervalProvider.future);

    // The preset list is loaded lazily; effectivePresetForChatProvider yields
    // null until it resolves, which would leave the block settings hidden.
    await ref.read(presetListProvider.future);
    if (!mounted) return;
    final preset = ref.read(
      effectivePresetForChatProvider((
        charId: widget.charId,
        sessionId: session.id,
      )),
    );
    final block = _summaryBlockOf(preset);

    setState(() {
      _presetId = block == null ? null : preset?.id;
      _localItem = {
        'content': content ?? '',
        'prompt': prompt ?? '',
        'autoInterval': autoInterval,
        if (block != null) ...{
          'role': block.role,
          'insertionMode': block.insertionMode,
          'depth': block.depth ?? 1,
        },
      };
      _savedItem = Map.of(_localItem);
    });
  }

  /// True when [item] differs from what is already persisted. Values arrive
  /// from text controllers, so compare their string forms.
  bool _isDirty(Map<String, dynamic> item) {
    for (final entry in item.entries) {
      final saved = _savedItem[entry.key];
      if ('${entry.value}' != '$saved') return true;
    }
    return false;
  }

  static PresetBlock? _summaryBlockOf(Preset? preset) =>
      preset?.blocks.where((b) => b.id == 'summary').firstOrNull;

  Future<void> _performSave(Map<String, dynamic> item) async {
    // Use the captured container, not ref — this can be invoked from
    // GenericEditor.dispose() when the element is already deactivated.
    final session = _container.read(chatProvider(widget.charId)).value?.session;
    if (session == null) return;
    if (!_isDirty(item)) return;
    _savedItem = Map.of(item);

    final content = (item['content'] as String?)?.trim() ?? '';
    await _container.read(summaryServiceProvider).setSummary(
          sessionId: session.id,
          content: content,
          messageCount: session.messages.length,
          // Stored verbatim (macros stay unexpanded — it is a template).
          // Empty means "use the built-in prompt".
          prompt: (item['prompt'] as String?) ?? '',
        );
    _container.read(summaryRevisionProvider.notifier).state++;

    await _saveBlockSettings(item);
    await _saveAutoInterval(item);
  }

  Future<void> _saveAutoInterval(Map<String, dynamic> item) async {
    final raw = item['autoInterval'];
    final value = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
    if (_container.read(summaryAutoIntervalProvider).value == value) return;
    await _container.read(summaryAutoIntervalProvider.notifier).set(value);
  }

  /// Writes role / insertion mode / depth back onto the effective preset's
  /// `summary` block. No-op when the tab never resolved a preset block.
  Future<void> _saveBlockSettings(Map<String, dynamic> item) async {
    final presetId = _presetId;
    if (presetId == null) return;
    final presets = _container.read(presetListProvider).value ?? const [];
    final preset = presets.where((p) => p.id == presetId).firstOrNull;
    if (preset == null) return;
    final index = preset.blocks.indexWhere((b) => b.id == 'summary');
    if (index == -1) return;

    final current = preset.blocks[index];
    final insertionMode =
        item['insertionMode'] as String? ?? current.insertionMode;
    final updated = current.copyWith(
      role: item['role'] as String? ?? current.role,
      insertionMode: insertionMode,
      depth: insertionMode == 'depth'
          ? (item['depth'] as num?)?.toInt() ?? current.depth
          : current.depth,
    );
    if (updated == current) return;

    final blocks = List<PresetBlock>.from(preset.blocks)..[index] = updated;
    await _container
        .read(presetListProvider.notifier)
        .updatePreset(preset.copyWith(blocks: blocks));
  }

  List<GenericEditorSection> get _config => [
        GenericEditorSection(
          fields: [
            GenericEditorField(
              key: 'content',
              label: 'summary_title'.tr(),
              type: 'textarea',
              placeholder: 'summary_placeholder'.tr(),
              rows: 8,
              expandable: true,
            ),
          ],
        ),
        GenericEditorSection(
          title: 'summary_generation_section'.tr(),
          fields: [
            GenericEditorField(
              key: 'prompt',
              label: 'summary_prompt_label'.tr(),
              type: 'textarea',
              placeholder: defaultSummaryPrompt,
              rows: 5,
              expandable: true,
            ),
            const GenericEditorField(
              key: '__promptHint',
              label: '',
              type: 'info',
              text: 'Macros are expanded ({{char}}, {{user}}, {{getvar::…}}). '
                  'Add {{history}} to place the transcript yourself — without '
                  'it, it is appended at the end. Leave empty for the built-in '
                  'prompt.',
            ),
            GenericEditorField(
              key: 'autoInterval',
              label: 'summary_auto_interval_label'.tr(),
              type: 'number',
              placeholder: '0',
            ),
            const GenericEditorField(
              key: '__autoHint',
              label: '',
              type: 'info',
              text: 'Auto-summarize after this many new messages. 0 turns it '
                  'off. It only runs when the bot replies, never right after '
                  'your own message. Applies to every chat.',
            ),
          ],
        ),
        if (_presetId != null)
          GenericEditorSection(
            title: 'label_injection_point'.tr(),
            fields: [
              GenericEditorField(
                key: 'role',
                label: 'label_role'.tr(),
                type: 'select',
                options: const [
                  {'label': 'System', 'value': 'system'},
                  {'label': 'User', 'value': 'user'},
                  {'label': 'Assistant', 'value': 'assistant'},
                ],
              ),
              GenericEditorField(
                key: 'insertionMode',
                label: 'label_insertion'.tr(),
                type: 'select',
                options: [
                  {'label': 'injection_relative'.tr(), 'value': 'relative'},
                  {'label': 'injection_depth'.tr(), 'value': 'depth'},
                ],
              ),
              GenericEditorField(
                key: 'depth',
                label: 'label_depth'.tr(),
                type: 'select',
                options: List.generate(
                  20,
                  (i) => {'label': '${i + 1}', 'value': i + 1},
                ),
                showIf: (item) => item['insertionMode'] == 'depth',
              ),
            ],
          ),
      ];

  Future<void> _generateSummary() async {
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    if (session == null) return;

    setState(() {
      _isGenerating = true;
      _error = null;
    });
    try {
      // Flush a pending prompt edit first: the editor's save is debounced, and
      // generation reads the template back out of the repo.
      await _performSave(_localItem);
      if (!mounted) return;
      final summary = await ref
          .read(summaryGenerationServiceProvider)
          .generate(charId: widget.charId, session: session);
      if (!mounted) return;
      setState(() {
        _localItem = Map.from(_localItem)..['content'] = summary;
      });
      // generateSummary already persisted to the repo; just notify watchers.
      ref.read(summaryRevisionProvider.notifier).state++;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: GenericEditor(
            item: _localItem,
            config: _config,
            onChanged: (val) => setState(() => _localItem = val),
            onSave: _performSave,
            useWindows: false,
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top + 4,
              bottom: 16,
            ),
          ),
        ),
        _buildActionBar(context),
      ],
    );
  }

  Widget _buildActionBar(BuildContext context) {
    final error = _error;
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        MediaQuery.paddingOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: _isGenerating ? null : _generateSummary,
            icon: _isGenerating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: GlazeSpinner(),
                  )
                : const Icon(Icons.auto_awesome, size: 18),
            label: Text(
              _isGenerating ? 'Generating...' : 'btn_auto_summary'.tr(),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF528BCC),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            GlazeErrorBlock.fromError(error),
          ],
        ],
      ),
    );
  }
}
