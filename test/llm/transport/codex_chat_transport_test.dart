import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/reasoning_effort.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/codex_account_service.dart';
import 'package:glaze_flutter/core/llm/transport/codex_app_server_client.dart';
import 'package:glaze_flutter/core/llm/transport/codex_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';

class _RecordedRequest {
  const _RecordedRequest(this.method, this.params);

  final String method;
  final Map<String, dynamic> params;
}

class _FakeCodexSession implements CodexAppServerSession {
  final StreamController<CodexAppServerNotification> _notifications =
      StreamController<CodexAppServerNotification>.broadcast(sync: true);
  final List<_RecordedRequest> requests = <_RecordedRequest>[];

  String? accountType = 'chatgpt';
  String? planType = 'plus';
  bool ephemeral = true;
  String approvalPolicy = 'never';
  Map<String, dynamic> sandbox = const <String, dynamic>{
    'type': 'readOnly',
    'networkAccess': false,
  };
  List<Object> instructionSources = const [];
  List<Object> nestedInstructionSources = const [];
  Object? instructionSourcesOverride;
  Completer<Map<String, dynamic>>? blockedThreadStart;
  String threadReadStatus = 'completed';
  String? threadReadError;
  bool malformedThreadRead = false;
  void Function(_FakeCodexSession session)? onTurnStart;
  bool closed = false;

  @override
  Stream<CodexAppServerNotification> get notifications => _notifications.stream;

