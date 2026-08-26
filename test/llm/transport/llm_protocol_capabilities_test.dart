import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol_capabilities.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol_platform_support.dart';

void main() {
  test('HTTP protocol requirements remain unchanged', () {
    for (final protocol in const [
      LlmProtocol.openai,
      LlmProtocol.customChatCompletion,
      LlmProtocol.openaiResponses,
      LlmProtocol.anthropic,
      LlmProtocol.gemini,
    ]) {
      final capabilities = LlmProtocolCapabilities.forProtocol(protocol);

      expect(capabilities.requiresEndpoint, isTrue, reason: protocol);
      expect(capabilities.requiresApiKey, isTrue, reason: protocol);
      expect(capabilities.supportsSharedEmbeddings, isTrue, reason: protocol);
      expect(
        capabilities.supportsSharedImageGeneration,
        isTrue,
        reason: protocol,
      );
      expect(capabilities.isDesktopOnly, isFalse, reason: protocol);
    }
  });

  test('OpenRouter keeps its hardcoded endpoint exception', () {
    final capabilities = LlmProtocolCapabilities.forProtocol(
      LlmProtocol.openrouter,
    );

    expect(capabilities.requiresEndpoint, isFalse);
    expect(capabilities.requiresApiKey, isTrue);
    expect(capabilities.supportsSharedEmbeddings, isTrue);
    expect(capabilities.supportsSharedImageGeneration, isTrue);
    expect(capabilities.isDesktopOnly, isFalse);
    expect(
      capabilities.hasRequiredConnectionFields(endpoint: '', apiKey: 'key'),
      isTrue,
    );
    expect(
      capabilities.hasRequiredConnectionFields(endpoint: '', apiKey: ''),
      isFalse,
    );
  });

  test('Codex delegates connection and authentication to the desktop app', () {
    final capabilities = LlmProtocolCapabilities.forProtocol(
      LlmProtocol.codexChatgpt,
    );

    expect(capabilities.requiresEndpoint, isFalse);
    expect(capabilities.requiresApiKey, isFalse);
    expect(capabilities.supportsSharedEmbeddings, isFalse);
    expect(capabilities.supportsSharedImageGeneration, isFalse);
    expect(capabilities.isDesktopOnly, isTrue);
    expect(
      capabilities.hasRequiredConnectionFields(endpoint: '', apiKey: ''),
      isTrue,
    );
  });

  test('unknown protocols fail closed as HTTP connections', () {
    final capabilities = LlmProtocolCapabilities.forProtocol('unknown');

    expect(capabilities.requiresEndpoint, isTrue);
    expect(capabilities.requiresApiKey, isTrue);
    expect(capabilities.supportsSharedEmbeddings, isTrue);
    expect(capabilities.supportsSharedImageGeneration, isTrue);
    expect(capabilities.isDesktopOnly, isFalse);
  });

  test('Codex is available only on native desktop targets', () {
    for (final platform in const [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      expect(
        LlmProtocolPlatformSupport.isAvailableOn(
          LlmProtocol.codexChatgpt,
          platform,
        ),
        isTrue,
        reason: platform.name,
      );
    }
    for (final platform in const [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      expect(
        LlmProtocolPlatformSupport.isAvailableOn(
          LlmProtocol.codexChatgpt,
          platform,
        ),
        isFalse,
        reason: platform.name,
      );
    }
    expect(
      LlmProtocolPlatformSupport.isAvailableOn(
        LlmProtocol.codexChatgpt,
        TargetPlatform.macOS,
        isWeb: true,
      ),
      isFalse,
    );
  });

  test('HTTP protocols stay available on mobile and web', () {
    expect(
      LlmProtocolPlatformSupport.isAvailableOn(
        LlmProtocol.openai,
        TargetPlatform.iOS,
      ),
      isTrue,
    );
    expect(
      LlmProtocolPlatformSupport.isAvailableOn(
        LlmProtocol.openai,
        TargetPlatform.macOS,
        isWeb: true,
      ),
      isTrue,
    );
  });
}
