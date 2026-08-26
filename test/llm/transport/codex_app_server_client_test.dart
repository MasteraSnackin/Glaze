import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/codex_app_server_client.dart';

void main() {
  group('CodexJsonLineSession', () {
    late StreamController<String> input;
    late List<String> output;
    late CodexJsonLineSession session;

    setUp(() {
      input = StreamController<String>(sync: true);
      output = <String>[];
      session = CodexJsonLineSession(input.stream, output.add);
    });

    tearDown(() async {
      await session.close();
      await input.close();
    });

    test(
      'writes headerless requests and correlates out-of-order replies',
      () async {
        final first = session.request('account/read', {'refreshToken': false});
        final second = session.request('model/list', {'limit': 100});

        expect(output, hasLength(2));
        final firstEnvelope = Map<String, dynamic>.from(
          jsonDecode(output[0]) as Map,
        );
        final secondEnvelope = Map<String, dynamic>.from(
          jsonDecode(output[1]) as Map,
        );
        expect(firstEnvelope, {
          'method': 'account/read',
          'id': 1,
          'params': {'refreshToken': false},
        });
        expect(secondEnvelope, {
          'method': 'model/list',
          'id': 2,
          'params': {'limit': 100},
        });
        expect(firstEnvelope, isNot(contains('jsonrpc')));

        input.add(
          jsonEncode({
            'id': 2,
            'result': {
              'data': [
                {'model': 'gpt-later'},
              ],
            },
            'futureField': true,
          }),
        );
        input.add(
          jsonEncode({
            'id': 1,
            'result': {
              'account': {'type': 'chatgpt'},
            },
          }),
        );

        expect(await first, {
          'account': {'type': 'chatgpt'},
        });
        expect(await second, {
          'data': [
            {'model': 'gpt-later'},
          ],
        });
      },
    );

    test('delivers notifications interleaved with pending requests', () async {
      final notification = session.notifications.first;
      final pending = session.request('thread/start');

      input.add(
        jsonEncode({
          'method': 'thread/status/changed',
          'params': {
            'threadId': 'thread-1',
            'status': {'type': 'idle'},
          },
        }),
      );
      input.add(
        jsonEncode({
          'id': 1,
          'result': {
            'thread': {'id': 'thread-1'},
          },
        }),
      );

      final event = await notification;
      expect(event.method, 'thread/status/changed');
      expect(event.params['threadId'], 'thread-1');
      expect(await pending, {
        'thread': {'id': 'thread-1'},
      });
    });

    test('surfaces structured RPC errors for the matching request', () async {
      final pending = session.request('turn/start');
      input.add(
        jsonEncode({
          'id': 1,
          'error': {
            'code': -32602,
            'message': 'invalid turn input',
            'data': {'field': 'input'},
          },
        }),
      );

      final error = await pending.then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      expect(error, isA<CodexAppServerRpcException>());
      final rpc = error! as CodexAppServerRpcException;
      expect(rpc.message, 'invalid turn input');
      expect(rpc.code, -32602);
      expect(rpc.data, {'field': 'input'});
    });

    test('fails closed for an unstructured RPC error', () async {
      final pending = session.request('thread/inject_items');
      input.add(jsonEncode({'id': 1, 'error': 'injection was rejected'}));

      await expectLater(
        pending,
        throwsA(
          isA<CodexAppServerRpcException>().having(
            (error) => error.message,
            'message',
            'injection was rejected',
          ),
        ),
      );
    });

    test('fails closed for a non-object RPC result', () async {
      final pending = session.request('thread/start');
      input.add(jsonEncode({'id': 1, 'result': null}));

      await expectLater(
        pending,
        throwsA(
          isA<CodexAppServerException>().having(
            (error) => error.message,
            'message',
            contains('malformed response result'),
          ),
        ),
      );
    });

    test('rejects host requests without dispatching them', () async {
      final notifications = <CodexAppServerNotification>[];
      final subscription = session.notifications.listen(notifications.add);

      input.add(
        jsonEncode({
          'id': 41,
          'method': 'item/commandExecution/requestApproval',
          'params': {'threadId': 'thread-1', 'turnId': 'turn-1'},
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications, isEmpty);
      final denial = Map<String, dynamic>.from(
        jsonDecode(output.single) as Map,
      );
      expect(denial['id'], 41);
      expect(denial['error'], {
        'code': -32601,
        'message': 'Glaze does not permit Codex App Server requests.',
      });
      await subscription.cancel();
    });

    test('fails every pending request on malformed protocol data', () async {
      final notificationError = Completer<Object>();
      final subscription = session.notifications.listen(
        (_) {},
        onError: (Object error) {
          if (!notificationError.isCompleted) notificationError.complete(error);
        },
      );
      final first = session.request('first');
      final second = session.request('second');
      final firstError = expectLater(
        first,
        throwsA(isA<CodexAppServerException>()),
      );
      final secondError = expectLater(
        second,
        throwsA(isA<CodexAppServerException>()),
      );

      input.add('this is not json');

      await firstError;
      await secondError;
      expect(await notificationError.future, isA<CodexAppServerException>());
      await expectLater(
        session.request('after-failure'),
        throwsA(isA<CodexAppServerException>()),
      );
      expect(
        () => session.notify('after-failure'),
        throwsA(isA<CodexAppServerException>()),
      );
      await subscription.cancel();
    });

    test(
      'closing the session rejects pending work and future requests',
      () async {
        final pending = session.request('thread/read');
        final pendingError = expectLater(
          pending,
          throwsA(isA<CodexAppServerException>()),
        );

        await session.close();

        await pendingError;
        await expectLater(
          session.request('account/read'),
          throwsA(isA<CodexAppServerException>()),
        );
      },
    );
  });

  group('CodexIsolatedEnvironment', () {
    test(
      'pins state roots, retains safe process settings and drops secrets',
      () {
        final environment = CodexIsolatedEnvironment.build(
          '/isolated/codex-home',
          parent: const <String, String>{
            'CODEX_HOME': '/shared/codex-home',
            'CODEX_SQLITE_HOME': '/shared/codex-sqlite',
            'CODEX_ACCESS_TOKEN': 'codex-access-secret',
            'CODEX_API_KEY': 'codex-api-secret',
            'OPENAI_API_KEY': 'openai-secret',
            'AWS_ACCESS_KEY_ID': 'aws-access-secret',
            'AWS_SECRET_ACCESS_KEY': 'aws-secret',
            'AWS_WEB_IDENTITY_TOKEN_FILE': '/var/run/aws-token',
            'AZURE_CLIENT_SECRET': 'azure-secret',
            'AZURE_FEDERATED_TOKEN_FILE': '/var/run/azure-token',
            'GOOGLE_APPLICATION_CREDENTIALS': '/var/run/google-token.json',
            'PATH': '/usr/local/bin:/usr/bin',
            'HTTPS_PROXY': 'https://proxy.example.test:8443',
            'NO_PROXY': 'localhost,127.0.0.1',
            'SSL_CERT_FILE': '/etc/example-ca.pem',
            'NODE_EXTRA_CA_CERTS': '/etc/node-ca.pem',
            'TMPDIR': '/private/tmp',
            'LANG': 'en_GB.UTF-8',
          },
        );

        expect(environment['CODEX_HOME'], '/isolated/codex-home');
        expect(environment['CODEX_SQLITE_HOME'], '/isolated/codex-home');
        expect(environment['HOME'], '/isolated/codex-home');
        expect(environment['USERPROFILE'], '/isolated/codex-home');
        expect(environment['PATH'], '/usr/local/bin:/usr/bin');
        expect(environment['HTTPS_PROXY'], 'https://proxy.example.test:8443');
        expect(environment['NO_PROXY'], 'localhost,127.0.0.1');
        expect(environment['SSL_CERT_FILE'], '/etc/example-ca.pem');
        expect(environment['NODE_EXTRA_CA_CERTS'], '/etc/node-ca.pem');
        expect(environment['TMPDIR'], '/private/tmp');
        expect(environment['LANG'], 'en_GB.UTF-8');

        for (final secret in const <String>[
          'CODEX_ACCESS_TOKEN',
          'CODEX_API_KEY',
          'OPENAI_API_KEY',
          'AWS_ACCESS_KEY_ID',
          'AWS_SECRET_ACCESS_KEY',
          'AWS_WEB_IDENTITY_TOKEN_FILE',
          'AZURE_CLIENT_SECRET',
          'AZURE_FEDERATED_TOKEN_FILE',
          'GOOGLE_APPLICATION_CREDENTIALS',
        ]) {
          expect(environment, isNot(contains(secret)), reason: secret);
        }
      },
    );
  });
}
