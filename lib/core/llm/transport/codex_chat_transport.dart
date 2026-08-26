import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../converters/reasoning_effort.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'codex_account_service.dart';
import 'codex_app_server_client.dart';
import 'codex_prompt_adapter.dart';
import 'llm_protocol.dart';

typedef CodexTurnWorkingDirectoryFactory = Future<Directory> Function();

Future<Directory> defaultCodexTurnWorkingDirectoryFactory() =>
    CodexIsolatedHome.createTurnWorkingDirectory();

/// Desktop ChatGPT-subscription transport backed by local Codex App Server.
///
/// Authentication is owned by Codex inside Glaze's isolated CODEX_HOME. The
/// transport never receives an OAuth token and rejects API-key-authenticated
/// Codex accounts so a subscription connection cannot silently use API billing.
class CodexChatTransport implements ChatTransport {
  CodexChatTransport({
    CodexSessionFactory? sessionFactory,
    CodexAccountService? accountService,
    this.setupRequestTimeout = const Duration(seconds: 30),
    CodexTurnWorkingDirectoryFactory? workingDirectoryFactory,
  }) : _sessionFactory = sessionFactory ?? defaultCodexSessionFactory,
       _accountService =
           accountService ??
           CodexAccountService(
             sessionFactory: sessionFactory ?? defaultCodexSessionFactory,
           ),
       _workingDirectoryFactory =
           workingDirectoryFactory ?? defaultCodexTurnWorkingDirectoryFactory,
       assert(setupRequestTimeout > Duration.zero);

  final CodexSessionFactory _sessionFactory;
  final CodexAccountService _accountService;
  final CodexTurnWorkingDirectoryFactory _workingDirectoryFactory;
  final Duration setupRequestTimeout;

  static const String _baseInstructions = '''
You are the text-completion engine embedded in Glaze, a local conversation and roleplay application.

Generate only the next assistant message for the supplied conversation. Follow developer messages contained in the injected conversation as its instructions. Do not discuss this host application, coding, files, tools, policies, or your process unless the supplied conversation explicitly asks for that content.

Never call or request a tool, shell command, file operation, network operation, app, connector, skill, plugin, sub-agent, approval, or user-input prompt. Return the final assistant message directly, without a preamble, progress update, analysis, citation, or wrapper.
''';

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    var callbackSettled = false;
    Object? pendingError;
    String? completedText;
    String? completedReasoning;
    String? completedRawResponse;
    CodexAppServerSession? session;
    StreamSubscription<CodexAppServerNotification>? notificationSubscription;
    Directory? workspace;

    void reportError(Object error) {
      if (callbackSettled) return;
      callbackSettled = true;
      onError?.call(error);
    }

