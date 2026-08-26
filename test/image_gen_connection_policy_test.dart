import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_connection_policy.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';

void main() {
  test('Codex forces image generation onto its separate connection', () {
    const settings = ImageGenSettings(
      enabled: true,
      useSameEndpoint: true,
      customEndpoint: 'https://images.example/v1',
      customApiKey: 'image-key',
    );

    final effective = applyImageGenProtocolPolicy(
      settings,
      LlmProtocol.codexChatgpt,
    );

    expect(effective.useSameEndpoint, isFalse);
    expect(effective.customEndpoint, settings.customEndpoint);
    expect(effective.customApiKey, settings.customApiKey);
  });

  test('HTTP chat connections may still be shared with image generation', () {
    const settings = ImageGenSettings(enabled: true, useSameEndpoint: true);

    expect(
      applyImageGenProtocolPolicy(settings, LlmProtocol.openai).useSameEndpoint,
      isTrue,
    );
  });
}
