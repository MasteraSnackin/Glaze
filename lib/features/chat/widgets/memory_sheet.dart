import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/summary_providers.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../chat_provider.dart';
import 'memory_books_tab.dart';
import 'summary_tab.dart';

/// Tabs of the Memory sheet, in display order.
enum MemoryTab { summary, books }

/// Single home for everything session memory: the chat summary and the memory
/// books, behind one segmented control. Replaces the two separate Quick Access
/// entries that used to open them.
class MemorySheet extends ConsumerStatefulWidget {
  final String charId;
  final MemoryTab initialTab;

  const MemorySheet({
    super.key,
    required this.charId,
    this.initialTab = MemoryTab.summary,
  });

  @override
  ConsumerState<MemorySheet> createState() => _MemorySheetState();
}

class _MemorySheetState extends ConsumerState<MemorySheet> {
  late MemoryTab _tab = widget.initialTab;

  /// Tabs the user has actually opened. Both stay mounted afterwards so
  /// switching back does not re-run their loads, but the untouched one is
  /// never built — the books tab queries an embedding status per entry on
  /// first build.
  late final Set<MemoryTab> _visited = {widget.initialTab};

  void _select(MemoryTab tab) {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      _visited.add(tab);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref
        .watch(chatProvider(widget.charId))
        .value
        ?.session;

    return SheetView(
      title: 'Memory',
      showBack: true,
      tabs: [
        SheetViewTab(id: MemoryTab.summary.name, label: 'magic_summary'.tr()),
        SheetViewTab(
          id: MemoryTab.books.name,
          label: 'magic_memory_books'.tr(),
        ),
      ],
      activeTabId: _tab.name,
      onTabSelected: (id) => _select(
        MemoryTab.values.firstWhere((t) => t.name == id),
      ),
      actions: [
        if (_tab == MemoryTab.summary && session != null)
          _summaryToggle(session.id),
      ],
      body: session == null
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _tab.index,
              sizing: StackFit.expand,
              children: [
                _visited.contains(MemoryTab.summary)
                    ? SummaryTab(charId: widget.charId)
                    : const SizedBox.shrink(),
                _visited.contains(MemoryTab.books)
                    ? MemoryBooksTab(
                        sessionId: session.id,
                        charId: widget.charId,
                        messages: session.messages,
                      )
                    : const SizedBox.shrink(),
              ],
            ),
    );
  }

  /// Master switch for summary injection. Writes through
  /// [syncSummaryEnabled], which also flips the `summary` block in every
  /// preset so the toggle is not silently overridden by the active preset.
  SheetViewAction _summaryToggle(String sessionId) {
    final enabled = ref.watch(summaryEnabledProvider(sessionId)).value ?? true;
    void setEnabled(bool value) => syncSummaryEnabled(
          ref,
          charId: widget.charId,
          enabled: value,
        );
    return SheetViewAction(
      icon: Switch(
        value: enabled,
        onChanged: setEnabled,
        activeThumbColor: Theme.of(context).colorScheme.primary,
      ),
      onPressed: () => setEnabled(!enabled),
    );
  }
}

Future<void> showMemorySheet(
  BuildContext context,
  String charId, {
  MemoryTab initialTab = MemoryTab.summary,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => MemorySheet(charId: charId, initialTab: initialTab),
  );
}