  void emit(String method, Map<String, dynamic> params) {
    if (closed) return;
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
    switch (method) {
      case 'account/read':
        return <String, dynamic>{
          'account': accountType == null
              ? null
              : <String, dynamic>{
                  'type': accountType,
                  if (planType != null) 'planType': planType,
                },
        };
      case 'thread/start':
        final blocked = blockedThreadStart;
        if (blocked != null) return blocked.future;
        return <String, dynamic>{
          'thread': <String, dynamic>{
            'id': 'thread-1',
            'ephemeral': ephemeral,
            if (nestedInstructionSources.isNotEmpty)
              'instructionSources': nestedInstructionSources,
          },
          'approvalPolicy': approvalPolicy,
          'sandbox': Map<String, dynamic>.from(sandbox),
          'instructionSources':
              instructionSourcesOverride ?? instructionSources,
        };
      case 'thread/inject_items':
        return const <String, dynamic>{};
      case 'turn/start':
        final callback = onTurnStart;
        if (callback != null) {
          scheduleMicrotask(() => callback(this));
        }
        return <String, dynamic>{
          'turn': <String, dynamic>{'id': 'turn-1'},
        };
      case 'thread/read':
        if (malformedThreadRead) {
          return <String, dynamic>{'thread': 'malformed'};
        }
        return <String, dynamic>{
          'thread': <String, dynamic>{
            'id': 'thread-1',
            'turns': <Object>[
              <String, dynamic>{
                'id': 'turn-1',
                'status': threadReadStatus,
                if (threadReadError != null)
                  'error': <String, dynamic>{'message': threadReadError},
              },
            ],
          },
        };
      case 'turn/interrupt':
        return const <String, dynamic>{};
      default:
        fail('Unexpected App Server request: $method');
    }
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

class _Update {
  const _Update(this.text, this.reasoning);

  final String text;
  final String? reasoning;
}

class _RunResult {
  String? text;
  String? reasoning;
  String? rawResponse;
  Object? error;
  final List<_Update> updates = <_Update>[];
}

ChatTransportRequest _request({
  List<Map<String, dynamic>> messages = const [
    {'role': 'user', 'content': 'Tell me a story.'},
  ],
  bool stream = true,
  bool requestReasoning = false,
  String reasoningEffort = 'auto',
  bool omitReasoning = false,
  bool? showNativeReasoning,
  List<Map<String, dynamic>>? tools,
}) => ChatTransportRequest(
  endpoint: '',
  apiKey: '',
  model: 'gpt-test',
  messages: messages,
  maxTokens: 256,
  temperature: 0.7,
  topP: 0.9,
  stream: stream,
  requestReasoning: requestReasoning,
  reasoningEffort: reasoningEffort,
  omitReasoning: omitReasoning,
  showNativeReasoning: showNativeReasoning,
  tools: tools,
);

Future<_RunResult> _run(
  _FakeCodexSession session, {
  ChatTransportRequest? request,
  CancelToken? cancelToken,
  void Function(String? workingDirectory)? onCreateSession,
  Duration setupRequestTimeout = const Duration(seconds: 30),
}) async {
  final result = _RunResult();
  final transport = CodexChatTransport(
    sessionFactory: ({String? workingDirectory}) async {
      onCreateSession?.call(workingDirectory);
      return session;
    },
    setupRequestTimeout: setupRequestTimeout,
  );
  await transport.stream(
    request: request ?? _request(),
    cancelToken: cancelToken,
    onUpdate: (text, reasoning) {
      result.updates.add(_Update(text, reasoning));
    },
    onComplete: (text, reasoning, {rawResponseJson}) {
      result.text = text;
      result.reasoning = reasoning;
      result.rawResponse = rawResponseJson;
    },
    onError: (error) {
      result.error = error;
    },
  );
  return result;
}

void _emitStarted(_FakeCodexSession session) {
  session.emit('turn/started', {
    'threadId': 'thread-1',
    'turn': {'id': 'turn-1'},
  });
}

void _emitAgentStarted(
  _FakeCodexSession session, {
  required String id,
  String? phase,
}) {
  session.emit('item/started', {
    'threadId': 'thread-1',
    'turnId': 'turn-1',
    'item': {'id': id, 'type': 'agentMessage', 'phase': ?phase},
  });
}

void _emitAgentDelta(
  _FakeCodexSession session, {
  required String id,
  required String text,
}) {
  session.emit('item/agentMessage/delta', {
    'threadId': 'thread-1',
    'turnId': 'turn-1',
    'itemId': id,
    'delta': text,
  });
}

void _emitAgentCompleted(
  _FakeCodexSession session, {
  required String id,
  String? phase,
  required String text,
}) {
  session.emit('item/completed', {
    'threadId': 'thread-1',
    'turnId': 'turn-1',
    'item': {'id': id, 'type': 'agentMessage', 'phase': ?phase, 'text': text},
  });
}

void _emitTurnCompleted(
  _FakeCodexSession session, {
  String status = 'completed',
  String? error,
}) {
  session.emit('turn/completed', {
    'threadId': 'thread-1',
    'turnId': 'turn-1',
    'turn': {
      'id': 'turn-1',
      'status': status,
      if (error != null) 'error': {'message': error},
    },
  });
}

void main() {
  group('CodexChatTransport', () {
    test(
      'uses an ephemeral read-only thread and emits final-answer content only',
      () async {
        final session = _FakeCodexSession();
        session.onTurnStart = (session) {
          _emitStarted(session);
          _emitAgentStarted(session, id: 'comment-1', phase: 'commentary');
          _emitAgentDelta(session, id: 'comment-1', text: 'internal progress');
          _emitAgentCompleted(
            session,
            id: 'comment-1',
            phase: 'commentary',
            text: 'internal progress',
          );
          session.emit('item/reasoning/summaryTextDelta', {
            'threadId': 'thread-1',
            'turnId': 'turn-1',
            'delta': 'brief reason',
          });
          _emitAgentStarted(session, id: 'answer-1', phase: 'final_answer');
          _emitAgentDelta(session, id: 'answer-1', text: 'Final answer');
          _emitAgentCompleted(
            session,
            id: 'answer-1',
            phase: 'final_answer',
            text: 'Final answer',
          );
          session.emit('thread/tokenUsage/updated', {
            'threadId': 'thread-1',
            'turnId': 'turn-1',
            'tokenUsage': {'inputTokens': 12, 'outputTokens': 3},
          });
          _emitTurnCompleted(session);
        };
        String? workingDirectory;

        final result = await _run(
          session,
          request: _request(
            messages: const [
              {'role': 'system', 'content': 'Stay in character.'},
              {'role': 'user', 'content': 'First prompt'},
              {'role': 'assistant', 'content': 'First answer'},
              {'role': 'user', 'content': 'Continue'},
            ],
            requestReasoning: true,
            reasoningEffort: 'max',
            showNativeReasoning: true,
          ),
          onCreateSession: (value) => workingDirectory = value,
        );

        expect(result.error, isNull);
        expect(result.text, 'Final answer');
        expect(result.reasoning, 'brief reason');
        expect(result.updates.map((update) => update.text), [
          '',
          'Final answer',
        ]);
        expect(result.updates.map((update) => update.reasoning), [
          'brief reason',
          null,
        ]);
        expect(result.rawResponse, isNot(contains('internal progress')));
        final raw = Map<String, dynamic>.from(
          jsonDecode(result.rawResponse!) as Map,
        );
        expect(raw['status'], 'completed');
        expect(raw['token_usage'], {'inputTokens': 12, 'outputTokens': 3});

        final threadStart = session.requests.singleWhere(
          (request) => request.method == 'thread/start',
        );
        expect(threadStart.params['model'], 'gpt-test');
        expect(threadStart.params['cwd'], workingDirectory);
        expect(threadStart.params['approvalPolicy'], 'never');
        expect(threadStart.params['sandbox'], 'read-only');
        expect(threadStart.params['ephemeral'], isTrue);
        expect(threadStart.params['baseInstructions'], contains('Never call'));
        expect(threadStart.params, isNot(contains('developerInstructions')));
        expect(workingDirectory, isNotNull);

        final inject = session.requests.singleWhere(
          (request) => request.method == 'thread/inject_items',
        );
        final items = (inject.params['items'] as List)
            .cast<Map<String, dynamic>>();
        expect(items, hasLength(3));
        expect(items.first['role'], 'developer');
        expect(items.last['role'], 'assistant');

        final turnStart = session.requests.singleWhere(
          (request) => request.method == 'turn/start',
        );
        expect(turnStart.params['approvalPolicy'], 'never');
        expect(turnStart.params['sandboxPolicy'], {
          'type': 'readOnly',
          'networkAccess': false,
        });
        expect(turnStart.params['summary'], 'auto');
        expect(turnStart.params['effort'], 'high');
        expect(turnStart.params['input'], [
          {'type': 'text', 'text': 'Continue', 'text_elements': <Object>[]},
        ]);
        expect(session.closed, isTrue);
      },
    );

    test('applies a trailing assistant prefill exactly once', () async {
      final session = _FakeCodexSession();
      session.onTurnStart = (session) {
        _emitStarted(session);
        _emitAgentStarted(session, id: 'answer-1', phase: 'final_answer');
        _emitAgentDelta(session, id: 'answer-1', text: 'upon a time');
        _emitAgentCompleted(
          session,
          id: 'answer-1',
          phase: 'final_answer',
          text: 'Once upon a time',
        );
        _emitTurnCompleted(session);
      };

      final result = await _run(
        session,
        request: _request(
          messages: const [
            {'role': 'user', 'content': 'Start a tale.'},
            {'role': 'assistant', 'content': 'Once '},
          ],
        ),
      );

      expect(result.error, isNull);
      expect(result.text, 'Once upon a time');
      expect(result.updates.map((update) => update.text), ['upon a time']);
      final inject = session.requests.singleWhere(
        (request) => request.method == 'thread/inject_items',
      );
      final items = (inject.params['items'] as List)
          .cast<Map<String, dynamic>>();
      expect(items.last['role'], 'assistant');
      expect(items.last['content'], [
        {'type': 'output_text', 'text': 'Once '},
      ]);
    });

    test('streams legacy agent messages whose phase is omitted', () async {
      final session = _FakeCodexSession();
      session.onTurnStart = (session) {
        _emitStarted(session);
        _emitAgentStarted(session, id: 'legacy-answer');
        _emitAgentDelta(session, id: 'legacy-answer', text: 'Legacy answer');
        _emitAgentCompleted(
          session,
          id: 'legacy-answer',
          text: 'Legacy answer',
        );
        _emitTurnCompleted(session);
      };

      final result = await _run(session);

      expect(result.error, isNull);
      expect(result.text, 'Legacy answer');
      expect(result.updates.map((update) => update.text), ['Legacy answer']);
    });

    test(
      'does not request or expose reasoning when reasoning is off',
      () async {
        final session = _FakeCodexSession();
        session.onTurnStart = (session) {
          _emitStarted(session);
          session.emit('item/reasoning/summaryTextDelta', {
            'threadId': 'thread-1',
            'turnId': 'turn-1',
            'delta': 'must stay hidden',
          });
          _emitAgentStarted(session, id: 'answer-1', phase: 'final_answer');
          _emitAgentCompleted(
            session,
            id: 'answer-1',
            phase: 'final_answer',
            text: 'Answer',
          );
          _emitTurnCompleted(session);
        };

        final result = await _run(session);

        expect(result.error, isNull);
        expect(result.reasoning, isNull);
        expect(
          result.updates.every((update) => update.reasoning == null),
          isTrue,
        );
        final turnStart = session.requests.singleWhere(
          (request) => request.method == 'turn/start',
        );
        expect(turnStart.params['summary'], 'none');
      },
    );

    test('bounds a wedged setup request and closes the session', () async {
      final session = _FakeCodexSession()
        ..blockedThreadStart = Completer<Map<String, dynamic>>();

      final result = await _run(
        session,
        setupRequestTimeout: const Duration(milliseconds: 20),
      );

      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), contains('thread/start'));
      expect(session.closed, isTrue);
    });

    test('rejects any external instruction source before generation', () async {
      final session = _FakeCodexSession()
        ..instructionSources = const ['/outside/AGENTS.md'];

      final result = await _run(session);

      expect(result.text, isNull);
      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), contains('instruction sources'));
      expect(
        session.requests.any((request) => request.method == 'turn/start'),
        isFalse,
      );
      expect(session.closed, isTrue);
    });

