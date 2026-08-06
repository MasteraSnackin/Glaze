import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_connection_service.dart';

void main() {
  Future<HttpServer> startServer(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handler);
    addTearDown(() => server.close(force: true));
    return server;
  }

  test('fetches and filters OpenAI-compatible image models', () async {
    final server = await startServer((request) async {
      expect(request.uri.path, '/v1/models');
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer key',
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'data': [
            {'id': 'dall-e-3'},
            {'id': 'gpt-image-1'},
            {'id': 'sora-2'},
            {'id': 'chat-model'},
          ],
        }),
      );
      await request.response.close();
    });
    final service = ImageGenConnectionService();
    addTearDown(service.dispose);

    final models = await service.fetchOpenAiModels(
      settings: ImageGenSettings(
        useSameEndpoint: false,
        customEndpoint: 'http://${server.address.address}:${server.port}',
        customApiKey: 'key',
      ),
      llmEndpoint: '',
      llmApiKey: '',
    );

    expect(models, ['dall-e-3', 'gpt-image-1']);
  });

  test(
    'checks a Gemini generateContent endpoint through its models route',
    () async {
      final server = await startServer((request) async {
        expect(request.uri.path, '/v1beta/models');
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer key',
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write('{}');
        await request.response.close();
      });
      final service = ImageGenConnectionService();
      addTearDown(service.dispose);

      await service.checkConnection(
        settings: ImageGenSettings(
          apiType: ImageGenApiType.gemini,
          useSameEndpoint: false,
          customEndpoint: 'http://${server.address.address}:${server.port}',
          customApiKey: 'key',
        ),
        llmEndpoint: '',
        llmApiKey: '',
      );
    },
  );
}
