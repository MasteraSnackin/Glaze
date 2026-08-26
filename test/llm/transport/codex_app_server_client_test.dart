import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/codex_app_server_client.dart';
import 'package:path/path.dart' as p;

Map<String, dynamic> _safeConfigRead({
  String codexHome = '/isolated/codex-home',
}) {
  final userSource = <String, dynamic>{
    'type': 'user',
    'file': '$codexHome/config.toml',
    'profile': null,
  };
  final sessionSource = <String, dynamic>{'type': 'sessionFlags'};
  final sessionOrigin = <String, dynamic>{
    'name': sessionSource,
    'version': 'sha256:session-config',
  };
  final userOrigin = <String, dynamic>{
    'name': userSource,
    'version': 'sha256:user-config',
  };
  return <String, dynamic>{
    'config': <String, dynamic>{
      'model_provider': 'openai',
      'openai_base_url': CodexInvocationPolicy.openAiBaseUrl,
      'chatgpt_base_url': CodexInvocationPolicy.chatGptBaseUrl,
      'forced_login_method': 'chatgpt',
      'cli_auth_credentials_store': 'file',
      'approval_policy': 'never',
      'sandbox_mode': 'read-only',
      'allow_login_shell': false,
      'project_doc_max_bytes': 0,
      'project_root_markers': <Object>[],
      'include_apps_instructions': false,
      'include_collaboration_mode_instructions': false,
      'include_environment_context': false,
      'include_permissions_instructions': false,
      'marketplaces': <String, dynamic>{},
      'mcp_servers': <String, dynamic>{},
      'model_providers': <String, dynamic>{},
      'plugins': <String, dynamic>{},
      'analytics': <String, dynamic>{'enabled': false},
      'compact_prompt': null,
      'developer_instructions': null,
      'experimental_compact_prompt_file': null,
      'experimental_thread_config_endpoint': null,
      'experimental_thread_store': null,
      'experimental_thread_store_endpoint': null,
      'forced_chatgpt_workspace_id': null,
      'hooks': null,
      'instructions': null,
      'mcp_oauth_credentials_store': null,
      'model_catalog_json': CodexInvocationPolicy.modelCatalogPath(codexHome),
      'model_instructions_file': null,
      'notify': <Object>[],
      'otel': <String, dynamic>{
        'exporter': 'none',
        'trace_exporter': 'none',
        'metrics_exporter': 'none',
        'log_user_prompt': false,
      },
      'profile': null,
      'projects': null,
      'history': <String, dynamic>{'persistence': 'none'},
      'web_search': 'disabled',
      'agents': <String, dynamic>{'enabled': false},
      'apps': <String, dynamic>{
        '_default': <String, dynamic>{
          'enabled': false,
          'destructive_enabled': false,
          'open_world_enabled': false,
        },
      },
      'memories': <String, dynamic>{
        'use_memories': false,
        'generate_memories': false,
      },
      'tools': <String, dynamic>{
        'update_plan': <String, dynamic>{'enabled': false},
        'experimental_request_user_input': <String, dynamic>{'enabled': false},
      },
      'features': Map<String, dynamic>.from(
        CodexIsolationPolicy.expectedUserLayerConfig(codexHome)['features']!
            as Map,
      ),
    },
    'origins': <String, dynamic>{
      'model_provider': sessionOrigin,
      'openai_base_url': sessionOrigin,
      'chatgpt_base_url': sessionOrigin,
      'model_catalog_json': sessionOrigin,
      'forced_login_method': sessionOrigin,
      'web_search': sessionOrigin,
      'project_root_markers': sessionOrigin,
      'approval_policy': sessionOrigin,
      'sandbox_mode': sessionOrigin,
      'history.persistence': userOrigin,
    },
    'layers': <Object>[
      <String, dynamic>{
        'name': sessionSource,
        'version': 'sha256:session-config',
        'config': CodexInvocationPolicy.expectedLayerConfig(codexHome),
      },
      <String, dynamic>{
        'name': userSource,
        'version': 'sha256:user-config',
        'config': CodexIsolationPolicy.expectedUserLayerConfig(codexHome),
      },
      <String, dynamic>{
        'name': <String, dynamic>{
          'type': 'system',
          'file': '/etc/codex/config.toml',
        },
        'version': 'sha256:empty',
        'config': <String, dynamic>{},
      },
    ],
  };
}

