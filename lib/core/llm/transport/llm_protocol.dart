/// Canonical protocol identifiers stored in `ApiConfig.protocol`.
///
/// Strings (not a Dart enum) for consistency with other `ApiConfig` string
/// fields (`mode`, `providerId`, `cacheControlTtl`) and to avoid migration
/// pain when adding new protocols.
class LlmProtocol {
  LlmProtocol._();

  /// OpenAI Chat Completions API and any OpenAI-compatible custom endpoint.
  /// Auth: `Authorization: Bearer`. URL: `{endpoint}/v1/chat/completions`.
  static const String openai = 'openai';

  /// OpenAI Responses API and any endpoint implementing it. Same auth and
  /// endpoint shape as [openai], different body (`input` instead of
  /// `messages`, `max_output_tokens`, `reasoning: {effort, summary}`) and a
  /// typed SSE event stream. URL: `{endpoint}/v1/responses`.
  ///
  /// Was a boolean opt-in (`ApiConfig.useResponsesApi`) before it became a
  /// protocol of its own; that field is now derived from this value.
  static const String openaiResponses = 'openai_responses';

  /// Anthropic Messages API (`/v1/messages`). Auth: `x-api-key`.
  /// Supports prefill (last assistant message), prompt caching, extended
  /// thinking.
  static const String anthropic = 'anthropic';

  /// Google Gemini AI Studio (`generativelanguage.googleapis.com`).
  /// Auth: `?key=`. Supports vision, safety settings, thinking budget.
  static const String gemini = 'gemini';

  /// OpenRouter — hardcoded URL `https://openrouter.ai/api/v1`. Behaves like
  /// OpenAI plus OR-specific extras: `HTTP-Referer`/`X-Title` headers,
  /// `cache_control` at depth for Claude-through-OR models, reasoning
  /// signatures.
  static const String openrouter = 'openrouter';

  static const List<String> all = [
    openai,
    openaiResponses,
    anthropic,
    gemini,
    openrouter,
  ];

  static const Map<String, String> labels = {
    openai: 'Custom (OpenAI Chat Completion)',
    openaiResponses: 'Custom (OpenAI Responses)',
    anthropic: 'Anthropic',
    gemini: 'Google Gemini',
    openrouter: 'OpenRouter',
  };

  static bool isValid(String value) => all.contains(value);
}
