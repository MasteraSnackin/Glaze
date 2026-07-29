import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';

void main() {
  test('old preset JSON preserves legacy context behavior', () {
    final preset = ExtensionPreset.fromJson({
      'id': 'p1',
      'name': 'Old',
      'blocks': <Object?>[],
    });
    final policy = preset.contextPolicy;
    expect(policy.legacyPromptSemantics, isTrue);
    expect(policy.useMainModelContext, isFalse);
    expect(policy.includeCharacterCard, isTrue);
    expect(policy.includePersona, isTrue);
    expect(policy.includeLorebooks, isFalse);
    expect(policy.includeMemoryBooks, isFalse);
    expect(policy.messageCount, isNull);
  });

  test('explicit context policy is not treated as legacy', () {
    final preset = ExtensionPreset.fromJson({
      'id': 'p1',
      'name': 'New',
      'blocks': <Object?>[],
      'contextPolicy': <String, Object?>{},
    });

    expect(preset.contextPolicy.legacyPromptSemantics, isFalse);
  });

  test('context policy survives preset JSON round-trip', () {
    final original = ExtensionPreset.fromJson({
      'id': 'p1',
      'name': 'New',
      'blocks': <Object?>[],
      'contextPolicy': {
        'useMainModelContext': true,
        'includeLorebooks': true,
        'messageCount': -1,
      },
    });
    final json =
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>;
    final decoded = ExtensionPreset.fromJson(json);
    expect(decoded.contextPolicy.useMainModelContext, isTrue);
    expect(decoded.contextPolicy.includeLorebooks, isTrue);
    expect(decoded.contextPolicy.messageCount, -1);
  });
}