    try {
      _throwIfCancelled(cancelToken);
      if (request.tools?.isNotEmpty == true) {
        throw const CodexAppServerException(
          'Codex ChatGPT connections do not support Glaze native tool '
          'definitions.',
        );
      }

      workspace = await _workingDirectoryFactory();
      final startupTimeout = Completer<void>();
      var startupTimedOut = false;
      final userCancellation = cancelToken?.whenCancel.then<void>((_) {});
      final startupCancellation = CodexStartupCancellation(
        isCancelled: () => startupTimedOut || cancelToken?.isCancelled == true,
        whenCancelled: userCancellation == null
            ? startupTimeout.future
            : Future.any(<Future<void>>[
                startupTimeout.future,
                userCancellation,
              ]),
      );
      final sessionFuture = _sessionFactory(
        workingDirectory: workspace.path,
        startupCancellation: startupCancellation,
      );
      session = await _awaitSessionStart(
        sessionFuture,
        cancelToken,
        onTimeout: () {
          startupTimedOut = true;
          if (!startupTimeout.isCompleted) startupTimeout.complete();
        },
      );
      await _awaitSetupRequest(
        'account verification',
        _accountService.requireChatGpt(session),
        cancelToken,
      );
      _throwIfCancelled(cancelToken);

      final prepared = CodexPromptAdapter.prepare(request.messages);
      final threadParams = <String, dynamic>{
        if (request.model.trim().isNotEmpty) 'model': request.model.trim(),
        'modelProvider': CodexIsolationPolicy.provider,
        'allowProviderModelFallback': false,
        'cwd': workspace.path,
        'environments': <Object>[],
        'runtimeWorkspaceRoots': <Object>[],
        'selectedCapabilityRoots': <Object>[],
        'dynamicTools': <Object>[],
        'approvalPolicy': 'never',
        'sandbox': 'read-only',
        'ephemeral': true,
        'baseInstructions': _baseInstructions,
      };
      final threadResponse = await _awaitSetupRequest(
        'thread/start',
        session.request('thread/start', threadParams),
        cancelToken,
      );
      final rawThread = threadResponse['thread'];
      final thread = rawThread is Map
          ? Map<String, dynamic>.from(rawThread)
          : <String, dynamic>{};
      if (threadResponse['modelProvider'] != CodexIsolationPolicy.provider ||
          thread['modelProvider'] != CodexIsolationPolicy.provider) {
        throw const CodexIsolationException(
          'Codex did not preserve OpenAI as the thread provider. Generation '
          'was stopped before any conversation content was sent.',
        );
      }
      for (final instructionSources in <Object?>[
        threadResponse['instructionSources'],
        thread['instructionSources'],
      ]) {
        if (instructionSources != null &&
            (instructionSources is! List || instructionSources.isNotEmpty)) {
          throw const CodexAppServerException(
            'Codex reported invalid or external instruction sources for the '
            'Glaze session. Generation was stopped to preserve profile '
            'isolation.',
          );
        }
      }
      final effectiveSandbox = _map(threadResponse['sandbox']);
      final networkAccess = effectiveSandbox?['networkAccess'];
      final runtimeWorkspaceRoots = threadResponse['runtimeWorkspaceRoots'];
      if (threadResponse['approvalPolicy'] != 'never') {
        throw const CodexAppServerException(
          'Codex did not preserve the required never-approve policy.',
        );
      }
      if (effectiveSandbox?['type'] != 'readOnly' ||
          (networkAccess != null && networkAccess != false)) {
        throw const CodexAppServerException(
          'Codex did not preserve the required read-only, offline sandbox.',
        );
      }
      if (runtimeWorkspaceRoots is! List || runtimeWorkspaceRoots.isNotEmpty) {
        throw const CodexAppServerException(
          'Codex did not preserve the empty runtime workspace boundary.',
        );
      }
      final threadId = thread['id'];
      if (threadId is! String || threadId.isEmpty) {
        throw const CodexAppServerException(
          'Codex did not return a valid thread identifier.',
        );
      }
      if (thread['ephemeral'] != true) {
        throw const CodexAppServerException(
          'Codex refused to create an ephemeral Glaze thread.',
        );
      }
      _throwIfCancelled(cancelToken);

      if (prepared.injectedItems.isNotEmpty) {
        await _awaitSetupRequest(
          'thread/inject_items',
          session.request('thread/inject_items', <String, dynamic>{
            'threadId': threadId,
            'items': prepared.injectedItems,
          }),
          cancelToken,
        );
      }
      _throwIfCancelled(cancelToken);

      final observer = _CodexTurnObserver(
        threadId: threadId,
        assistantPrefill: prepared.assistantPrefill,
        emitUpdates: request.stream,
        showReasoning:
            request.requestReasoning &&
            (request.showNativeReasoning ?? !request.omitReasoning) &&
            !request.omitReasoning,
        onUpdate: onUpdate,
      );
      notificationSubscription = session.notifications.listen(
        observer.handle,
        onError: observer.fail,
        onDone: observer.closed,
      );

      final turnParams = <String, dynamic>{
        'threadId': threadId,
        'input': prepared.turnInput,
        'environments': <Object>[],
        'runtimeWorkspaceRoots': <Object>[],
        'approvalPolicy': 'never',
        'sandboxPolicy': <String, dynamic>{
          'type': 'readOnly',
          'networkAccess': false,
        },
        'summary': observer.showReasoning ? 'auto' : 'none',
      };
      if (request.requestReasoning &&
          !request.omitReasoning &&
          !request.omitReasoningEffort) {
        final effort = resolveReasoningEffort(
          protocol: LlmProtocol.codexChatgpt,
          effort: request.reasoningEffort,
          model: request.model,
        );
        if (effort != null) turnParams['effort'] = effort;
      }

      final turnResponse = await _awaitSetupRequest(
        'turn/start',
        session.request('turn/start', turnParams),
        cancelToken,
      );
      final rawTurn = turnResponse['turn'];
      final turn = rawTurn is Map
          ? Map<String, dynamic>.from(rawTurn)
          : <String, dynamic>{};
      final turnId = turn['id'];
      if (turnId is! String || turnId.isEmpty) {
        throw const CodexAppServerException(
          'Codex did not return a valid turn identifier.',
        );
      }
      observer.setTurnId(turnId);

      final cancellation = _interruptOnCancel(
        session: session,
        observer: observer,
        cancelToken: cancelToken,
      );
      final watchdog = Completer<_CodexTurnOutcome>();
      final watchdogTimer = Timer(_processWatchdog, () {
        if (!watchdog.isCompleted) {
          watchdog.completeError(
            const CodexAppServerException(
              'Codex did not finish the generation before the safety timeout.',
            ),
          );
        }
      });
      late final _CodexTurnOutcome outcome;
      try {
        outcome = await Future.any(<Future<_CodexTurnOutcome>>[
          observer.completed,
          _readCompletionFallback(session: session, observer: observer),
          watchdog.future,
          if (cancellation != null)
            cancellation.then<_CodexTurnOutcome>((_) {
              throw cancelToken!.cancelError!;
            }),
        ]);
      } finally {
        watchdogTimer.cancel();
      }
      _throwIfCancelled(cancelToken);

      switch (outcome.status) {
        case 'completed':
          break;
        case 'failed':
          throw CodexAppServerException(
            outcome.errorMessage ?? 'Codex generation failed.',
          );
        case 'interrupted':
          throw const CodexAppServerException(
            'Codex interrupted the generation before it completed.',
          );
        default:
          throw CodexAppServerException(
            outcome.errorMessage ??
                'Codex returned an unsupported turn status: '
                    '${outcome.status}.',
          );
      }

      completedText = outcome.text;
      completedReasoning = outcome.reasoning.isEmpty ? null : outcome.reasoning;
      completedRawResponse = jsonEncode(<String, dynamic>{
        'object': 'codex.app_server.completion',
        'thread_id': threadId,
        'turn_id': turnId,
        'status': outcome.status,
        'output_text': outcome.text,
        if (outcome.reasoning.isNotEmpty) 'reasoning': outcome.reasoning,
        if (outcome.tokenUsage != null) 'token_usage': outcome.tokenUsage,
      });
    } catch (error) {
      final cancellationError = cancelToken?.isCancelled == true
          ? cancelToken?.cancelError
          : null;
      pendingError = cancellationError ?? error;
    } finally {
      try {
        await notificationSubscription?.cancel();
      } catch (error) {
        pendingError = error;
      }
      try {
        await session?.close();
      } catch (error) {
        // Process shutdown is part of the isolation boundary. Never report a
        // successful completion or ordinary cancellation if it was not
        // verified.
        pendingError = error;
      }
      if (workspace != null) {
        try {
          await workspace.delete(recursive: true);
        } catch (error) {
          pendingError ??= CodexIsolationException(
            'Glaze could not remove its private Codex turn workspace: '
            '${workspace.path}',
          );
        }
      }
    }

