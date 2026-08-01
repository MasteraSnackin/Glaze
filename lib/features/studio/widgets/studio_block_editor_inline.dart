import 'package:flutter/material.dart';

import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/models/studio_config.dart';
import '../../../shared/widgets/generic_editor.dart';

/// Inline block editor built on the shared [GenericEditor] (the same engine the
/// plain preset block editor uses), so editing an agentic block feels identical
/// to editing a plain one. Fields follow STUDIO_UX_ANALYSIS §5. The two agent
/// dropdowns mean opposite directions, so they are labelled `←`/`→`.
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
          GenericEditorField(
            key: 'content',
            label: 'Content',
            type: 'textarea',
            rows: 8,
            expandable: true,
          ),
        ],
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: GenericEditor(
            item: block.toJson(),
            config: config,
            scrollable: true,
            onChanged: (values) => onChanged(StudioPresetBlock.fromJson(values)),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            MediaQuery.paddingOf(context).bottom + 16,
          ),
          child: Material(
            color: const Color(0xFFFF4444).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(12),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.delete_outlined,
                      size: 20,
                      color: Color(0xFFFF4444),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Delete Block',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFFF4444),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
