import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/features/studio/widgets/studio_block_editor_dialog.dart';

void main() {
  group('StudioBlockEditorDialog', () {
    // The editor is now a SheetView (a Riverpod ConsumerWidget presented via
    // showModalBottomSheet), so tests wrap it in a ProviderScope and open it as
    // a modal bottom sheet. A tall surface keeps the whole form on screen so
    // the lazily-built ListView materializes every field.
    Future<StudioPresetBlock?> openEditor(
      WidgetTester tester,
      StudioPresetBlock block, {
      bool isNew = false,
    }) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      StudioPresetBlock? result;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    result = await showModalBottomSheet<StudioPresetBlock>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) =>
                          StudioBlockEditorDialog(block: block, isNew: isNew),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('returns updated block on Save', (tester) async {
      final block = StudioPresetBlock(
        id: 'test_block',
        title: 'Original Title',
        role: 'system',
        content: 'Original content',
        enabled: true,
        order: 5,
        section: 'pregen',
      );

      StudioPresetBlock? result;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    result = await showModalBottomSheet<StudioPresetBlock>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => StudioBlockEditorDialog(block: block),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Edit Block'), findsOneWidget);

      // Save is the check action in the sheet header (always visible).
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.id, 'test_block');
      expect(result!.title, 'Original Title');
      expect(result!.section, 'pregen');
    });

    testWidgets('returns null on dismiss', (tester) async {
      final block = StudioPresetBlock(
        id: 'test_block',
        title: 'Test',
        section: 'final',
      );

      StudioPresetBlock? result = block;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    result = await showModalBottomSheet<StudioPresetBlock>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => StudioBlockEditorDialog(block: block),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // No explicit Cancel button in the sheet UI — dismiss by tapping the
      // modal barrier above the sheet.
      await tester.tapAt(const Offset(400, 10));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('shows all section options in dropdown', (tester) async {
      final block = StudioPresetBlock(
        id: 'test_block',
        title: 'Test',
        section: 'pregen',
      );

      await openEditor(tester, block);

      expect(find.text('Edit Block'), findsOneWidget);
      expect(find.text('pregen'), findsOneWidget);
      expect(find.text('instruction'), findsOneWidget);
      // Role is now a SegmentedButton; 'system' is one of its segments.
      expect(find.text('system'), findsOneWidget);
      expect(find.text('Enabled'), findsOneWidget);
    });

    testWidgets('shows New Block title for new blocks', (tester) async {
      final block = StudioPresetBlock(
        id: 'new_block',
        title: '',
        section: 'pregen',
      );

      await openEditor(tester, block, isNew: true);

      expect(find.text('New Block'), findsOneWidget);
    });

    testWidgets('selects an explicit context source and clears target', (
      tester,
    ) async {
      const block = StudioPresetBlock(
        id: 'source',
        content: 'Old instruction',
        targetAgentId: 'continuity',
      );
      StudioPresetBlock? result;
      await _pumpEditor(tester, block, (value) => result = value);

      await tester.tap(find.text('instruction').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('context').last);
      await tester.pumpAndSettle();

      expect(find.text('Context Source'), findsOneWidget);
      expect(find.text('Target Agent'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('studio_context_source')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('memory').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      expect(result!.type, StudioBlockType.context);
      expect(result!.contextSlot, StudioContextSlot.memory);
      expect(result!.targetAgentId, isNull);
    });

    testWidgets('selects an exact target for instructions', (tester) async {
      const block = StudioPresetBlock(id: 'rules', content: 'Rules');
      StudioPresetBlock? result;
      await _pumpEditor(tester, block, (value) => result = value);

      expect(find.text('Target Agent'), findsOneWidget);
      expect(find.text('Context Source'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('studio_target_agent')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continuity Controller').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      expect(result!.targetAgentId, 'continuity');
      expect(result!.contextSlot, isNull);
    });

    testWidgets('keeps invalid instruction open and explains the error', (
      tester,
    ) async {
      const block = StudioPresetBlock(id: 'rules');
      StudioPresetBlock? result;
      await _pumpEditor(tester, block, (value) => result = value);

      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(find.text('Edit Block'), findsOneWidget);
      expect(
        find.text('Instruction content must not be empty.'),
        findsOneWidget,
      );
    });
  });
}

Future<void> _pumpEditor(
  WidgetTester tester,
  StudioPresetBlock block,
  ValueChanged<StudioPresetBlock?> onResult,
) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                final result = await showModalBottomSheet<StudioPresetBlock>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => StudioBlockEditorDialog(block: block),
                );
                onResult(result);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}
