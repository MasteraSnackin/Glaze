import 'codex_account_bridge_types.dart';

CodexSettingsAccountClient createCodexSettingsAccountClient() =>
    const _UnsupportedCodexSettingsAccountClient();

class _UnsupportedCodexSettingsAccountClient
    implements CodexSettingsAccountClient {
  const _UnsupportedCodexSettingsAccountClient();

  static const _error = CodexSettingsException(
    CodexSettingsFailureKind.unsupportedPlatform,
    'ChatGPT subscription connections are available only in the Windows, '
    'macOS and Linux versions of Glaze.',
  );

  @override
  Future<CodexSettingsAccount?> readAccount() => Future.error(_error);

  @override
  Future<List<Map<String, dynamic>>> listModels() => Future.error(_error);

  @override
  Future<CodexSettingsAccount> signInWithChatGpt({
    required Future<bool> Function(Uri uri) openBrowser,
  }) => Future.error(_error);
}