    if (pendingError != null) {
      reportError(pendingError);
      return;
    }
    callbackSettled = true;
    onComplete?.call(
      completedText!,
      completedReasoning,
      rawResponseJson: completedRawResponse,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async {
    try {
      return await _accountService.listModels();
    } catch (_) {
      // ChatTransport's model-list contract is empty-on-failure. The settings
      // account preflight exposes the actionable installation/auth error.
      return const [];
    }
  }

  static void _throwIfCancelled(CancelToken? token) {
    if (token?.isCancelled == true) throw token!.cancelError!;
  }

  static Future<T> _cancelAware<T>(
    Future<T> operation,
    CancelToken? cancelToken,
  ) {
    if (cancelToken == null) return operation;
    return Future.any(<Future<T>>[
      operation,
      cancelToken.whenCancel.then<T>((_) => throw cancelToken.cancelError!),
    ]);
  }

  Future<T> _awaitSetupRequest<T>(
    String operation,
    Future<T> request,
    CancelToken? cancelToken, {
    void Function()? onTimeout,
  }) {
    final bounded = request.timeout(
      setupRequestTimeout,
      onTimeout: () {
        onTimeout?.call();
        throw CodexAppServerException(
          'Codex App Server did not respond to $operation in time.',
        );
      },
    );
    return _cancelAware(bounded, cancelToken);
  }

  Future<CodexAppServerSession> _awaitSessionStart(
    Future<CodexAppServerSession> start,
    CancelToken? cancelToken, {
    required void Function() onTimeout,
  }) async {
    var claimed = false;
    try {
      final session = await _awaitSetupRequest(
        'process startup',
        start,
        cancelToken,
        onTimeout: onTimeout,
      );
      claimed = true;
      return session;
    } finally {
      if (!claimed) {
        // Future.any cannot cancel Process.start. Retain ownership of a late
        // session and close it as soon as startup finishes, so cancellation or
        // timeout cannot orphan a verified App Server process.
        unawaited(
          start.then<void>(
            (lateSession) => lateSession.close(),
            onError: (Object _, StackTrace _) {},
          ),
        );
      }
    }
  }

  // Callers own first-chunk/idle timeout semantics through CancelToken. This
  // is only a final guard against a permanently wedged local process.
  static const Duration _processWatchdog = Duration(minutes: 30);

  static Future<_CodexTurnOutcome> _readCompletionFallback({
    required CodexAppServerSession session,
    required _CodexTurnObserver observer,
  }) async {
    await observer.fallbackReady;

    // Codex 0.147.0 can omit turn/completed. Once the final item is complete
    // and the thread is idle, read the authoritative turn state directly.
    // The short grace period also lets the token-usage event arrive.
    await Future<void>.delayed(const Duration(milliseconds: 75));
    if (observer.isCompleted) return observer.completed;

    Object? lastReadError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (observer.isCompleted) return observer.completed;
      try {
        final response = await session
            .request('thread/read', <String, dynamic>{
              'threadId': observer.threadId,
              'includeTurns': true,
            })
            .timeout(const Duration(seconds: 3));
        if (observer.isCompleted) return observer.completed;
        final thread = _map(response['thread']);
        final turns = thread?['turns'];
        if (turns is! List) {
          throw const CodexAppServerException(
            'Codex returned malformed thread status data.',
          );
        }
        final matchingTurn = turns.reversed
            .map(_map)
            .where((turn) => turn?['id'] == observer.turnId)
            .firstOrNull;
        if (matchingTurn == null) {
          throw const CodexAppServerException(
            'Codex omitted the generated turn from its status response.',
          );
        }
        final status = matchingTurn['status']?.toString();
        if (status == null) {
          throw const CodexAppServerException(
            'Codex returned a turn without a completion status.',
          );
        }
        if (status == 'inProgress') {
          lastReadError = const CodexAppServerException(
            'Codex still reported the generated turn as in progress.',
          );
        } else {
          final error = _map(matchingTurn['error']);
          observer.completeFromStatus(
            status,
            errorMessage: error?['message']?.toString(),
          );
          return observer.completed;
        }
      } catch (error) {
        lastReadError = error;
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    throw CodexAppServerException(
      'Codex final status could not be verified through thread/read: '
      '${lastReadError ?? 'unknown response error'}',
    );
  }

  static Map<String, dynamic>? _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  static Future<void>? _interruptOnCancel({
    required CodexAppServerSession session,
    required _CodexTurnObserver observer,
    required CancelToken? cancelToken,
  }) {
    if (cancelToken == null) return null;
    return cancelToken.whenCancel.then((_) async {
      try {
        await observer.turnStarted.timeout(const Duration(milliseconds: 750));
      } on TimeoutException {
        // Closing this operation's private process is the fail-closed fallback
        // when Codex never announces that the turn became active.
        return;
      }
      final turnId = observer.turnId;
      if (turnId == null) return;
      try {
        await session
            .request('turn/interrupt', <String, dynamic>{
              'threadId': observer.threadId,
              'turnId': turnId,
            })
            .timeout(const Duration(seconds: 2));
      } on CodexAppServerRpcException catch (error) {
        if (!error.message.contains('no active turn')) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        try {
          await session
              .request('turn/interrupt', <String, dynamic>{
                'threadId': observer.threadId,
                'turnId': turnId,
              })
              .timeout(const Duration(seconds: 1));
        } catch (_) {
          // The private process is closed by stream() immediately afterwards.
        }
      } catch (_) {
        // Process shutdown remains the bounded cancellation fallback.
      }
    });
  }
}

class _CodexTurnObserver {
  _CodexTurnObserver({
    required this.threadId,
    required this.assistantPrefill,
    required this.emitUpdates,
    required this.showReasoning,
    required this.onUpdate,
  });

  final String threadId;
  final bool emitUpdates;
  final bool showReasoning;
  final ChatTransportOnUpdate? onUpdate;
  final String assistantPrefill;
  final Completer<_CodexTurnOutcome> _completed =
      Completer<_CodexTurnOutcome>();
  final Completer<void> _turnStarted = Completer<void>();
  final Completer<void> _fallbackReady = Completer<void>();
  final Map<String, String?> _messagePhases = <String, String?>{};
  final StringBuffer _generatedText = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();

  String? turnId;
  Map<String, dynamic>? _tokenUsage;
  String? _lastErrorMessage;
  bool _finalAgentCompleted = false;
  bool _threadIdle = false;
  bool _turnIdConfirmed = false;
  String? _pendingCompletionStatus;
  String? _pendingCompletionError;

  Future<_CodexTurnOutcome> get completed => _completed.future;
  Future<void> get turnStarted => _turnStarted.future;
  Future<void> get fallbackReady => _fallbackReady.future;
  bool get isCompleted => _completed.isCompleted;

  void setTurnId(String value) {
    if (_completed.isCompleted) return;
    final announcedTurnId = turnId;
    if (announcedTurnId != null && announcedTurnId != value) {
      fail(
        const CodexAppServerException(
          'Codex returned inconsistent turn identifiers.',
        ),
      );
      return;
    }
    turnId = value;
    _turnIdConfirmed = true;
    final pendingStatus = _pendingCompletionStatus;
    if (pendingStatus != null) {
      _complete(status: pendingStatus, errorMessage: _pendingCompletionError);
    }
  }

  void handle(CodexAppServerNotification event) {
    if (_completed.isCompleted) return;
    final params = event.params;
    if (params['threadId'] != threadId) return;

    switch (event.method) {
      case 'error':
        if (!_matchesTurn(params['turnId'])) return;
        final error = _map(params['error']);
        _lastErrorMessage =
            error?['message']?.toString() ?? 'Codex generation failed.';
        if (params['willRetry'] == false) {
          _complete(status: 'failed', errorMessage: _lastErrorMessage);
        }
        break;
      case 'turn/started':
        final announcedTurn = _map(params['turn']);
        final announcedTurnId = announcedTurn?['id'];
        if (announcedTurnId is! String || announcedTurnId.isEmpty) return;
        if (turnId != null && turnId != announcedTurnId) return;
        turnId ??= announcedTurnId;
        if (!_turnStarted.isCompleted) _turnStarted.complete();
        break;
      case 'item/started':
        if (!_matchesTurn(params['turnId'])) return;
        final item = _map(params['item']);
        if (item?['type'] == 'agentMessage') {
          final id = item?['id'];
          if (id is String) _messagePhases[id] = item?['phase']?.toString();
        }
        break;
      case 'item/agentMessage/delta':
        if (!_matchesTurn(params['turnId'])) return;
        final itemId = params['itemId']?.toString();
        if (!_isFinalAnswer(itemId)) return;
        final delta = params['delta'];
        if (delta is String && delta.isNotEmpty) {
          _generatedText.write(delta);
          if (emitUpdates) onUpdate?.call(delta, null);
        }
        break;
      case 'item/reasoning/summaryTextDelta':
        if (!_matchesTurn(params['turnId'])) return;
        if (!showReasoning) return;
        final delta = params['delta'];
        if (delta is String && delta.isNotEmpty) {
          _reasoning.write(delta);
          if (emitUpdates) onUpdate?.call('', delta);
        }
        break;
      case 'item/completed':
        if (!_matchesTurn(params['turnId'])) return;
        final item = _map(params['item']);
        if (item?['type'] != 'agentMessage') return;
        final itemId = item?['id']?.toString();
        final phase = item?['phase']?.toString() ?? _messagePhases[itemId];
        if (phase == 'commentary') return;
        final finalText = item?['text'];
        if (finalText is String) {
          _generatedText
            ..clear()
            ..write(finalText);
        }
        _finalAgentCompleted = true;
        _signalFallbackIfReady();
        break;
      case 'thread/tokenUsage/updated':
        if (!_matchesTurn(params['turnId'])) return;
        _tokenUsage = _map(params['tokenUsage']);
        break;
      case 'thread/status/changed':
        final status = params['status'];
        final statusType = status is Map ? status['type'] : status;
        if (statusType == 'idle') {
          _threadIdle = true;
          if (!_finalAgentCompleted && _lastErrorMessage != null) {
            _complete(status: 'failed', errorMessage: _lastErrorMessage);
            return;
          }
          _signalFallbackIfReady();
        }
        break;
      case 'turn/completed':
        final turn = _map(params['turn']);
        if (!_matchesTurn(turn?['id'])) return;
        final rawStatus = turn?['status'];
        final status = rawStatus is String && rawStatus.isNotEmpty
            ? rawStatus
            : 'invalid';
        final error = _map(turn?['error']);
        final errorMessage = error?['message']?.toString();
        if (!_turnIdConfirmed) {
          _pendingCompletionStatus = status;
          _pendingCompletionError = errorMessage;
          return;
        }
        _complete(status: status, errorMessage: errorMessage);
        break;
      default:
        break;
    }
  }

  // Older and some model-specific App Server events omit `phase`. Treat an
  // unknown phase as answer content while continuing to suppress anything
  // explicitly labelled commentary.
  bool _isFinalAnswer(String? itemId) =>
      itemId != null && _messagePhases[itemId] != 'commentary';

  bool _matchesTurn(Object? candidate) =>
      turnId != null && candidate is String && candidate == turnId;

  void _signalFallbackIfReady() {
    if (_finalAgentCompleted && _threadIdle && !_fallbackReady.isCompleted) {
      _fallbackReady.complete();
    }
  }

  void completeFromStatus(String status, {String? errorMessage}) {
    _complete(status: status, errorMessage: errorMessage);
  }

  void _complete({required String status, String? errorMessage}) {
    if (_completed.isCompleted) return;
    if (!_fallbackReady.isCompleted) _fallbackReady.complete();
    _completed.complete(
      _CodexTurnOutcome(
        status: status,
        text: _combinedText,
        reasoning: _reasoning.toString(),
        errorMessage: errorMessage,
        tokenUsage: _tokenUsage,
      ),
    );
  }

  String get _combinedText {
    final generated = _generatedText.toString();
    if (assistantPrefill.isEmpty || generated.startsWith(assistantPrefill)) {
      return generated;
    }
    return '$assistantPrefill$generated';
  }

  void fail(Object error, [StackTrace? stackTrace]) {
    if (_completed.isCompleted) return;
    if (!_fallbackReady.isCompleted) _fallbackReady.complete();
    _completed.completeError(error, stackTrace ?? StackTrace.current);
  }

  void closed() {
    if (_completed.isCompleted) return;
    fail(
      const CodexAppServerException(
        'Codex App Server closed before generation completed.',
      ),
    );
  }

  static Map<String, dynamic>? _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;
}

class _CodexTurnOutcome {
  const _CodexTurnOutcome({
    required this.status,
    required this.text,
    required this.reasoning,
    this.errorMessage,
    this.tokenUsage,
  });

  final String status;
  final String text;
  final String reasoning;
  final String? errorMessage;
  final Map<String, dynamic>? tokenUsage;
}
