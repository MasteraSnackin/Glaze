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
  test('macOS application workspace is available on a clean checkout', () {
    final workspace = File('macos/Runner.xcworkspace/contents.xcworkspacedata');
    final checks = File(
      'macos/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist',
    );

    expect(workspace.existsSync(), isTrue);
    expect(checks.existsSync(), isTrue);
    expect(
      workspace.readAsStringSync(),
      contains('location = "group:Runner.xcodeproj"'),
    );
  });

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

  test('personal macOS DMG workflow builds and verifies Profile', () {
    final workflow = File(
      '.github/workflows/build-branch.yml',
    ).readAsStringSync();
    final start = workflow.indexOf('  build-macos:');
    final end = workflow.indexOf('  build-linux:', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final macosJob = workflow.substring(start, end);
    expect(macosJob, contains('runs-on: macos-15'));
    expect(macosJob, contains('flutter build macos --profile --no-pub'));
    expect(macosJob, isNot(contains('flutter build macos --release')));
    expect(macosJob, contains('codesign --verify --deep --strict'));
    expect(macosJob, contains('hdiutil verify'));
    expect(macosJob, contains('name: Glaze-release-macOS'));
  });
}
