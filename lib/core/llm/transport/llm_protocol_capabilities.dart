import 'llm_protocol.dart';

/// Connection and feature requirements which vary by LLM protocol.
///
/// Keeping these rules next to [LlmProtocol] prevents endpoint/key checks from
/// being reimplemented as one-off `OpenRouter` exceptions around the app. An
/// unknown persisted value remains conservative and behaves like a custom
/// HTTP provider until settings normalisation replaces it.
class LlmProtocolCapabilities {
  const LlmProtocolCapabilities({
    required this.requiresEndpoint,
    required this.requiresApiKey,
    required this.supportsSharedEmbeddings,
    required this.supportsSharedImageGeneration,
    required this.isDesktopOnly,
  });

  /// Whether Glaze needs a configured HTTP endpoint before using the protocol.
  final bool requiresEndpoint;

  /// Whether Glaze needs a configured API key before using the protocol.
  final bool requiresApiKey;

  /// Whether the chat connection can also be used for embedding requests.
  final bool supportsSharedEmbeddings;

  /// Whether image generation may reuse this chat connection's HTTP fields.
  final bool supportsSharedImageGeneration;

  /// Whether the protocol is only usable on macOS, Windows, and Linux.
  final bool isDesktopOnly;

  static const _http = LlmProtocolCapabilities(
    requiresEndpoint: true,
    requiresApiKey: true,
    supportsSharedEmbeddings: true,
    supportsSharedImageGeneration: true,
    isDesktopOnly: false,
  );

  static const _openRouter = LlmProtocolCapabilities(
    requiresEndpoint: false,
    requiresApiKey: true,
    supportsSharedEmbeddings: true,
    supportsSharedImageGeneration: true,
    isDesktopOnly: false,
  );

  static const _codex = LlmProtocolCapabilities(
    requiresEndpoint: false,
    requiresApiKey: false,
    supportsSharedEmbeddings: false,
    supportsSharedImageGeneration: false,
    isDesktopOnly: true,
  );

  static LlmProtocolCapabilities forProtocol(String protocol) {
    return switch (protocol) {
      LlmProtocol.openrouter => _openRouter,
      LlmProtocol.codexChatgpt => _codex,
      _ => _http,
    };
  }

  /// True when all connection fields owned by Glaze are present.
  ///
  /// The model is intentionally not part of this check: some callers only
  /// need to authenticate or fetch models, while generation call sites keep
  /// their existing, more specific model validation.
  bool hasRequiredConnectionFields({
    required String endpoint,
    required String apiKey,
  }) {
    return (!requiresEndpoint || endpoint.trim().isNotEmpty) &&
        (!requiresApiKey || apiKey.trim().isNotEmpty);
  }
}
