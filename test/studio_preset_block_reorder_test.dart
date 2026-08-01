import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_groups.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_reorder.dart';

StudioPresetBlock _block(
  String id, {
  int order = 0,
  String title = '',
  String injectionPoint = 'pregen',
}) {
  return StudioPresetBlock(
    id: id,
    title: title.isEmpty ? id : title,
    order: order,
    injectionPoint: injectionPoint,
  );
}

List<String> _idsInOrder(List<StudioPresetBlock> blocks) {
  final sorted = [...blocks]..sort((a, b) => a.order.compareTo(b.order));
  return sorted.map((b) => b.id).toList();
}

void main() {
  group('reorderStudioPresetBlocks', () {
    test('permutes the visible rows and renumbers order densely', () {
      final blocks = [
        _block('a', order: 0),
        _block('b', order: 1),
        _block('c', order: 2),
      ];
      final entries = groupStudioPresetBlocks(blocks);
      expect(entries.length, 3);

      // Drag the last row to the top.
      final reordered = [entries[2], entries[0], entries[1]];
      final result = reorderStudioPresetBlocks(all: blocks, entries: reordered);

      expect(_idsInOrder(result), ['c', 'a', 'b']);
      expect(result.map((b) => b.order).toList()..sort(), [0, 1, 2]);
    });

    test('leaves blocks at other injection points in their slots', () {
      final blocks = [
        _block('pre1', order: 0),
        _block('final1', order: 1, injectionPoint: 'final'),
        _block('pre2', order: 2),
      ];
      final visible = blocks
          .where((b) => b.injectionPoint == 'pregen')
          .toList();
      final entries = groupStudioPresetBlocks(visible);
      final result = reorderStudioPresetBlocks(
        all: blocks,
        entries: [entries[1], entries[0]],
      );

      // `final1` keeps the middle slot; only the two pregen rows swap.
      expect(_idsInOrder(result), ['pre2', 'final1', 'pre1']);
    });

    test('moves a section header together with its children', () {
      final blocks = [
        _block('lead', order: 0),
        _block('head', order: 1, title: '━ Narrative'),
        _block('child1', order: 2),
        _block('child2', order: 3),
      ];
      final entries = groupStudioPresetBlocks(blocks);
      // One standalone row, then a section (header + 2 children).
      expect(entries.length, 2);
      expect(entries.first.standalone?.id, 'lead');
      expect(entries.last.header?.id, 'head');

      final result = reorderStudioPresetBlocks(
        all: blocks,
        entries: [entries.last, entries.first],
      );

      expect(_idsInOrder(result), ['head', 'child1', 'child2', 'lead']);
    });

    test('skips the synthesized Tense header instead of bailing out', () {
      final blocks = [
        _block('pov', order: 0, title: '━ Point-of-View'),
        _block('pov_first', order: 1, title: 'First person'),
        _block('tense_past', order: 2, title: 'Tense modifier: past'),
      ];
      final entries = groupStudioPresetBlocks(blocks);
      // The grouper splits the tense modifier into its own section under a
      // header block that exists only in the UI.
      expect(entries.length, 2);
      expect(entries.last.header?.id, 'tense_past_group');

      final result = reorderStudioPresetBlocks(
        all: blocks,
        entries: [entries.last, entries.first],
      );

      expect(_idsInOrder(result), ['tense_past', 'pov', 'pov_first']);
      expect(result.any((b) => b.id == 'tense_past_group'), isFalse);
    });

    test('is a no-op when a block is claimed by two rows', () {
      final duplicated = _block('a', order: 0);
      final blocks = [duplicated, _block('b', order: 1)];
      final result = reorderStudioPresetBlocks(
        all: blocks,
        entries: [
          StudioPresetBlockGroup.standalone(duplicated),
          StudioPresetBlockGroup.standalone(duplicated),
        ],
      );
      expect(identical(result, blocks), isTrue);
    });
  });

  group('studioPresetEntryBlocks', () {
    test('returns the standalone block for an ungrouped row', () {
      final block = _block('solo');
      final entry = StudioPresetBlockGroup.standalone(block);
      expect(studioPresetEntryBlocks(entry).map((b) => b.id), ['solo']);
    });

    test('emits boundaries around the header and children', () {
      final entry = StudioPresetBlockGroup.section(
        header: _block('head', title: '━ Section'),
        openingBoundary: _block('head_group_open'),
        closingBoundary: _block('head_group_close'),
        children: [_block('child')],
        exclusive: false,
      );
      expect(studioPresetEntryBlocks(entry).map((b) => b.id).toList(), [
        'head_group_open',
        'head',
        'child',
        'head_group_close',
      ]);
    });
  });
}
