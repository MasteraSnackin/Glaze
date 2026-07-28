import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/studio_agent_settings.dart';

void main() {
  test('reasoning history count defaults to zero', () {
    expect(
      StudioAgentSettings.fromJson(const {}).studioFinalReasoningHistoryCount,
      0,
    );
  });

  test('migrates the legacy reasoning history toggle', () {
    final settings = StudioAgentSettings.fromJson(const {
      'studioFinalIncludeLastReasoning': true,
    });

    expect(settings.studioFinalReasoningHistoryCount, 1);
    expect(settings.toJson()['studioFinalReasoningHistoryCount'], 1);
    expect(
      settings.toJson(),
      isNot(contains('studioFinalIncludeLastReasoning')),
    );
  });

  test('explicit reasoning history count wins over the legacy toggle', () {
    final settings = StudioAgentSettings.fromJson(const {
      'studioFinalReasoningHistoryCount': 3,
      'studioFinalIncludeLastReasoning': false,
    });

    expect(settings.studioFinalReasoningHistoryCount, 3);
  });
}
