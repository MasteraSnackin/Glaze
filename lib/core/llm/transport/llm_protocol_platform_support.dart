import 'package:flutter/foundation.dart';

import 'llm_protocol_capabilities.dart';

/// Platform availability policy for LLM protocols.
///
/// This deliberately uses Flutter's [TargetPlatform] instead of `dart:io`, so
/// settings widgets and unit tests can evaluate availability without importing
/// an unsupported library on web builds.
class LlmProtocolPlatformSupport {
  LlmProtocolPlatformSupport._();

  static bool isDesktop(TargetPlatform platform) {
    return switch (platform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };
  }

  static bool isAvailableOn(
    String protocol,
    TargetPlatform platform, {
    bool isWeb = false,
  }) {
    final capabilities = LlmProtocolCapabilities.forProtocol(protocol);
    return !capabilities.isDesktopOnly || (!isWeb && isDesktop(platform));
  }

  static bool isAvailableOnCurrentPlatform(String protocol) {
    return isAvailableOn(protocol, defaultTargetPlatform, isWeb: kIsWeb);
  }
}
