import 'package:flutter/material.dart';

import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/models/studio_config.dart';
import '../../../shared/shell/nav_bar_suppression_provider.dart';
import '../../../shared/widgets/generic_editor.dart';
import '../../../shared/widgets/glass_surface.dart';

/// Inline block editor built on the shared [GenericEditor] (the same engine the
/// plain preset block editor uses), so editing an agentic block feels identical
/// to editing a plain one. Fields follow STUDIO_UX_ANALYSIS §5. The two agent
/// dropdowns mean opposite directions, so they are labelled `←`/`→`.
///
/// While it is open the shell's bottom nav bar is hidden: the editor is a
/// full-height form whose content field would otherwise run under the bar.
class StudioBlockEditorInline extends StatelessWidget {
  final StudioPresetBlock block;
  final ValueChanged<StudioPresetBlock> onChanged;
  final VoidCallback onDelete;

  const StudioBlockEditorInline({
    super.key,
    required this.block,
    required this.onChanged,
    required this.onDelete,
  });

  /// Agent dropdown options — the pre-gen controllers (they produce briefs and
  /// receive specific-agent blocks). The final and post-processing agents are
  /// excluded.
  static List<Map<String, dynamic>> get agentOptions => [
    for (final spec in StudioControllerOntology.specs)
      if (!spec.isFinal && spec.phase != 'post_processing')
        {'label': spec.name, 'value': spec.id},
  ];

  @override
  Widget build(BuildContext context) {
    final config = [
      GenericEditorSection(
        title: null,
        fields: [
          GenericEditorField(key: 'title', label: 'Title', type: 'text'),
          GenericEditorField(
            key: 'role',
            label: 'Role',
            type: 'select',
            options: const [
              {'label': 'System', 'value': 'system'},
              {'label': 'User', 'value': 'user'},
              {'label': 'Assistant', 'value': 'assistant'},
            ],
          ),
          GenericEditorField(
            key: 'mode',
            label: 'Mode',
            type: 'select',
            options: const [
              {'label': 'Direct instruction', 'value': 'direct'},
              {'label': 'Pregen Brief', 'value': 'pregenBrief'},
              {'label': 'Agent response', 'value': 'agentResponse'},
            ],
          ),
          GenericEditorField(
            key: 'sourceAgentId',
            label: '← Take response from agent',
            type: 'select',
            options: agentOptions,
            showIf: (item) => item['mode'] == 'agentResponse',
          ),
          GenericEditorField(
            key: 'injectionPoint',
            label: 'Injection point',
            type: 'select',
            options: const [
              {'label': 'Pre-generation', 'value': 'pregen'},
              {'label': 'Final', 'value': 'final'},
              {'label': 'Post-processing', 'value': 'cleaner'},
              {'label': 'Трекер', 'value': 'ledger'},
              {'label': 'Specific agent', 'value': 'specificAgent'},
            ],
          ),
          GenericEditorField(
            key: 'targetAgentId',
            label: '→ Send to agent',
            type: 'select',
            options: agentOptions,
            showIf: (item) => item['injectionPoint'] == 'specificAgent',
          ),
          // A brief/agent-response block emits what an agent produced, so it
          // carries no authored text. The field is only hidden, never cleared —
          // GenericEditor keeps untouched keys in its working copy, so the
          // content comes back if the mode is switched to direct again.
          GenericEditorField(
            key: 'content',
            label: 'Content',
            type: 'textarea',
            rows: 8,
            expandable: true,
            showIf: (item) =>
                item['mode'] != 'pregenBrief' &&
                item['mode'] != 'agentResponse',
          ),
        ],
      ),
    ];

    return NavBarSuppressor(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: GenericEditor(
              item: block.toJson(),
              config: config,
              scrollable: true,
              onChanged: (values) =>
                  onChanged(StudioPresetBlock.fromJson(values)),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              MediaQuery.paddingOf(context).bottom + 16,
            ),
            child: GlassSurface(
              borderRadius: BorderRadius.circular(12),
              tint: _danger.withValues(alpha: 0.14),
              border: Border.all(color: _danger.withValues(alpha: 0.35)),
              glowColor: _danger,
              onTap: onDelete,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.delete_outlined, size: 20, color: _danger),
                    SizedBox(width: 8),
                    Text(
                      'Delete Block',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _danger,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const _danger = Color(0xFFFF4444);
