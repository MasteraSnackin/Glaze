import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

void main() {
  const http = ApiConfig(
    id: 'http',
    protocol: LlmProtocol.openai,
    endpoint: 'https://api.example.test',
  );
  const codex = ApiConfig(id: 'codex', protocol: LlmProtocol.codexChatgpt);

  bool mobileAvailability(String protocol) =>
      protocol != LlmProtocol.codexChatgpt;

  test(
    'an unsupported saved desktop selection fails closed without deletion',
    () {
      final configs = <ApiConfig>[codex, http];

      final resolved = resolveAvailableApiConfig(
        configs,
        codex.id,
        isProtocolAvailable: mobileAvailability,
      );

      expect(resolved, isNull);
      expect(configs, contains(codex));
    },
  );

  test('a missing saved connection still falls back to an available one', () {
    expect(
      resolveAvailableApiConfig(
        const <ApiConfig>[codex, http],
        'deleted-connection',
        isProtocolAvailable: mobileAvailability,
      ),
      http,
    );
  });

  test('returns null when every saved connection is unavailable', () {
    expect(
      resolveAvailableApiConfig(
        const <ApiConfig>[codex],
        codex.id,
        isProtocolAvailable: mobileAvailability,
      ),
      isNull,
    );
  });

  test(
    'keeps the selected desktop connection when the platform supports it',
    () {
      expect(
        resolveAvailableApiConfig(
          const <ApiConfig>[http, codex],
          codex.id,
          isProtocolAvailable: (_) => true,
        ),
        codex,
      );
    },
  );
}
