import 'package:flutter/foundation.dart';

import 'llm_protocol.dart';
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
    bool isReleaseMode = kReleaseMode,
  }) {
    final capabilities = LlmProtocolCapabilities.forProtocol(protocol);
    if (protocol == LlmProtocol.codexChatgpt &&
        platform == TargetPlatform.macOS &&
        isReleaseMode) {
      // macOS Release retains App Sandbox and cannot launch a user-installed
      // executable. Local Debug/Profile builds deliberately use the separate
      // unsandboxed development entitlement file.
      return false;
    }
    return !capabilities.isDesktopOnly || (!isWeb && isDesktop(platform));
  }

  static bool isAvailableOnCurrentPlatform(String protocol) {
    return isAvailableOn(protocol, defaultTargetPlatform, isWeb: kIsWeb);
  }
}
