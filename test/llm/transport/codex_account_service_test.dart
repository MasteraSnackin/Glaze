import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/codex_account_service.dart';
import 'package:glaze_flutter/core/llm/transport/codex_app_server_client.dart';

typedef _RequestHandler =
    FutureOr<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

Future<String> _testWorkingDirectory() async => Directory.systemTemp.path;

class _RecordedRequest {
  const _RecordedRequest(this.method, this.params);

  final String method;
  final Map<String, dynamic> params;
}

class _FakeSession implements CodexAppServerSession {
  _FakeSession(this.handler);

  final _RequestHandler handler;
  final StreamController<CodexAppServerNotification> _notifications =
      StreamController<CodexAppServerNotification>.broadcast(sync: true);
  final List<_RecordedRequest> requests = <_RecordedRequest>[];
  bool closed = false;

  @override
  Stream<CodexAppServerNotification> get notifications => _notifications.stream;

  void emit(String method, [Map<String, dynamic> params = const {}]) {
    _notifications.add(
      CodexAppServerNotification(method: method, params: params),
    );
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    requests.add(_RecordedRequest(method, Map<String, dynamic>.from(params)));
    return handler(method, params);
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {}

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _notifications.close();
  }
}

void main() {
  group('CodexAccountInfo', () {
    test('parses only account type and plan', () {
      final account = CodexAccountInfo.fromAccountRead({
        'requiresOpenaiAuth': true,
        'account': {
          'type': 'chatgpt',
          'planType': 'plus',
          'email': 'must-not-be-retained@example.test',
        },
      });

      expect(account?.type, 'chatgpt');
      expect(account?.planType, 'plus');
      expect(account?.isChatGpt, isTrue);
      expect(account?.requiresManagedCodexConfig, isFalse);
    });

    test('returns null for a signed-out or malformed response', () {
      expect(
        CodexAccountInfo.fromAccountRead({
          'requiresOpenaiAuth': true,
          'account': null,
        }),
        isNull,
      );
      expect(
        CodexAccountInfo.fromAccountRead(<String, dynamic>{
          'requiresOpenaiAuth': true,
          'account': <String, dynamic>{},
        }),
        isNull,
      );
    });

    test('rejects a provider that does not require OpenAI auth', () {
      expect(
        () => CodexAccountInfo.fromAccountRead({
          'requiresOpenaiAuth': false,
          'account': {'type': 'chatgpt'},
        }),
        throwsA(isA<CodexIsolationException>()),
      );
      expect(
        () => CodexAccountInfo.fromAccountRead({
          'account': {'type': 'chatgpt'},
        }),
        throwsA(isA<CodexIsolationException>()),
      );
    });
  });

  group('CodexAccountService', () {
    test('keeps the session open until account/read completes', () async {
      final response = Completer<Map<String, dynamic>>();
      final session = _FakeSession((method, params) {
        expect(method, 'account/read');
        return response.future;
      });
      final service = CodexAccountService(
        sessionFactory:
            ({
              String? workingDirectory,
              CodexStartupCancellation? startupCancellation,
            }) async => session,
        workingDirectoryFactory: _testWorkingDirectory,
      );

      final accountFuture = service.readAccount();
      await Future<void>.delayed(Duration.zero);

      expect(session.closed, isFalse);
      response.complete(<String, dynamic>{
        'requiresOpenaiAuth': true,
        'account': null,
      });
      expect(await accountFuture, isNull);
      expect(session.closed, isTrue);
    });

    test('bounds account RPCs and closes a wedged session', () async {
      final response = Completer<Map<String, dynamic>>();
      final session = _FakeSession((_, _) => response.future);
      final service = CodexAccountService(
        sessionFactory:
            ({
              String? workingDirectory,
              CodexStartupCancellation? startupCancellation,
            }) async => session,
        workingDirectoryFactory: _testWorkingDirectory,
        requestTimeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        service.readAccount(),
        throwsA(
          isA<CodexAppServerException>().having(
            (error) => error.message,
            'message',
            contains('account/read'),
          ),
        ),
      );
      expect(session.closed, isTrue);
    });

    test('accepts a ChatGPT account', () async {
      final session = _FakeSession((method, params) {
        expect(method, 'account/read');
        expect(params, {'refreshToken': false});
        return {
          'requiresOpenaiAuth': true,
          'account': {'type': 'chatgpt', 'planType': 'team'},
        };
      });

      final account = await CodexAccountService().requireChatGpt(session);

      expect(account.type, 'chatgpt');
      expect(account.planType, 'team');
      await session.close();
    });

    test('rejects a workspace account with managed Codex policy', () async {
      final session = _FakeSession(
        (_, _) => {
          'requiresOpenaiAuth': true,
          'account': {'type': 'chatgpt', 'planType': 'enterprise'},
        },
      );

      await expectLater(
        CodexAccountService().requireChatGpt(session),
        throwsA(isA<CodexManagedWorkspaceUnsupportedException>()),
      );
      await session.close();
    });

    test('rejects missing and unknown ChatGPT plan types', () async {
      for (final planType in <Object?>[null, 'unknown', 'future_workspace']) {
        final session = _FakeSession(
          (_, _) => {
            'requiresOpenaiAuth': true,
            'account': {'type': 'chatgpt', 'planType': ?planType},
          },
        );

        await expectLater(
          CodexAccountService().requireChatGpt(session),
          throwsA(isA<CodexManagedWorkspaceUnsupportedException>()),
          reason: '$planType',
        );
        await session.close();
      }
    });

    test('rejects a signed-out session', () async {
      final session = _FakeSession(
        (_, _) => {'requiresOpenaiAuth': true, 'account': null},
      );

      await expectLater(
        CodexAccountService().requireChatGpt(session),
        throwsA(isA<CodexChatGptSignInRequiredException>()),
      );
      await session.close();
    });

    test('rejects an API-billed account', () async {
      final session = _FakeSession(
        (_, _) => {
          'requiresOpenaiAuth': true,
          'account': {'type': 'apiKey'},
        },
      );

      await expectLater(
        CodexAccountService().requireChatGpt(session),
        throwsA(isA<CodexChatGptAccountRequiredException>()),
      );
      await session.close();
    });

    test('paginates models and normalises their wire identifiers', () async {
      late final _FakeSession session;
      session = _FakeSession((method, params) {
        if (method == 'account/read') {
          return {
            'requiresOpenaiAuth': true,
            'account': {'type': 'chatgpt', 'planType': 'plus'},
          };
        }
        expect(method, 'model/list');
        expect(params['includeHidden'], isFalse);
        expect(params['limit'], 100);
        if (!params.containsKey('cursor')) {
          return {
            'data': [
              {'model': 'gpt-first', 'displayName': 'First'},
              {'model': ''},
              {'unexpected': true},
            ],
            'nextCursor': 'page-2',
          };
        }
        expect(params['cursor'], 'page-2');
        return {
          'data': [
            {'id': 'gpt-second', 'displayName': 'Second'},
          ],
          'nextCursor': null,
        };
      });
      final service = CodexAccountService(
        sessionFactory:
            ({
              String? workingDirectory,
              CodexStartupCancellation? startupCancellation,
            }) async => session,
        workingDirectoryFactory: _testWorkingDirectory,
      );

      final models = await service.listModels();

      expect(models, [
        {'model': 'gpt-first', 'displayName': 'First', 'id': 'gpt-first'},
        {'id': 'gpt-second', 'displayName': 'Second'},
      ]);
      expect(session.requests.map((request) => request.method), [
        'account/read',
        'model/list',
        'model/list',
      ]);
      expect(session.closed, isTrue);
    });

    test('keeps the session open until model/list completes', () async {
      final response = Completer<Map<String, dynamic>>();
      final session = _FakeSession((method, params) {
        if (method == 'account/read') {
          return <String, dynamic>{
            'requiresOpenaiAuth': true,
            'account': <String, dynamic>{'type': 'chatgpt', 'planType': 'plus'},
          };
        }
        expect(method, 'model/list');
        return response.future;
      });
      final service = CodexAccountService(
        sessionFactory:
            ({
              String? workingDirectory,
              CodexStartupCancellation? startupCancellation,
            }) async => session,
        workingDirectoryFactory: _testWorkingDirectory,
      );

      final modelsFuture = service.listModels();
      await Future<void>.delayed(Duration.zero);

      expect(session.closed, isFalse);
      response.complete(<String, dynamic>{
        'data': <Object>[],
        'nextCursor': null,
      });
      expect(await modelsFuture, isEmpty);
      expect(session.closed, isTrue);
    });

    test('fails closed when model pagination repeats a cursor', () async {
      final session = _FakeSession(
        (method, params) => {
          'data': const <Object>[],
          'nextCursor': 'same-cursor',
        },
      );

      await expectLater(
        CodexAccountService().listModelsFrom(session),
        throwsA(isA<CodexAppServerException>()),
      );
      expect(session.requests, hasLength(2));
      await session.close();
    });

    test(
      'completes Codex-owned browser sign-in without receiving tokens',
      () async {
        late final _FakeSession session;
        session = _FakeSession((method, params) {
          switch (method) {
            case 'account/login/start':
              expect(params['type'], 'chatgpt');
              return {
                'loginId': 'login-1',
                'authUrl': 'https://auth.openai.com/oauth/authorize?test=1',
              };
            case 'account/read':
              return {
                'requiresOpenaiAuth': true,
                'account': {'type': 'chatgpt', 'planType': 'plus'},
              };
            default:
              fail('Unexpected request: $method');
          }
        });
        final service = CodexAccountService(
          sessionFactory:
              ({
                String? workingDirectory,
                CodexStartupCancellation? startupCancellation,
              }) async => session,
          workingDirectoryFactory: _testWorkingDirectory,
        );
        Uri? openedUri;

        final account = await service.signInWithChatGpt(
          openBrowser: (uri) async {
            openedUri = uri;
            scheduleMicrotask(() {
              session.emit('account/login/completed', {
                'loginId': 'login-1',
                'success': true,
              });
              session.emit('account/updated', {
                'authMode': 'chatgpt',
                'planType': 'plus',
              });
            });
            return true;
          },
        );

        expect(
          openedUri,
          Uri.parse('https://auth.openai.com/oauth/authorize?test=1'),
        );
        expect(account.type, 'chatgpt');
        expect(account.planType, 'plus');
        expect(session.requests.map((request) => request.method), [
          'account/login/start',
          'account/read',
        ]);
        expect(session.closed, isTrue);
      },
    );

    test('clears an unsupported managed-workspace login', () async {
      var clearedIsolatedAuthentication = false;
      late final _FakeSession session;
      session = _FakeSession((method, params) {
        switch (method) {
          case 'account/login/start':
            return {
              'loginId': 'login-managed',
              'authUrl': 'https://auth.openai.com/oauth/authorize?test=1',
            };
          case 'account/logout':
            return <String, dynamic>{};
          default:
            fail('Unexpected request: $method');
        }
      });
      final service = CodexAccountService(
        sessionFactory:
            ({
              String? workingDirectory,
              CodexStartupCancellation? startupCancellation,
            }) async => session,
        workingDirectoryFactory: _testWorkingDirectory,
        clearIsolatedAuthentication: () async {
          clearedIsolatedAuthentication = true;
        },
      );

      await expectLater(
        service.signInWithChatGpt(
          openBrowser: (_) async {
            scheduleMicrotask(() {
              session.emit('account/login/completed', {
                'loginId': 'login-managed',
                'success': true,
              });
              session.emit('account/updated', {
                'authMode': 'chatgpt',
                'planType': 'business',
              });
            });
            return true;
          },
        ),
        throwsA(isA<CodexManagedWorkspaceUnsupportedException>()),
      );
      expect(session.requests.map((request) => request.method), [
        'account/login/start',
        'account/logout',
      ]);
      expect(clearedIsolatedAuthentication, isTrue);
      expect(session.closed, isTrue);
    });

    test(
      'clears an incomplete login if account propagation times out',
      () async {
        var clearedIsolatedAuthentication = false;
        late final _FakeSession session;
        session = _FakeSession((method, params) {
          if (method == 'account/login/start') {
            return {
              'loginId': 'login-incomplete',
              'authUrl': 'https://auth.openai.com/oauth/authorize?test=1',
            };
          }
          fail('Unexpected request: $method');
        });
        final service = CodexAccountService(
          sessionFactory:
              ({
                String? workingDirectory,
                CodexStartupCancellation? startupCancellation,
              }) async => session,
          workingDirectoryFactory: _testWorkingDirectory,
          loginPropagationTimeout: const Duration(milliseconds: 20),
          clearIsolatedAuthentication: () async {
            clearedIsolatedAuthentication = true;
          },
        );

        await expectLater(
          service.signInWithChatGpt(
            openBrowser: (_) async {
              scheduleMicrotask(() {
                session.emit('account/login/completed', {
                  'loginId': 'login-incomplete',
                  'success': true,
                });
              });
              return true;
            },
          ),
          throwsA(
            isA<CodexAppServerException>().having(
              (error) => error.message,
              'message',
              contains('timed out'),
            ),
          ),
        );
        expect(session.requests.map((request) => request.method), [
          'account/login/start',
        ]);
        expect(clearedIsolatedAuthentication, isTrue);
        expect(session.closed, isTrue);
      },
    );

    test('clears auth if the session closes before login completion', () async {
      var clearedIsolatedAuthentication = false;
      late final _FakeSession session;
      session = _FakeSession((method, params) {
        switch (method) {
          case 'account/login/start':
            return {
              'loginId': 'login-interrupted',
              'authUrl': 'https://auth.openai.com/oauth/authorize?test=1',
            };
          case 'account/login/cancel':
            expect(params, {'loginId': 'login-interrupted'});
            return <String, dynamic>{};
          default:
            fail('Unexpected request: $method');
        }
      });
      final service = CodexAccountService(
        sessionFactory:
            ({
              String? workingDirectory,
              CodexStartupCancellation? startupCancellation,
            }) async => session,
        workingDirectoryFactory: _testWorkingDirectory,
        clearIsolatedAuthentication: () async {
          clearedIsolatedAuthentication = true;
        },
      );

      await expectLater(
        service.signInWithChatGpt(
          openBrowser: (_) async {
            scheduleMicrotask(session.close);
            return true;
          },
        ),
        throwsA(
          isA<CodexAppServerException>().having(
            (error) => error.message,
            'message',
            contains('closed before ChatGPT sign-in completed'),
          ),
        ),
      );
      expect(session.requests.map((request) => request.method), [
        'account/login/start',
        'account/login/cancel',
      ]);
      expect(clearedIsolatedAuthentication, isTrue);
      expect(session.closed, isTrue);
    });

    test('cancels the Codex login if the browser cannot be opened', () async {
      var clearedIsolatedAuthentication = false;
      late final _FakeSession session;
      session = _FakeSession((method, params) {
        if (method == 'account/login/start') {
          return {
            'loginId': 'login-cancel',
            'authUrl': 'https://auth.openai.com/oauth/authorize?test=1',
          };
        }
        if (method == 'account/login/cancel') {
          expect(params, {'loginId': 'login-cancel'});
          return const <String, dynamic>{};
        }
        fail('Unexpected request: $method');
      });
      final service = CodexAccountService(
        sessionFactory:
            ({
              String? workingDirectory,
              CodexStartupCancellation? startupCancellation,
            }) async => session,
        workingDirectoryFactory: _testWorkingDirectory,
        clearIsolatedAuthentication: () async {
          clearedIsolatedAuthentication = true;
        },
      );

      await expectLater(
        service.signInWithChatGpt(openBrowser: (_) async => false),
        throwsA(isA<CodexLoginCancelledException>()),
      );

      expect(session.requests.map((request) => request.method), [
        'account/login/start',
        'account/login/cancel',
      ]);
      expect(clearedIsolatedAuthentication, isTrue);
      expect(session.closed, isTrue);
    });

    test('rejects a sign-in URL outside the audited OpenAI issuer', () async {
      late final _FakeSession session;
      session = _FakeSession((method, params) {
        if (method == 'account/login/start') {
          return {
            'loginId': 'login-unsafe',
            'authUrl': 'https://untrusted.example.test/oauth/authorize',
          };
        }
        if (method == 'account/login/cancel') {
          expect(params, {'loginId': 'login-unsafe'});
          return const <String, dynamic>{};
        }
        fail('Unexpected request: $method');
      });
      final service = CodexAccountService(
        sessionFactory:
            ({
              String? workingDirectory,
              CodexStartupCancellation? startupCancellation,
            }) async => session,
        workingDirectoryFactory: _testWorkingDirectory,
      );

      await expectLater(
        service.signInWithChatGpt(openBrowser: (_) async => true),
        throwsA(
          isA<CodexAppServerException>().having(
            (error) => error.message,
            'message',
            contains('unsafe'),
          ),
        ),
      );
      expect(session.requests.map((request) => request.method), [
        'account/login/start',
        'account/login/cancel',
      ]);
      expect(session.closed, isTrue);
    });
  });
}