class _IsolationVerificationSession implements CodexAppServerSession {
  _IsolationVerificationSession(this.responses);

  final Map<String, Map<String, dynamic>> responses;
  final List<String> methods = <String>[];

  @override
  Stream<CodexAppServerNotification> get notifications =>
      const Stream<CodexAppServerNotification>.empty();

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    methods.add(method);
    return responses[method] ?? <String, dynamic>{};
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {}

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('CodexIsolationPolicy', () {
    test(
      'validates configuration and requirements before MCP discovery',
      () async {
        final session = _IsolationVerificationSession(
          <String, Map<String, dynamic>>{
            'config/read': _safeConfigRead(),
            'configRequirements/read': <String, dynamic>{'requirements': null},
            'mcpServerStatus/list': <String, dynamic>{
              'data': <Object>[],
              'nextCursor': null,
            },
          },
        );

        await CodexIsolationPolicy.verify(
          session,
          codexHome: '/isolated/codex-home',
          workingDirectory: '/isolated/workspace',
        );

        expect(session.methods, <String>[
          'config/read',
          'configRequirements/read',
          'mcpServerStatus/list',
        ]);
      },
    );

    test(
      'does not discover MCP servers after managed requirements fail',
      () async {
        final session = _IsolationVerificationSession(
          <String, Map<String, dynamic>>{
            'config/read': _safeConfigRead(),
            'configRequirements/read': <String, dynamic>{
              'requirements': <String, dynamic>{
                'allowedApprovalPolicies': <String>[],
              },
            },
          },
        );

        await expectLater(
          CodexIsolationPolicy.verify(
            session,
            codexHome: '/isolated/codex-home',
            workingDirectory: '/isolated/workspace',
          ),
          throwsA(isA<CodexIsolationException>()),
        );
        expect(session.methods, <String>[
          'config/read',
          'configRequirements/read',
        ]);
      },
    );

    test('accepts Glaze startup/user layers plus an empty system layer', () {
      expect(
        () => CodexIsolationPolicy.validateConfigRead(
          _safeConfigRead(),
          codexHome: '/isolated/codex-home',
        ),
        returnsNormally,
      );
      expect(
        () => CodexIsolationPolicy.validateInitialize(const <String, dynamic>{
          'codexHome': '/isolated/codex-home',
          'userAgent': 'glaze/0.147.0 (Test OS; arm64) unknown (glaze; 0.7.0)',
        }, codexHome: '/isolated/codex-home'),
        returnsNormally,
      );
    });

    test('rejects a non-empty external system layer', () {
      final response = _safeConfigRead();
      final layers = response['layers']! as List;
      (layers[2] as Map<String, dynamic>)['config'] = <String, dynamic>{
        'mcp_servers': <String, dynamic>{
          'host-tools': <String, dynamic>{'command': 'unsafe'},
        },
      };

      expect(
        () => CodexIsolationPolicy.validateConfigRead(
          response,
          codexHome: '/isolated/codex-home',
        ),
        throwsA(isA<CodexIsolationException>()),
      );
    });

    test('rejects project and managed layers even when empty', () {
      for (final source in <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'project',
          'dotCodexFolder': '/outside/.codex',
        },
        <String, dynamic>{
          'type': 'enterpriseManaged',
          'id': 'managed-1',
          'name': 'Managed policy',
        },
      ]) {
        final response = _safeConfigRead();
        (response['layers']! as List).add(<String, dynamic>{
          'name': source,
          'version': 'sha256:empty',
          'config': <String, dynamic>{},
        });

        expect(
          () => CodexIsolationPolicy.validateConfigRead(
            response,
            codexHome: '/isolated/codex-home',
          ),
          throwsA(isA<CodexIsolationException>()),
          reason: source['type'] as String,
        );
      }
    });

