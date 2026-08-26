import 'dart:async';
import 'dart:io';

import 'codex_app_server_client.dart';

typedef CodexSessionFactory =
    Future<CodexAppServerSession> Function({String? workingDirectory});

Future<CodexAppServerSession> defaultCodexSessionFactory({
  String? workingDirectory,
}) => CodexAppServerClient.start(workingDirectory: workingDirectory);

class CodexAccountInfo {
  const CodexAccountInfo({required this.type, this.planType});

  final String type;
  final String? planType;

  bool get isChatGpt => type == 'chatgpt';

  static CodexAccountInfo? fromAccountRead(Map<String, dynamic> response) {
    final rawAccount = response['account'];
    if (rawAccount is! Map) return null;
    final account = Map<String, dynamic>.from(rawAccount);
    final type = account['type'];
    if (type is! String || type.isEmpty) return null;
    return CodexAccountInfo(
      type: type,
      planType: account['planType']?.toString(),
    );
  }
}

class CodexChatGptSignInRequiredException extends CodexAppServerException {
  const CodexChatGptSignInRequiredException()
    : super('Sign in to Codex with ChatGPT before using this connection.');
}

class CodexChatGptAccountRequiredException extends CodexAppServerException {
  const CodexChatGptAccountRequiredException()
    : super(
        'Codex is signed in with API billing, not ChatGPT. Choose “Sign in '
        'with ChatGPT” so this connection uses your ChatGPT subscription.',
      );
}

class CodexLoginCancelledException extends CodexAppServerException {
  const CodexLoginCancelledException()
    : super('ChatGPT sign-in was cancelled.');
}

class CodexAccountService {
  CodexAccountService({
    CodexSessionFactory? sessionFactory,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _sessionFactory = sessionFactory ?? defaultCodexSessionFactory,
       assert(requestTimeout > Duration.zero);

  final CodexSessionFactory _sessionFactory;
  final Duration requestTimeout;

  Future<CodexAccountInfo?> readAccount() async {
    final session = await _sessionFactory(
      workingDirectory: Directory.systemTemp.path,
    );
    try {
      return await readAccountFrom(session);
    } finally {
      await session.close();
    }
  }

  Future<CodexAccountInfo?> readAccountFrom(
    CodexAppServerSession session,
  ) async {
    final response = await _request(session, 'account/read', <String, dynamic>{
      'refreshToken': false,
    });
    return CodexAccountInfo.fromAccountRead(response);
  }

  Future<CodexAccountInfo> requireChatGpt(CodexAppServerSession session) async {
    final account = await readAccountFrom(session);
    if (account == null) throw const CodexChatGptSignInRequiredException();
    if (!account.isChatGpt) {
      throw const CodexChatGptAccountRequiredException();
    }
    return account;
  }

  Future<List<Map<String, dynamic>>> listModels() async {
    final session = await _sessionFactory(
      workingDirectory: Directory.systemTemp.path,
    );
    try {
      await requireChatGpt(session);
      return await listModelsFrom(session);
    } finally {
      await session.close();
    }
  }

  Future<List<Map<String, dynamic>>> listModelsFrom(
    CodexAppServerSession session,
  ) async {
    final models = <Map<String, dynamic>>[];
    String? cursor;
    final seenCursors = <String>{};
    do {
      final response = await _request(session, 'model/list', <String, dynamic>{
        'includeHidden': false,
        'limit': 100,
        'cursor': ?cursor,
      });
      final page = response['data'];
      if (page is List) {
        for (final rawModel in page) {
          if (rawModel is! Map) continue;
          final model = Map<String, dynamic>.from(rawModel);
          final wireId = model['model'] ?? model['id'];
          if (wireId is! String || wireId.isEmpty) continue;
          models.add(<String, dynamic>{...model, 'id': wireId});
        }
      }

      final next = response['nextCursor'];
      cursor = next is String && next.isNotEmpty ? next : null;
      if (cursor != null && !seenCursors.add(cursor)) {
        throw const CodexAppServerException(
          'Codex returned a repeated model-list cursor.',
        );
      }
    } while (cursor != null);
    return models;
  }

  /// Starts Codex-owned browser OAuth. Glaze's Dart code receives only the
  /// authorization URL and completion status; Codex stores the OAuth
  /// credential inside the isolated Glaze profile without exposing it here.
  Future<CodexAccountInfo> signInWithChatGpt({
    required Future<bool> Function(Uri uri) openBrowser,
  }) async {
    final session = await _sessionFactory(
      workingDirectory: Directory.systemTemp.path,
    );
    StreamSubscription<CodexAppServerNotification>? loginSubscription;
    String? loginId;
    try {
      final login =
          await _request(session, 'account/login/start', <String, dynamic>{
            'type': 'chatgpt',
            'appBrand': 'chatgpt',
            'useHostedLoginSuccessPage': true,
            'codexStreamlinedLogin': false,
          });
      final rawLoginId = login['loginId'];
      final rawAuthUrl = login['authUrl'];
      if (rawLoginId is! String || rawAuthUrl is! String) {
        throw const CodexAppServerException(
          'Codex did not return a valid ChatGPT sign-in URL.',
        );
      }
      final authUri = Uri.tryParse(rawAuthUrl);
      if (authUri == null ||
          authUri.scheme != 'https' ||
          !authUri.hasAuthority) {
        throw const CodexAppServerException(
          'Codex returned an unsafe ChatGPT sign-in URL.',
        );
      }
      loginId = rawLoginId;

      final completion = Completer<CodexAppServerNotification>();
      loginSubscription = session.notifications.listen(
        (event) {
          if (!completion.isCompleted &&
              event.method == 'account/login/completed' &&
              event.params['loginId'] == loginId) {
            completion.complete(event);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!completion.isCompleted) {
            completion.completeError(error, stackTrace);
          }
        },
        onDone: () {
          if (!completion.isCompleted) {
            completion.completeError(
              const CodexAppServerException(
                'Codex closed before ChatGPT sign-in completed.',
              ),
            );
          }
        },
      );
      final opened = await openBrowser(authUri);
      if (!opened) throw const CodexLoginCancelledException();

      final event = await completion.future.timeout(const Duration(minutes: 5));
      if (event.params['success'] != true) {
        throw CodexAppServerException(
          event.params['error']?.toString() ?? 'ChatGPT sign-in failed.',
        );
      }
      final account = await requireChatGpt(session);
      loginId = null;
      return account;
    } on TimeoutException {
      throw const CodexAppServerException(
        'ChatGPT sign-in timed out. Start the sign-in again.',
      );
    } finally {
      if (loginId != null) {
        try {
          await session
              .request('account/login/cancel', <String, dynamic>{
                'loginId': loginId,
              })
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          // Completion or process shutdown already settled the login.
        }
      }
      await loginSubscription?.cancel();
      await session.close();
    }
  }

  Future<Map<String, dynamic>> _request(
    CodexAppServerSession session,
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {
    return session
        .request(method, params)
        .timeout(
          requestTimeout,
          onTimeout: () => throw CodexAppServerException(
            'Codex App Server did not respond to $method in time.',
          ),
        );
  }
}
