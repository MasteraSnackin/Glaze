import '../../core/llm/transport/llm_protocol_capabilities.dart';
import 'image_gen_models.dart';

/// Prevents a non-HTTP chat transport from exposing preserved, inactive HTTP
/// credentials to image generation.
bool supportsSharedImageConnection(String protocol) =>
    LlmProtocolCapabilities.forProtocol(protocol).supportsSharedImageGeneration;

ImageGenSettings applyImageGenProtocolPolicy(
  ImageGenSettings settings,
  String protocol,
) {
  final usesLlmConnection = switch (settings.apiType) {
    ImageGenApiType.openai || ImageGenApiType.gemini => true,
    _ => false,
  };
  if (!usesLlmConnection ||
      !settings.useSameEndpoint ||
      supportsSharedImageConnection(protocol)) {
    return settings;
  }
  return settings.copyWith(useSameEndpoint: false);
}