    test('rejects malformed instruction-source metadata', () async {
      final session = _FakeCodexSession()
        ..instructionSourcesOverride = <String, Object>{'unexpected': true};

      final result = await _run(session);

      expect(result.text, isNull);
      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), contains('instruction sources'));
      expect(
        session.requests.any((request) => request.method == 'turn/start'),
        isFalse,
      );
      expect(session.closed, isTrue);
    });

    test(
      'rejects nested instruction sources when the top level is empty',
      () async {
        final session = _FakeCodexSession()
          ..nestedInstructionSources = const ['/outside/AGENTS.md'];

        final result = await _run(session);

        expect(result.text, isNull);
        expect(result.error, isA<CodexAppServerException>());
        expect(result.error.toString(), contains('instruction sources'));
        expect(
          session.requests.any((request) => request.method == 'turn/start'),
          isFalse,
        );
      },
    );

    test('rejects a non-ephemeral thread before injecting history', () async {
      final session = _FakeCodexSession()..ephemeral = false;

      final result = await _run(session);

      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), contains('ephemeral'));
      expect(
        session.requests.any(
          (request) => request.method == 'thread/inject_items',
        ),
        isFalse,
      );
    });

    test('rejects a relaxed effective approval policy', () async {
      final session = _FakeCodexSession()..approvalPolicy = 'on-request';

      final result = await _run(session);

      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), contains('never-approve'));
      expect(
        session.requests.any(
          (request) => request.method == 'thread/inject_items',
        ),
        isFalse,
      );
    });

    test('rejects a relaxed effective sandbox', () async {
      final session = _FakeCodexSession()
        ..sandbox = <String, dynamic>{
          'type': 'workspaceWrite',
          'networkAccess': true,
        };

      final result = await _run(session);

      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), contains('read-only, offline'));
      expect(
        session.requests.any(
          (request) => request.method == 'thread/inject_items',
        ),
        isFalse,
      );
    });

    test('rejects malformed effective network access metadata', () async {
      final session = _FakeCodexSession()
        ..sandbox = <String, dynamic>{
          'type': 'readOnly',
          'networkAccess': 'false',
        };

      final result = await _run(session);

      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), contains('read-only, offline'));
      expect(
        session.requests.any(
          (request) => request.method == 'thread/inject_items',
        ),
        isFalse,
      );
    });

    test(
      'rejects an API-billed Codex account before starting a thread',
      () async {
        final session = _FakeCodexSession()..accountType = 'apiKey';

        final result = await _run(session);

        expect(result.error, isA<CodexChatGptAccountRequiredException>());
        expect(session.requests.map((request) => request.method), [
          'account/read',
        ]);
        expect(session.closed, isTrue);
      },
    );

    test('uses thread/read when 0.147 omits turn/completed', () async {
      final session = _FakeCodexSession();
      session.onTurnStart = (session) {
        _emitStarted(session);
        _emitAgentStarted(session, id: 'answer-1', phase: 'final_answer');
        _emitAgentDelta(session, id: 'answer-1', text: 'Recovered answer');
        _emitAgentCompleted(
          session,
          id: 'answer-1',
          phase: 'final_answer',
          text: 'Recovered answer',
        );
        session.emit('thread/status/changed', {
          'threadId': 'thread-1',
          'status': {'type': 'idle'},
        });
      };

      final result = await _run(session);

      expect(result.error, isNull);
      expect(result.text, 'Recovered answer');
      expect(
        session.requests.where((request) => request.method == 'thread/read'),
        hasLength(1),
      );
    });

    test('surfaces a failed turn status and its message', () async {
      final session = _FakeCodexSession();
      session.onTurnStart = (session) {
        _emitStarted(session);
        _emitTurnCompleted(
          session,
          status: 'failed',
          error: 'Generation failed safely.',
        );
      };

      final result = await _run(session);

      expect(result.text, isNull);
      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), 'Generation failed safely.');
    });

    test('ignores uncorrelated completion notifications', () async {
      final session = _FakeCodexSession();
      session.onTurnStart = (session) {
        _emitStarted(session);
        _emitAgentStarted(session, id: 'answer-1', phase: 'final_answer');
        _emitAgentDelta(session, id: 'answer-1', text: 'partial');
        session.emit('turn/completed', {
          'turn': {'id': 'turn-1', 'status': 'completed'},
        });
        session.emit('turn/completed', {
          'threadId': 'thread-1',
          'turn': {'id': 'another-turn', 'status': 'completed'},
        });
        _emitTurnCompleted(
          session,
          status: 'failed',
          error: 'Correlated failure.',
        );
      };

      final result = await _run(session);

      expect(result.text, isNull);
      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), 'Correlated failure.');
    });

    test(
      'surfaces a terminal error notification without turn/completed',
      () async {
        final session = _FakeCodexSession();
        session.onTurnStart = (session) {
          _emitStarted(session);
          session.emit('error', {
            'threadId': 'thread-1',
            'turnId': 'turn-1',
            'willRetry': false,
            'error': {'message': 'Terminal App Server failure.'},
          });
        };

        final result = await _run(session);

        expect(result.text, isNull);
        expect(result.error, isA<CodexAppServerException>());
        expect(result.error.toString(), 'Terminal App Server failure.');
        expect(
          session.requests.any((request) => request.method == 'thread/read'),
          isFalse,
        );
      },
    );

    test('surfaces an interrupted turn instead of partial output', () async {
      final session = _FakeCodexSession();
      session.onTurnStart = (session) {
        _emitStarted(session);
        _emitAgentStarted(session, id: 'answer-1', phase: 'final_answer');
        _emitAgentDelta(session, id: 'answer-1', text: 'partial');
        _emitTurnCompleted(session, status: 'interrupted');
      };

      final result = await _run(session);

      expect(result.text, isNull);
      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), contains('interrupted'));
    });

    test(
      'rejects an unknown terminal status instead of committing output',
      () async {
        final session = _FakeCodexSession();
        session.onTurnStart = (session) {
          _emitStarted(session);
          _emitAgentStarted(session, id: 'answer-1', phase: 'final_answer');
          _emitAgentDelta(session, id: 'answer-1', text: 'partial');
          _emitTurnCompleted(session, status: 'cancelled');
        };

        final result = await _run(session);

        expect(result.text, isNull);
        expect(result.error, isA<CodexAppServerException>());
        expect(result.error.toString(), contains('unsupported turn status'));
      },
    );

    test('rejects a non-terminal thread/read fallback status', () async {
      final session = _FakeCodexSession()..threadReadStatus = 'inProgress';
      session.onTurnStart = (session) {
        _emitStarted(session);
        _emitAgentCompleted(
          session,
          id: 'answer-1',
          phase: 'final_answer',
          text: 'partial',
        );
        session.emit('thread/status/changed', {
          'threadId': 'thread-1',
          'status': {'type': 'idle'},
        });
      };

      final result = await _run(session);

      expect(result.text, isNull);
      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), contains('could not be verified'));
      expect(
        session.requests.where((request) => request.method == 'thread/read'),
        hasLength(3),
      );
    });

    test('rejects a malformed thread/read fallback response', () async {
      final session = _FakeCodexSession()..malformedThreadRead = true;
      session.onTurnStart = (session) {
        _emitStarted(session);
        _emitAgentCompleted(
          session,
          id: 'answer-1',
          phase: 'final_answer',
          text: 'partial',
        );
        session.emit('thread/status/changed', {
          'threadId': 'thread-1',
          'status': {'type': 'idle'},
        });
      };

      final result = await _run(session);

      expect(result.text, isNull);
      expect(result.error, isA<CodexAppServerException>());
      expect(result.error.toString(), contains('could not be verified'));
    });

    test('interrupts an active turn when its cancel token fires', () async {
      final session = _FakeCodexSession();
      final announced = Completer<void>();
      session.onTurnStart = (session) {
        _emitStarted(session);
        announced.complete();
      };
      final token = CancelToken();

      final pending = _run(session, cancelToken: token);
      await announced.future;
      await Future<void>.delayed(Duration.zero);
      token.cancel('stop requested');
      final result = await pending;

      expect(result.text, isNull);
      expect(result.error, isA<DioException>());
      expect(
        session.requests.where((request) => request.method == 'turn/interrupt'),
        hasLength(1),
      );
      final interrupt = session.requests.singleWhere(
        (request) => request.method == 'turn/interrupt',
      );
      expect(interrupt.params, {'threadId': 'thread-1', 'turnId': 'turn-1'});
      expect(session.closed, isTrue);
    });

    test(
      'rejects native tool definitions without starting a process',
      () async {
        final session = _FakeCodexSession();
        var created = false;

        final result = await _run(
          session,
          request: _request(
            tools: const [
              {
                'type': 'function',
                'function': {'name': 'unsafe_tool'},
              },
            ],
          ),
          onCreateSession: (_) => created = true,
        );

        expect(result.error, isA<CodexAppServerException>());
        expect(result.error.toString(), contains('native tool definitions'));
        expect(created, isFalse);
        expect(session.requests, isEmpty);
      },
    );

    test('does not emit chunk callbacks when streaming is disabled', () async {
      final session = _FakeCodexSession();
      session.onTurnStart = (session) {
        _emitStarted(session);
        _emitAgentStarted(session, id: 'answer-1', phase: 'final_answer');
        _emitAgentDelta(session, id: 'answer-1', text: 'One shot');
        _emitAgentCompleted(
          session,
          id: 'answer-1',
          phase: 'final_answer',
          text: 'One shot',
        );
        _emitTurnCompleted(session);
      };

      final result = await _run(session, request: _request(stream: false));

      expect(result.text, 'One shot');
      expect(result.updates, isEmpty);
    });
  });

  group('Codex reasoning effort', () {
    test('maps the Glaze scale onto supported Codex values', () {
      expect(
        resolveReasoningEffort(
          protocol: LlmProtocol.codexChatgpt,
          effort: 'auto',
          model: 'gpt-5.6',
        ),
        isNull,
      );
      expect(
        resolveReasoningEffort(
          protocol: LlmProtocol.codexChatgpt,
          effort: 'min',
          model: 'gpt-5.6',
        ),
        'low',
      );
      expect(
        resolveReasoningEffort(
          protocol: LlmProtocol.codexChatgpt,
          effort: 'medium',
          model: 'gpt-5.6',
        ),
        'medium',
      );
      expect(
        resolveReasoningEffort(
          protocol: LlmProtocol.codexChatgpt,
          effort: 'max',
          model: 'gpt-5.6',
        ),
        'high',
      );
    });
  });
}
