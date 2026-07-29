import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/services/routmy_image_provider.dart';

void main() {
  Future<({RoutmyImageProvider provider, Future<Map<String, dynamic>> request})>
  createProvider(Map<String, dynamic> responseBody) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final request = server.first.then((httpRequest) async {
      final body =
          jsonDecode(await utf8.decoder.bind(httpRequest).join())
              as Map<String, dynamic>;
      httpRequest.response.headers.contentType = ContentType.json;
      httpRequest.response.write(jsonEncode(responseBody));
      await httpRequest.response.close();
      return body;
    });
    return (
      provider: RoutmyImageProvider(
        baseUrl: 'http://${server.address.host}:${server.port}',
      ),
      request: request,
    );
  }

  group('RoutmyImageProvider Seedream references', () {
    for (final referenceCount in [1, 2]) {
      test('uses generations with $referenceCount reference(s)', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);

        late Uri requestUri;
        late Map<String, dynamic> requestBody;
        final requestHandled = server.first.then((request) async {
          requestUri = request.uri;
          requestBody =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {'b64_json': 'AQ=='},
              ],
            }),
          );
          await request.response.close();
        });

        final provider = RoutmyImageProvider(
          baseUrl: 'http://${server.address.host}:${server.port}',
        );
        final references = List.generate(referenceCount, (_) => 'iVBORw0KGgo=');

        final bytes = await provider.generate(
          apiKey: 'test-key',
          model: 'bytedance/seedream-5.0-pro',
          prompt: 'test prompt',
          aspectRatio: '1:1',
          imageSize: '1K',
          quality: 'auto',
          referenceImages: references,
        );
        await requestHandled;

        expect(requestUri.path, '/v1/images/generations');
        expect(bytes, [1]);
        final expectedRef = 'data:image/png;base64,${references.first}';
        if (referenceCount == 1) {
          expect(requestBody['image'], expectedRef);
        } else {
          expect(requestBody['image'], [expectedRef, expectedRef]);
        }
      });
    }
  });

  group('RoutmyImageProvider Seedream contract', () {
    test('normalizes 4K to 2K and omits generic quality', () async {
      final fixture = await createProvider({
        'data': [
          {'b64_json': 'AQ=='},
        ],
      });

      final bytes = await fixture.provider.generate(
        apiKey: 'test-key',
        model: 'bytedance/seedream-5.0-pro',
        prompt: 'test prompt',
        aspectRatio: '16:9',
        imageSize: '4K',
        quality: 'hd',
      );
      final request = await fixture.request;

      expect(bytes, [1]);
      expect(request['model'], 'bytedance/seedream-5.0-pro');
      expect(request['n'], 1);
      expect(request['image_config'], {
        'aspect_ratio': '16:9',
        'image_size': '2K',
      });
      expect(request, isNot(contains('quality')));
    });

    test('keeps generic quality for non-Seedream image models', () async {
      final fixture = await createProvider({
        'data': [
          {'b64_json': 'AQ=='},
        ],
      });

      await fixture.provider.generate(
        apiKey: 'test-key',
        model: 'meta/muse-spark-1.1',
        prompt: 'test prompt',
        aspectRatio: '1:1',
        imageSize: '4K',
        quality: 'hd',
      );
      final request = await fixture.request;

      expect(request['image_config'], {
        'aspect_ratio': '1:1',
        'image_size': '4K',
      });
      expect(request['quality'], 'high');
    });
  });

  group('RoutmyImageProvider response parsing', () {
    test(
      'accepts completed task metadata when data contains an image',
      () async {
        final fixture = await createProvider({
          'id': 'task-complete-123',
          'status': 'completed',
          'data': [
            {'url': 'data:image/png;base64,AQID'},
          ],
        });

        final bytes = await fixture.provider.generate(
          apiKey: 'test-key',
          model: 'bytedance/seedream-5.0-pro',
          prompt: 'test prompt',
          aspectRatio: '1:1',
          imageSize: '2K',
          quality: 'standard',
        );
        await fixture.request;

        expect(bytes, [1, 2, 3]);
      },
    );

    test('decodes a data URI in b64_json', () async {
      final fixture = await createProvider({
        'data': [
          {'b64_json': 'data:image/png;base64,AQID'},
        ],
      });

      final bytes = await fixture.provider.generate(
        apiKey: 'test-key',
        model: 'bytedance/seedream-5.0-pro',
        prompt: 'test prompt',
        aspectRatio: '1:1',
        imageSize: '1K',
        quality: 'standard',
      );
      await fixture.request;

      expect(bytes, [1, 2, 3]);
    });

    test(
      'reports a top-level asynchronous task without leaking fields',
      () async {
        final fixture = await createProvider({
          'id': 'task-top-level-123',
          'object': 'image.generation.task',
          'status': 'pending',
          'prompt': 'secret prompt',
        });

        final future = fixture.provider.generate(
          apiKey: 'test-key',
          model: 'bytedance/seedream-5.0-pro',
          prompt: 'test prompt',
          aspectRatio: '1:1',
          imageSize: '1K',
          quality: 'standard',
        );

        await expectLater(
          future,
          throwsA(
            predicate((error) {
              final message = error.toString();
              return message.contains('asynchronous image task') &&
                  message.contains('status=pending') &&
                  message.contains('id=task-top-level-123') &&
                  !message.contains('secret prompt');
            }),
          ),
        );
        await fixture.request;
      },
    );

    test('reports a data-item asynchronous task with task_id', () async {
      final fixture = await createProvider({
        'code': 200,
        'data': [
          {
            'status': 'submitted',
            'task_id': 'task-data-item-456',
            'b64_payload': 'must-not-leak',
          },
        ],
      });

      final future = fixture.provider.generate(
        apiKey: 'test-key',
        model: 'bytedance/seedream-5.0-pro',
        prompt: 'test prompt',
        aspectRatio: '1:1',
        imageSize: '2K',
        quality: 'standard',
      );

      await expectLater(
        future,
        throwsA(
          predicate((error) {
            final message = error.toString();
            return message.contains('status=submitted') &&
                message.contains('id=task-data-item-456') &&
                message.contains('no polling endpoint is documented') &&
                !message.contains('must-not-leak');
          }),
        ),
      );
      await fixture.request;
    });
  });
}