    test('rejects a custom or overridden OpenAI model provider', () {
      final wrongProvider = _safeConfigRead();
      (wrongProvider['config']! as Map<String, dynamic>)['model_provider'] =
          'custom';
      expect(
        () => CodexIsolationPolicy.validateConfigRead(
          wrongProvider,
          codexHome: '/isolated/codex-home',
        ),
        throwsA(isA<CodexIsolationException>()),
      );

      final overriddenOpenAi = _safeConfigRead();
      (overriddenOpenAi['config']!
          as Map<String, dynamic>)['model_providers'] = <String, dynamic>{
        'openai': <String, dynamic>{
          'base_url': 'https://untrusted.example.test',
          'requires_openai_auth': true,
        },
      };
      expect(
        () => CodexIsolationPolicy.validateConfigRead(
          overriddenOpenAi,
          codexHome: '/isolated/codex-home',
        ),
        throwsA(isA<CodexIsolationException>()),
      );
    });

    test('rejects provider URL overrides and unexpected user settings', () {
      final baseUrl = _safeConfigRead();
      (baseUrl['config']! as Map<String, dynamic>)['chatgpt_base_url'] =
          'https://untrusted.example.test';
      expect(
        () => CodexIsolationPolicy.validateConfigRead(
          baseUrl,
          codexHome: '/isolated/codex-home',
        ),
        throwsA(isA<CodexIsolationException>()),
      );

      final unexpectedUserSetting = _safeConfigRead();
      final userLayer = (unexpectedUserSetting['layers']! as List)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (layer) =>
                (layer['name'] as Map<String, dynamic>)['type'] == 'user',
          );
      userLayer['config'] = <String, dynamic>{
        ...CodexIsolationPolicy.expectedUserLayerConfig('/isolated/codex-home'),
        'notify': <String>['unsafe-hook'],
      };
      expect(
        () => CodexIsolationPolicy.validateConfigRead(
          unexpectedUserSetting,
          codexHome: '/isolated/codex-home',
        ),
        throwsA(isA<CodexIsolationException>()),
      );
    });

    test('requires an empty, fully paginated MCP inventory', () {
      expect(
        () => CodexIsolationPolicy.validateMcpInventory(const <String, dynamic>{
          'data': <Object>[],
          'nextCursor': null,
        }),
        returnsNormally,
      );
      for (final response in <Map<String, dynamic>>[
        <String, dynamic>{
          'data': <Object>[
            <String, dynamic>{'name': 'host-tools'},
          ],
          'nextCursor': null,
        },
        <String, dynamic>{'data': <Object>[], 'nextCursor': 'more'},
        <String, dynamic>{'nextCursor': null},
      ]) {
        expect(
          () => CodexIsolationPolicy.validateMcpInventory(response),
          throwsA(isA<CodexIsolationException>()),
        );
      }
    });

    test('rejects managed configuration requirements', () {
      expect(
        () => CodexIsolationPolicy.validateConfigRequirements(
          const <String, dynamic>{'requirements': null},
        ),
        returnsNormally,
      );
      expect(
        () => CodexIsolationPolicy.validateConfigRequirements(
          const <String, dynamic>{
            'requirements': <String, dynamic>{
              'chatgptBaseUrl': 'https://managed.example.test',
            },
          },
        ),
        throwsA(isA<CodexIsolationException>()),
      );
      expect(
        () => CodexIsolationPolicy.validateConfigRequirements(
          const <String, dynamic>{},
        ),
        throwsA(isA<CodexIsolationException>()),
      );
    });

    test('requires the reported Codex home to match the Glaze profile', () {
      expect(
        () => CodexIsolationPolicy.validateInitialize(const <String, dynamic>{
          'codexHome': '/shared/codex-home',
          'userAgent': 'glaze/0.147.0 (Test OS; arm64) unknown (glaze; 0.7.0)',
        }, codexHome: '/isolated/codex-home'),
        throwsA(isA<CodexIsolationException>()),
      );
    });

    test('rejects Codex versions outside the audited compatibility set', () {
      expect(
        () => CodexIsolationPolicy.validateInitialize(const <String, dynamic>{
          'codexHome': '/isolated/codex-home',
          'userAgent': 'glaze/0.150.0 (Test OS; arm64) unknown (glaze; 0.7.0)',
        }, codexHome: '/isolated/codex-home'),
        throwsA(isA<CodexIsolationException>()),
      );
    });
  });

  group('CodexExecutableLocator', () {
    test(
      'rejects script wrappers and accepts native executable headers',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'glaze-codex-executable-test-',
        );
        addTearDown(() async {
          if (await directory.exists()) await directory.delete(recursive: true);
        });
        final script = File(p.join(directory.path, 'codex.cmd'))
          ..writeAsStringSync('@node codex.js');
        final machO = File(p.join(directory.path, 'codex'))
          ..writeAsBytesSync(<int>[0xcf, 0xfa, 0xed, 0xfe]);
        final windowsExecutable = File(p.join(directory.path, 'codex.exe'))
          ..writeAsBytesSync(<int>[0x4d, 0x5a, 0x90, 0x00]);

        expect(
          CodexExecutableLocator.isNativeExecutable(
            script.path,
            isWindows: true,
          ),
          isFalse,
        );
        expect(
          CodexExecutableLocator.isNativeExecutable(
            windowsExecutable.path,
            isWindows: true,
          ),
          isTrue,
        );
        expect(
          CodexExecutableLocator.isNativeExecutable(
            machO.path,
            isWindows: false,
          ),
          isTrue,
        );
        expect(
          CodexExecutableLocator.isNativeExecutable(
            script.path,
            isWindows: false,
          ),
          isFalse,
        );
      },
    );
  });

  group('CodexProcessTreeTerminator', () {
    test('builds an absolute non-shell Windows tree-kill command', () {
      expect(
        CodexProcessTreeTerminator.windowsTaskkillPath(const <String, String>{
          'SystemRoot': r'C:\Windows',
        }),
        r'C:\Windows\System32\taskkill.exe',
      );
      expect(CodexProcessTreeTerminator.taskkillArguments(4242), <String>[
        '/PID',
        '4242',
        '/T',
        '/F',
      ]);
      expect(
        () => CodexProcessTreeTerminator.windowsTaskkillPath(
          const <String, String>{'SystemRoot': r'relative\windows'},
        ),
        throwsA(isA<CodexIsolationException>()),
      );
    });
  });

  group('CodexHostPolicyGuard', () {
    test('derives the external Windows host-skill root', () {
      expect(
        CodexHostPolicyGuard.windowsHostSkillsPath(r'C:\Users\glaze-user'),
        r'C:\Users\glaze-user\.agents\skills',
      );
      expect(
        () => CodexHostPolicyGuard.windowsHostSkillsPath(r'relative\profile'),
        throwsA(isA<CodexIsolationException>()),
      );
    });
  });

  group('CodexSessionLifetimeCoordinator', () {
    test('serialises authenticated process lifetimes', () async {
      final first = await CodexSessionLifetimeCoordinator.acquire();
      var secondEntered = false;
      final secondFuture = CodexSessionLifetimeCoordinator.acquire().then((
        lease,
      ) {
        secondEntered = true;
        return lease;
      });

      await Future<void>.delayed(Duration.zero);
      expect(secondEntered, isFalse);

      first.release();
      final second = await secondFuture;
      expect(secondEntered, isTrue);
      second.release();
    });

    test(
      'removes a cancelled waiter without overlapping its predecessor',
      () async {
        final first = await CodexSessionLifetimeCoordinator.acquire();
        final cancellationSignal = Completer<void>();
        var cancelled = false;
        final cancellation = CodexStartupCancellation(
          isCancelled: () => cancelled,
          whenCancelled: cancellationSignal.future,
        );
        final waiting = CodexSessionLifetimeCoordinator.acquire(
          cancellation: cancellation,
        );

        cancelled = true;
        cancellationSignal.complete();
        await expectLater(
          waiting,
          throwsA(isA<CodexStartupCancelledException>()),
        );

        var successorEntered = false;
        final successorFuture = CodexSessionLifetimeCoordinator.acquire().then((
          lease,
        ) {
          successorEntered = true;
          return lease;
        });
        await Future<void>.delayed(Duration.zero);
        expect(successorEntered, isFalse);

        first.release();
        final successor = await successorFuture;
        expect(successorEntered, isTrue);
        successor.release();
      },
    );
  });

  group('CodexInvocationPolicy', () {
    test('opts into experimental empty-environment enforcement', () {
      const codexHome = '/isolated/codex-home';
      final arguments = CodexInvocationPolicy.arguments(codexHome);
      expect(
        CodexInvocationPolicy.initializeParams['capabilities'],
        <String, dynamic>{'experimentalApi': true},
      );
      expect(arguments.first, '--strict-config');
      expect(arguments.last, 'app-server');
      expect(arguments, contains('features.shell_snapshot=false'));
      expect(arguments, contains('features.code_mode=false'));
      expect(arguments, contains('features.code_mode_host=false'));
      expect(arguments, contains('features.code_mode_only=false'));
      expect(arguments, contains('features.web_search_cached=false'));
      expect(arguments, contains('features.web_search_request=false'));
      expect(arguments, contains('features.standalone_web_search=false'));
      expect(arguments, contains('web_search="disabled"'));
      expect(arguments, contains('otel.exporter="none"'));
      expect(arguments, contains('chatgpt_base_url="https://127.0.0.1:1"'));
      expect(arguments, contains('project_root_markers=[]'));
      expect(arguments, contains('tools.update_plan.enabled=false'));
      expect(
        arguments,
        contains('tools.experimental_request_user_input.enabled=false'),
      );
      expect(
        arguments,
        contains(
          'model_catalog_json=${jsonEncode(CodexInvocationPolicy.modelCatalogPath(codexHome))}',
        ),
      );
    });
  });

  group('CodexIsolatedHome', () {
    test('bundles the exact safety-restricted Codex model catalogue', () async {
      final data = await rootBundle.load(CodexIsolatedHome.modelCatalogAsset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );

      expect(bytes, hasLength(192980));
      expect(
        sha256.convert(bytes).toString(),
        CodexIsolatedHome.modelCatalogSha256,
      );
      final catalog = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final models = catalog['models'] as List<dynamic>;
      expect(models, isNotEmpty);
      expect(
        models.every(
          (model) =>
              model is Map<String, dynamic> && model['tool_mode'] == null,
        ),
        isTrue,
      );
    });

    test('removes a managed-policy cache before each process start', () async {
      final home = await Directory.systemTemp.createTemp(
        'glaze-codex-cache-test-',
      );
      addTearDown(() async {
        if (await home.exists()) await home.delete(recursive: true);
      });
      final cache = File(
        p.join(home.path, CodexIsolatedHome.cloudConfigCacheFileName),
      );

      await cache.writeAsString('first');
      await CodexIsolatedHome.removeCloudConfigCache(home.path);
      expect(await cache.exists(), isFalse);

      await cache.writeAsString('second');
      await CodexIsolatedHome.removeCloudConfigCache(home.path);
      expect(await cache.exists(), isFalse);
    });
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
            'CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED': '0',
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
        expect(
          environment['CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED'],
          '1',
        );
        expect(environment['PATH'], '/usr/local/bin:/usr/bin');
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
          'HTTPS_PROXY',
          'NO_PROXY',
          'SSL_CERT_FILE',
          'NODE_EXTRA_CA_CERTS',
        ]) {
          expect(environment, isNot(contains(secret)), reason: secret);
        }
      },
    );
  });
}
