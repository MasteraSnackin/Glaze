import 'dart:async';

import 'codex_app_server_client.dart';

typedef CodexSessionFactory =
    Future<CodexAppServerSession> Function({
      String? workingDirectory,
      CodexStartupCancellation? startupCancellation,
    });
typedef CodexWorkingDirectoryFactory = Future<String> Function();

Future<CodexAppServerSession> defaultCodexSessionFactory({
  String? workingDirectory,
  CodexStartupCancellation? startupCancellation,
}) => CodexAppServerClient.start(
  workingDirectory: workingDirectory,
  startupCancellation: startupCancellation,
);

Future<String> defaultCodexAccountWorkingDirectoryFactory() =>
    CodexIsolatedHome.prepareAccountWorkingDirectory();

class CodexAccountInfo {
  const CodexAccountInfo({required this.type, this.planType});

  final String type;
  final String? planType;

  bool get isChatGpt => type == 'chatgpt';

  /// Only plan values whose non-managed behaviour was audited in Codex
  /// 0.147.0/0.149.0 are accepted. Unknown, missing and future values fail
  /// closed so a new managed workspace SKU cannot bypass this boundary.
  bool get requiresManagedCodexConfig => !const <String>{
    'free',
    'go',
    'plus',
    'pro',
    'prolite',
    'team',
    'self_serve_business_prolite',
    'self_serve_business_usage_based',
  }.contains(planType?.trim().toLowerCase());

  static CodexAccountInfo? fromAccountRead(Map<String, dynamic> response) {
    if (response['requiresOpenaiAuth'] != true) {
      throw const CodexIsolationException(
        'Codex did not confirm OpenAI authentication for the active provider. '
        'The ChatGPT connection was stopped to prevent credential routing to '
        'another provider.',
      );
    }
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

class CodexManagedWorkspaceUnsupportedException
    extends CodexAppServerException {
  const CodexManagedWorkspaceUnsupportedException()
    : super(
        'This Glaze connection supports only audited personal and team-like '
        'ChatGPT plans. Managed, missing or unrecognised plan types are not '
        'accepted.',
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
    this.loginPropagationTimeout = const Duration(seconds: 30),
    Future<void> Function()? clearIsolatedAuthentication,
    CodexWorkingDirectoryFactory? workingDirectoryFactory,
  }) : _sessionFactory = sessionFactory ?? defaultCodexSessionFactory,
       _clearIsolatedAuthentication =
           clearIsolatedAuthentication ?? CodexIsolatedHome.clearAuthentication,
       _workingDirectoryFactory =
           workingDirectoryFactory ??
           defaultCodexAccountWorkingDirectoryFactory,
       assert(requestTimeout > Duration.zero),
       assert(loginPropagationTimeout > Duration.zero);

  final CodexSessionFactory _sessionFactory;
  final Duration requestTimeout;
  final Duration loginPropagationTimeout;
  final Future<void> Function() _clearIsolatedAuthentication;
  final CodexWorkingDirectoryFactory _workingDirectoryFactory;

  Future<CodexAccountInfo?> readAccount() async {
    final workingDirectory = await _workingDirectoryFactory();
    final session = await _sessionFactory(workingDirectory: workingDirectory);
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
    if (account.requiresManagedCodexConfig) {
      throw const CodexManagedWorkspaceUnsupportedException();
    }
    return account;
  }

  Future<List<Map<String, dynamic>>> listModels() async {
    final workingDirectory = await _workingDirectoryFactory();
    final session = await _sessionFactory(workingDirectory: workingDirectory);
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
    final workingDirectory = await _workingDirectoryFactory();
    final session = await _sessionFactory(workingDirectory: workingDirectory);
    StreamSubscription<CodexAppServerNotification>? loginSubscription;
    String? loginId;
    var clearIncompleteLogin = false;
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
      // Retain the identifier before validating the URL so even an unsafe
      // response is cancelled during cleanup.
      loginId = rawLoginId;
      final authUri = Uri.tryParse(rawAuthUrl);
      if (authUri == null ||
          authUri.scheme != 'https' ||
          authUri.host != 'auth.openai.com' ||
          authUri.port != 443 ||
          authUri.userInfo.isNotEmpty ||
          authUri.path != '/oauth/authorize') {
        throw const CodexAppServerException(
          'Codex returned an unsafe ChatGPT sign-in URL.',
        );
      }

      final completion = Completer<CodexAppServerNotification>();
      final accountUpdated = Completer<CodexAppServerNotification>();
      var matchingLoginSucceeded = false;
      loginSubscription = session.notifications.listen(
        (event) {
          if (!completion.isCompleted &&
              event.method == 'account/login/completed' &&
              event.params['loginId'] == loginId) {
            matchingLoginSucceeded = event.params['success'] == true;
            completion.complete(event);
            return;
          }
          if (matchingLoginSucceeded &&
              !accountUpdated.isCompleted &&
              event.method == 'account/updated') {
            accountUpdated.complete(event);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!completion.isCompleted) {
            completion.completeError(error, stackTrace);
          }
          if (matchingLoginSucceeded && !accountUpdated.isCompleted) {
            accountUpdated.completeError(error, stackTrace);
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
          if (matchingLoginSucceeded && !accountUpdated.isCompleted) {
            accountUpdated.completeError(
              const CodexAppServerException(
                'Codex closed before the signed-in account was ready.',
              ),
            );
          }
        },
      );
      // Codex can persist auth.json immediately before publishing the
      // completion notification, including while the browser launcher Future
      // is still pending. From this point on, any interruption must therefore
      // remove the isolated credential unless the account is fully validated.
      clearIncompleteLogin = true;
      final opened = await openBrowser(authUri);
      if (!opened) throw const CodexLoginCancelledException();

      final event = await completion.future.timeout(const Duration(minutes: 5));
      if (event.params['success'] != true) {
        throw CodexAppServerException(
          event.params['error']?.toString() ?? 'ChatGPT sign-in failed.',
        );
      }
      loginId = null;
      final update = await accountUpdated.future.timeout(
        loginPropagationTimeout,
      );
      if (update.params['authMode'] != 'chatgpt') {
        throw const CodexIsolationException(
          'Codex did not confirm the ChatGPT authentication mode after sign-in.',
        );
      }
      final updatedAccount = CodexAccountInfo(
        type: 'chatgpt',
        planType: update.params['planType']?.toString(),
      );
      if (updatedAccount.requiresManagedCodexConfig) {
        try {
          await _request(session, 'account/logout');
        } catch (_) {
          // The exact file-backed credential is removed after process close.
        }
        throw const CodexManagedWorkspaceUnsupportedException();
      }
      CodexAccountInfo account;
      try {
        account = await requireChatGpt(session);
      } on CodexManagedWorkspaceUnsupportedException {
        // The credential belongs only to Glaze's isolated Codex profile. Clear
        // an unsupported managed-workspace login immediately so the next App
        // Server start cannot be blocked by its cloud-policy bootstrap.
        try {
          await _request(session, 'account/logout');
        } catch (_) {
          // The exact file-backed credential is removed after process close.
        }
        rethrow;
      }
      clearIncompleteLogin = false;
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
      if (clearIncompleteLogin) await _clearIsolatedAuthentication();
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
