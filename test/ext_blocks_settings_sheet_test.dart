import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/extensions_settings.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extensions_settings_provider.dart';
import 'package:glaze_flutter/features/extensions/widgets/ext_blocks_settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('custom context spoiler exposes granular controls', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container
        .read(extensionPresetsProvider.notifier)
        .add(const ExtensionPreset(id: 'p1', name: 'Preset', blocks: []));
    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(enabled: true, activePresetId: 'p1'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ExtBlocksSettingsSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Передавать тот же контекст, что и в основную модель'),
      findsOneWidget,
    );
    expect(find.text('Настроить контекст'), findsOneWidget);
    await tester.tap(find.text('Настроить контекст'));
    await tester.pumpAndSettle();
    expect(find.text('Карточка персонажа'), findsOneWidget);
    expect(find.text('Lorebooks'), findsOneWidget);
    expect(find.text('MemoryBooks и raw recall'), findsOneWidget);
    expect(find.text('Studio Ledger / state'), findsOneWidget);
    expect(find.text('Author’s note'), findsOneWidget);
    expect(find.text('Runtime prompt injections'), findsOneWidget);
    expect(find.text('Количество сообщений'), findsOneWidget);
  });

  testWidgets('rapid context toggles merge into the latest preset state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container
        .read(extensionPresetsProvider.notifier)
        .add(const ExtensionPreset(id: 'p1', name: 'Preset', blocks: []));

    final notifier = container.read(extensionPresetsProvider.notifier);
    final first = notifier.updateContextPolicy(
      'p1',
      (policy) => policy.copyWith(includeLorebooks: true),
    );
    final second = notifier.updateContextPolicy(
      'p1',
      (policy) => policy.copyWith(includeMemoryBooks: true),
    );
    await Future.wait([first, second]);

    final policy = container
        .read(extensionPresetsProvider)
        .single
        .contextPolicy;
    expect(policy.includeLorebooks, isTrue);
    expect(policy.includeMemoryBooks, isTrue);
    final persisted = await container
        .read(extensionPresetsRepoProvider)
        .getById('p1');
    expect(persisted!.contextPolicy.includeLorebooks, isTrue);
    expect(persisted.contextPolicy.includeMemoryBooks, isTrue);
  });
}
