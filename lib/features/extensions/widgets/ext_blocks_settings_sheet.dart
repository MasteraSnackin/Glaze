import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/id_generator.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../models/extension_preset.dart';
import '../models/extension_context_policy.dart';
import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';

/// Bottom sheet shown from the magic drawer to manage Ext Blocks settings.
/// Contains a preset selector and an "Edit preset" button.
class ExtBlocksSettingsSheet extends ConsumerWidget {
  const ExtBlocksSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(extensionsSettingsProvider);
    final presets = ref.watch(extensionPresetsProvider);
    final activePreset = settings.activePresetId != null
        ? presets.where((p) => p.id == settings.activePresetId).firstOrNull
        : null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: context.cs.outlineVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Ext Blocks',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Выберите пресет расширений для текущего чата',
                style: TextStyle(
                  fontSize: 13,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              _SelectorTile(
                icon: Icons.tune_outlined,
                label: 'Активный пресет',
                value: activePreset?.name ?? 'Не выбран',
                onTap: () =>
                    _showPresetSelector(context, ref, settings, presets),
              ),
              const SizedBox(height: 8),
              if (activePreset != null) ...[
                _ActionTile(
                  icon: Icons.edit_outlined,
                  label: 'Редактировать пресет',
                  onTap: () {
                    Navigator.pop(context);
                    context.push(
                      '/extensions/preset-editor/${activePreset.id}',
                    );
                  },
                ),
                const SizedBox(height: 8),
                _ContextPolicyEditor(
                  policy: activePreset.contextPolicy,
                  onChanged: (update) => ref
                      .read(extensionPresetsProvider.notifier)
                      .updateContextPolicy(activePreset.id, update),
                ),
                const SizedBox(height: 8),
                _BlocksList(preset: activePreset),
              ],
              const SizedBox(height: 8),
              _ActionTile(
                icon: Icons.add_circle_outline,
                label: 'Создать пресет',
                onTap: () => _createPreset(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createPreset(BuildContext context, WidgetRef ref) async {
    final presets = ref.read(extensionPresetsProvider);
    final name = 'Пресет ${presets.length + 1}';
    final preset = ExtensionPreset(
      id: generateId(),
      name: name,
      blocks: const [],
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await ref.read(extensionPresetsProvider.notifier).add(preset);
    await ref.read(extensionsSettingsProvider.notifier).selectPreset(preset.id);
  }

  void _showPresetSelector(
    BuildContext context,
    WidgetRef ref,
    dynamic settings,
    List<ExtensionPreset> presets,
  ) {
    final activeId = settings.activePresetId as String?;
    GlazeBottomSheet.show<void>(
      context,
      title: 'Выберите пресет',
      items: [
        BottomSheetItem(
          label: 'Не выбран',
          icon: activeId == null
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
          iconColor: activeId == null
              ? context.cs.primary
              : context.cs.onSurfaceVariant,
          onTap: () {
            Navigator.pop(context);
            ref.read(extensionsSettingsProvider.notifier).selectPreset(null);
          },
        ),
        ...presets.map(
          (preset) => BottomSheetItem(
            label: preset.name,
            icon: activeId == preset.id
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            iconColor: activeId == preset.id
                ? context.cs.primary
                : context.cs.onSurfaceVariant,
            onTap: () {
              Navigator.pop(context);
              ref
                  .read(extensionsSettingsProvider.notifier)
                  .selectPreset(preset.id);
            },
          ),
        ),
      ],
    );
  }
}

class _ContextPolicyEditor extends StatefulWidget {
  const _ContextPolicyEditor({required this.policy, required this.onChanged});

  final ExtensionContextPolicy policy;
  final ValueChanged<
    ExtensionContextPolicy Function(ExtensionContextPolicy current)
  >
  onChanged;

  @override
  State<_ContextPolicyEditor> createState() => _ContextPolicyEditorState();
}

class _ContextPolicyEditorState extends State<_ContextPolicyEditor> {
  late final TextEditingController _countController;

  @override
  void initState() {
    super.initState();
    _countController = TextEditingController(
      text: (widget.policy.messageCount ?? 10).toString(),
    );
  }

  @override
  void didUpdateWidget(covariant _ContextPolicyEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final value = (widget.policy.messageCount ?? 10).toString();
    if (_countController.text != value) _countController.text = value;
  }

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  void _update(
    ExtensionContextPolicy Function(ExtensionContextPolicy current) update,
  ) => widget.onChanged(update);

  @override
  Widget build(BuildContext context) {
    final policy = widget.policy;
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SwitchListTile(
            title: const Text(
              'Передавать тот же контекст, что и в основную модель',
            ),
            subtitle: const Text(
              'ExtBlock может использовать другого API-провайдера. Полный '
              'контекст увеличивает стоимость и передаёт ему карточку, память '
              'и инструкции основного запроса.',
            ),
            value: policy.useMainModelContext,
            onChanged: (value) => _update(
              (current) => current.copyWith(
                legacyPromptSemantics: false,
                useMainModelContext: value,
              ),
            ),
          ),
          if (!policy.useMainModelContext)
            ExpansionTile(
              title: const Text('Настроить контекст'),
              subtitle: const Text(
                'Общий лимит сообщений имеет приоритет; старые пресеты без '
                'лимита используют настройку каждого блока.',
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                _toggle('Карточка персонажа', policy.includeCharacterCard, (v) {
                  _update(
                    (current) => current.copyWith(
                      legacyPromptSemantics: false,
                      includeCharacterCard: v,
                    ),
                  );
                }),
                _toggle('Персона пользователя', policy.includePersona, (v) {
                  _update(
                    (current) => current.copyWith(
                      legacyPromptSemantics: false,
                      includePersona: v,
                    ),
                  );
                }),
                _toggle(
                  'Инструкции основного пресета',
                  policy.includeMainPresetInstructions,
                  (v) => _update(
                    (current) => current.copyWith(
                      legacyPromptSemantics: false,
                      includeMainPresetInstructions: v,
                    ),
                  ),
                ),
                _toggle('Lorebooks', policy.includeLorebooks, (v) {
                  _update(
                    (current) => current.copyWith(
                      legacyPromptSemantics: false,
                      includeLorebooks: v,
                    ),
                  );
                }),
                _toggle('MemoryBooks и raw recall', policy.includeMemoryBooks, (
                  v,
                ) {
                  _update(
                    (current) => current.copyWith(
                      legacyPromptSemantics: false,
                      includeMemoryBooks: v,
                    ),
                  );
                }),
                _toggle('Studio Ledger / state', policy.includeStudioState, (
                  v,
                ) {
                  _update(
                    (current) => current.copyWith(
                      legacyPromptSemantics: false,
                      includeStudioState: v,
                    ),
                  );
                }),
                _toggle('Summary', policy.includeSummary, (v) {
                  _update(
                    (current) => current.copyWith(
                      legacyPromptSemantics: false,
                      includeSummary: v,
                    ),
                  );
                }),
                _toggle('Author’s note', policy.includeAuthorsNote, (v) {
                  _update(
                    (current) => current.copyWith(
                      legacyPromptSemantics: false,
                      includeAuthorsNote: v,
                    ),
                  );
                }),
                _toggle(
                  'Runtime prompt injections',
                  policy.includeRuntimePrompts,
                  (v) {
                    _update(
                      (current) => current.copyWith(
                        legacyPromptSemantics: false,
                        includeRuntimePrompts: v,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _countController,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Количество сообщений',
                    helperText:
                        '-1 = все до сообщения, 0 = без истории, N = последние N',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (raw) {
                    final parsed = int.tryParse(raw);
                    if (parsed == null || parsed < -1) return;
                    _update(
                      (current) => current.copyWith(
                        legacyPromptSemantics: false,
                        messageCount: parsed,
                      ),
                    );
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _toggle(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _SelectorTile extends StatelessWidget {
  const _SelectorTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(icon, size: 22, color: const Color(0xFF99A2AD)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 15, color: context.cs.onSurface),
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(icon, size: 22, color: context.cs.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 15, color: context.cs.onSurface),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BlocksList extends ConsumerWidget {
  const _BlocksList({required this.preset});
  final ExtensionPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (preset.blocks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text(
          'В пресете нет блоков. Нажмите «Редактировать пресет» чтобы добавить.',
          style: TextStyle(
            fontSize: 12,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 0, 4),
          child: Text(
            'Блоки (${preset.blocks.length})',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ),
        ...preset.blocks.map(
          (block) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(
                  block.enabled
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: block.enabled
                      ? context.cs.primary
                      : context.cs.onSurfaceVariant.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    block.name.isEmpty ? 'Без имени' : block.name,
                    style: TextStyle(
                      fontSize: 13,
                      color: context.cs.onSurface.withValues(
                        alpha: block.enabled ? 0.9 : 0.5,
                      ),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
