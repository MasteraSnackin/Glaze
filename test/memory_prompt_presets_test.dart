import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/memory_prompt_presets.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';

void main() {
  const custom = MemoryPromptPreset(
    key: 'custom_one',
    label: 'Custom one',
    prompt: 'Custom prompt {{history}}',
  );

  test(
    'resolves built-in and custom prompts without changing storage shape',
    () {
      expect(
        MemoryPromptPresets.resolve('concise_narrative'),
        contains('3-5 sentence'),
      );
      expect(MemoryPromptPresets.resolve(custom.key, [custom]), custom.prompt);
      expect(MemoryPromptPreset.fromJson(custom.toJson()).key, custom.key);
      expect(custom.toJson().keys, unorderedEquals(['key', 'label', 'prompt']));
    },
  );

  test('unknown or deleted selected key falls back to detailed beats', () {
    expect(
      MemoryPromptPresets.validSelection('missing', [custom]),
      MemoryPromptPresets.fallbackKey,
    );
    expect(
      MemoryPromptPresets.validSelection(custom.key, const []),
      MemoryPromptPresets.fallbackKey,
    );
    expect(
      MemoryPromptPresets.resolve('missing'),
      MemoryPromptPresets.resolve(MemoryPromptPresets.fallbackKey),
    );
  });

  test('built-in keys are protected and custom keys are not', () {
    expect(MemoryPromptPresets.isBuiltIn('detailed_beats'), isTrue);
    expect(MemoryPromptPresets.isBuiltIn(custom.key), isFalse);
  });

  test('serialized normalization repairs only a dangling selection', () {
    final original = <String, dynamic>{
      'promptPreset': 'custom_deleted',
      'enabled': false,
      'batchSize': 9,
      'futureField': {'kept': true},
    };
    final normalized = MemoryPromptPresets.normalizeSerializedSelection(
      original,
      {'detailed_beats', 'custom_kept'},
    );

    expect(normalized['promptPreset'], 'detailed_beats');
    expect(normalized['enabled'], isFalse);
    expect(normalized['batchSize'], 9);
    expect(normalized['futureField'], {'kept': true});
    expect(
      MemoryPromptPresets.normalizeSerializedSelection(
        {...original, 'promptPreset': 'custom_kept'},
        {'detailed_beats', 'custom_kept'},
      )['promptPreset'],
      'custom_kept',
    );
  });

  test('copyWith persists custom presets without resetting other settings', () {
    const original = MemoryGlobalSettings(
      memoryMode: 'balanced',
      maxInjectedEntries: 12,
    );
    final updated = original.copyWith(
      customPrompts: MemoryPromptPreset.toJsonList([custom]),
      promptPreset: custom.key,
    );

    expect(updated.customPrompts.single, custom.toJson());
    expect(updated.promptPreset, custom.key);
    expect(updated.memoryMode, original.memoryMode);
    expect(updated.maxInjectedEntries, original.maxInjectedEntries);
  });
}
