import 'package:flutter/material.dart';

import '../../../core/models/studio_config.dart';
import '../../../core/models/studio_preset_validation.dart';
import '../../../core/llm/studio/studio_context.dart';
import '../../../core/llm/studio_controller_ontology.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../../../shared/widgets/sheet_view.dart';

/// Dialog for editing a single [StudioPresetBlock].
///
/// Shows editable fields for: title, role, content, enabled, order, section,
/// and type. Returns the updated block (or null if cancelled).
class StudioBlockEditorDialog extends StatefulWidget {
  final StudioPresetBlock block;
  final bool isNew;

  const StudioBlockEditorDialog({
    super.key,
    required this.block,
    this.isNew = false,
  });

  @override
  State<StudioBlockEditorDialog> createState() =>
      _StudioBlockEditorDialogState();
}

class _StudioBlockEditorDialogState extends State<StudioBlockEditorDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _contentCtrl;
  late String _role;
  late String _section;
  late StudioBlockType _type;
  late StudioContextSlot? _contextSlot;
  late String? _targetAgentId;
  late bool _enabled;

  static const _roles = ['system', 'user', 'assistant'];
  static const _sections = [
    'pregen',
    'final',
    'cleaner',
    'ledger',
    'build',
    'brief_parser',
  ];

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.block.title);
    _contentCtrl = TextEditingController(text: widget.block.content);
    _role = widget.block.role;
    _section = widget.block.section;
    _type = widget.block.type;
    _contextSlot =
        widget.block.contextSlot ??
        (widget.block.type == StudioBlockType.context
            ? StudioContextSlot.characterCard
            : null);
    _targetAgentId = widget.block.targetAgentId;
    _enabled = widget.block.enabled;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: widget.isNew ? 'New Block' : 'Edit Block',
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check, size: 22),
          tooltip: 'Save',
          onPressed: _save,
        ),
      ],
      body: Material(
        type: MaterialType.transparency,
        child: ListView(
          children: [
            const SizedBox(height: 8),
            GlazeTextField(controller: _titleCtrl, label: 'Title'),
            const SizedBox(height: 16),
            _FieldLabel('Section'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _section,
              isExpanded: true,
              items: _sections
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _section = v ?? _section),
            ),
            const SizedBox(height: 16),
            _FieldLabel('Type'),
            const SizedBox(height: 6),
            DropdownButtonFormField<StudioBlockType>(
              initialValue: _type,
              isExpanded: true,
              items: StudioBlockType.values
                  .map(
                    (type) =>
                        DropdownMenuItem(value: type, child: Text(type.name)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _type = value;
                  if (value == StudioBlockType.context) {
                    _contextSlot ??= StudioContextSlot.characterCard;
                    _targetAgentId = null;
                  } else {
                    _contextSlot = null;
                    if (value != StudioBlockType.instruction) {
                      _targetAgentId = null;
                    }
                  }
                });
              },
            ),
            if (_type == StudioBlockType.context) ...[
              const SizedBox(height: 16),
              _FieldLabel('Context Source'),
              const SizedBox(height: 6),
              DropdownButtonFormField<StudioContextSlot>(
                key: const ValueKey('studio_context_source'),
                initialValue: _contextSlot,
                isExpanded: true,
                items: StudioContextSlot.values
                    .map(
                      (slot) =>
                          DropdownMenuItem(value: slot, child: Text(slot.name)),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _contextSlot = value),
              ),
            ],
            if (_type == StudioBlockType.instruction) ...[
              const SizedBox(height: 16),
              _FieldLabel('Target Agent'),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                key: const ValueKey('studio_target_agent'),
                initialValue: _targetAgentId ?? '',
                isExpanded: true,
                items: [
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text('All agents'),
                  ),
                  ...StudioControllerOntology.specs.map(
                    (spec) => DropdownMenuItem<String>(
                      value: spec.id,
                      child: Text(spec.name),
                    ),
                  ),
                ],
                onChanged: (value) => setState(
                  () => _targetAgentId = value == null || value.isEmpty
                      ? null
                      : value,
                ),
              ),
              const SizedBox(height: 16),
              _FieldLabel('Role'),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  segments: _roles
                      .map((r) => ButtonSegment(value: r, label: Text(r)))
                      .toList(),
                  selected: {_role},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _role = s.first),
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              title: Text(
                widget.block.locked ? 'Enabled (required)' : 'Enabled',
              ),
              value: _enabled,
              onChanged: widget.block.locked
                  ? null
                  : (v) => setState(() => _enabled = v),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 8),
            if (_type == StudioBlockType.instruction)
              GlazeTextField(
                controller: _contentCtrl,
                maxLines: 12,
                label: 'Content (macro templates supported)',
                hint: 'Use {{description}}, {{persona}}, {{memory}}, etc.',
              )
            else
              Text(switch (_type) {
                StudioBlockType.context =>
                  'Studio inserts the selected context source and preserves its message roles.',
                StudioBlockType.history =>
                  'Studio inserts the source-window chat history.',
                StudioBlockType.priorBriefs =>
                  'Studio inserts briefs produced by earlier agents.',
                StudioBlockType.instruction => '',
              }, style: TextStyle(color: context.cs.onSurfaceVariant)),
            const SizedBox(height: 12),
            Text(
              'Studio final-agent briefs: either enable the '
              '"Previous Studio agents" block, or place these macros in '
              'custom final blocks: {{studio_agent_briefs}}, '
              '{{studio_continuity_brief}}, {{studio_agency_brief}}, '
              '{{studio_narrative_brief}}, {{studio_dialogue_brief}}, '
              '{{studio_guard_brief}}, {{studio_world_brief}}, '
              '{{studio_meta_brief}}, {{studio_beauty_brief}}. If any '
              'Studio brief macro is present, the Previous Studio agents '
              'block is skipped to avoid duplicates.',
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  void _save() {
    final updated = widget.block.copyWith(
      title: _titleCtrl.text,
      content: _contentCtrl.text,
      role: _role,
      section: _section,
      type: _type,
      contextSlot: _type == StudioBlockType.context ? _contextSlot : null,
      targetAgentId: _type == StudioBlockType.instruction
          ? _targetAgentId
          : null,
      enabled: _enabled,
    );
    final error =
        StudioPresetValidator.validate(
              StudioPreset(id: 'editor', blocks: [updated]),
            )
            .where(
              (issue) => issue.severity == StudioPresetValidationSeverity.error,
            )
            .firstOrNull;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }
    Navigator.of(context).pop(updated);
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: context.cs.onSurfaceVariant,
      ),
    );
  }
}
