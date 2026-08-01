import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_groups.dart';
import 'package:glaze_flutter/features/studio/widgets/studio_block_row.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: ListView(children: [child])));

void main() {
  testWidgets('exclusive group expands and selects one option', (tester) async {
    const blocks = [
      StudioPresetBlock(
        id: 'pov_header_group_open',
        title: 'Opening tag',
        content: '<loompov>',
        order: 0,
      ),
      StudioPresetBlock(id: 'pov_header', title: '━🧍 Point-of-View', order: 1),
      StudioPresetBlock(
        id: 'third_person',
        title: 'Third Person Narrator',
        enabled: true,
        order: 2,
      ),
      StudioPresetBlock(
        id: 'second_person',
        title: 'Second Person',
        enabled: false,
        order: 3,
      ),
      StudioPresetBlock(
        id: 'pov_header_group_close',
        title: 'Closing tag',
        content: '</loompov>',
        order: 4,
      ),
    ];
    final group = groupStudioPresetBlocks(blocks).single;
    String? selected;
    StudioPresetBlock? edited;

    await tester.pumpWidget(
      _host(
        StudioBlockGroupRow(
          group: group,
          dragIndex: 0,
          isLast: true,
          onSelectExclusive: (id) => selected = id,
          onToggle: (_, _) {},
          onEdit: (block) => edited = block,
          onDelete: (_) {},
        ),
      ),
    );

    // Collapsed: only the header row and the currently selected child's name
    // (as the row subtitle) are visible.
    expect(find.text('Point-of-View'), findsOneWidget);
    expect(find.text('Second Person'), findsNothing);

    await tester.tap(find.text('Point-of-View'));
    await tester.pumpAndSettle();

    expect(find.text('Second Person'), findsOneWidget);
    expect(find.text('Opening tag'), findsOneWidget);
    expect(find.text('Closing tag'), findsOneWidget);

    await tester.tap(find.text('Opening tag'));
    await tester.pumpAndSettle();
    expect(edited?.id, 'pov_header_group_open');

    // Exclusive children carry radios, not switches.
    expect(find.byType(Switch), findsNothing);
    await tester.tap(find.byIcon(Icons.radio_button_off));
    await tester.pumpAndSettle();
    expect(selected, 'second_person');
  });

  testWidgets('locked group child cannot be toggled', (tester) async {
    const blocks = [
      StudioPresetBlock(id: 'header', title: '━ Core'),
      StudioPresetBlock(id: 'core', title: 'Core Directive', locked: true),
    ];
    final group = groupStudioPresetBlocks(blocks).single;
    var toggled = false;

    await tester.pumpWidget(
      _host(
        StudioBlockGroupRow(
          group: group,
          dragIndex: 0,
          isLast: true,
          onSelectExclusive: (_) {},
          onToggle: (_, _) => toggled = true,
          onEdit: (_) {},
          onDelete: (_) {},
        ),
      ),
    );

    await tester.tap(find.text('Core'));
    await tester.pumpAndSettle();

    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.onChanged, isNull);
    expect(toggled, isFalse);
  });
}
