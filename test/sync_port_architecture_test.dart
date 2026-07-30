import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('core repositories do not import cloud sync features', () {
    final files = <File>[
      ...Directory('lib/core/db/repositories')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
    ];
    final featureCloudSyncImport = RegExp(
      r'''import\s+['"][^'"]*features/cloud_sync/''',
    );

    for (final file in files) {
      expect(
        file.readAsStringSync(),
        isNot(matches(featureCloudSyncImport)),
        reason: '${file.path} must depend on the neutral sync port',
      );
    }
  });

  test('neutral sync ports do not import feature models', () {
    final files = <File>[
      File('lib/core/application/sync_repo_interfaces.dart'),
      File('lib/shared/application/sync_theme_store.dart'),
    ];
    final featureImport = RegExp(r'''import\s+['"][^'"]*features/''');

    for (final file in files) {
      expect(
        file.readAsStringSync(),
        isNot(matches(featureImport)),
        reason: '${file.path} must remain below the feature layer',
      );
    }
  });
}
