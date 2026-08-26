import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _configurationBlock(String project, String id) {
  final match = RegExp(
    '${RegExp.escape(id)}[^=]*= \\{([\\s\\S]*?)\\n\\t\\t\\};',
  ).firstMatch(project);
  expect(match, isNotNull, reason: 'Missing Xcode configuration $id');
  return match!.group(1)!;
}

void main() {
  test('only macOS Release retains App Sandbox', () {
    final release = File(
      'macos/Runner/Release.entitlements',
    ).readAsStringSync();
    final development = File(
      'macos/Runner/DebugProfile.entitlements',
    ).readAsStringSync();
    final project = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final appSandbox = RegExp(
      r'<key>com\.apple\.security\.app-sandbox</key>\s*<true\s*/>',
    );

    expect(appSandbox.hasMatch(release), isTrue);
    expect(appSandbox.hasMatch(development), isFalse);
    final debug = _configurationBlock(project, '33CC10FC2044A3C60003C045');
    final profile = _configurationBlock(project, '338D0CEA231458BD00FA5F75');
    final releaseBlock = _configurationBlock(
      project,
      '33CC10FD2044A3C60003C045',
    );
    expect(debug, contains('Runner/DebugProfile.entitlements'));
    expect(debug, contains('name = Debug;'));
    expect(profile, contains('Runner/DebugProfile.entitlements'));
    expect(profile, contains('name = Profile;'));
    expect(releaseBlock, contains('Runner/Release.entitlements'));
    expect(releaseBlock, contains('name = Release;'));
  });
}
