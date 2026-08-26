import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/card_rewrite_slot_resolver.dart';
import 'package:glaze_flutter/core/llm/memory_book_api_config_resolver.dart';
import 'package:glaze_flutter/core/llm/studio_api_config_resolver.dart';
import 'package:glaze_flutter/core/llm/studio_slot_resolver.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/memory_book_api_settings.dart';
import 'package:glaze_flutter/features/extensions/models/connection_profiles.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/services/connection_profile_resolver.dart';

void main() {
  const http = ApiConfig(
    id: 'http',
    protocol: LlmProtocol.openai,
    endpoint: 'https://api.example.test',
    apiKey: 'key',
    model: 'http-model',
  );
  const codex = ApiConfig(
    id: 'codex',
    protocol: LlmProtocol.codexChatgpt,
    model: 'codex-model',
  );

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Memory Books fail closed for a restored desktop-only selection', () {
    const resolver = MemoryBookApiConfigResolver(
      apiConfigs: <ApiConfig>[http, codex],
      activeConfig: http,
    );

    expect(
      resolver.resolve(const MemoryBookApiSettings(apiConfigId: 'codex')),
      isNull,
    );
  });

  test('extension profiles fail closed for a desktop-only mapping', () {
    final preset = ExtensionPreset(
      id: 'preset',
      name: 'Preset',
      blocks: const [],
      connectionProfiles: const ConnectionProfiles(big: 'codex'),
    );

    expect(
      const ConnectionProfileResolver().resolve(
        preset,
        ConnectionProfile.big,
        http,
        const <ApiConfig>[http, codex],
      ),
      isNull,
    );
  });

  test('Studio run resolution fails closed for a desktop-only slot', () {
    const resolver = StudioApiConfigResolver(
      apiConfigs: <ApiConfig>[http, codex],
      activeConfig: http,
    );

    expect(resolver.resolveRunConfig(codex.id), isNull);
    expect(
      () => resolver.resolveAgentConfig(http, codex.id, ''),
      throwsStateError,
    );
  });

  test('dedicated Studio and rewrite slots reject desktop-only configs', () {
    expect(
      () => StudioSlotResolver.resolve(
        apiConfigs: const <ApiConfig>[codex],
        apiConfigId: codex.id,
      ),
      throwsA(isA<Exception>()),
    );
    expect(
      () => CardRewriteSlotResolver.resolve(
        apiConfigs: const <ApiConfig>[codex],
        apiConfigId: codex.id,
      ),
      throwsA(isA<CardRewriteModelNotConfigured>()),
    );
  });
}
