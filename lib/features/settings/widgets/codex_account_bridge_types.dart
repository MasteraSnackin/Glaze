/// Privacy-preserving account details exposed to settings.
///
/// The bridge deliberately contains no email, token or credential fields.
class CodexSettingsAccount {
  const CodexSettingsAccount({required this.isChatGpt, this.planType});

  final bool isChatGpt;
  final String? planType;
}

enum CodexSettingsFailureKind {
  signedOut,
  apiKeyAccount,
  notInstalled,
  unsupportedPlatform,
  other,
}

class CodexSettingsException implements Exception {
  const CodexSettingsException(this.kind, this.message);

  final CodexSettingsFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

abstract interface class CodexSettingsAccountClient {
  Future<CodexSettingsAccount?> readAccount();

  Future<List<Map<String, dynamic>>> listModels();

  Future<CodexSettingsAccount> signInWithChatGpt({
    required Future<bool> Function(Uri uri) openBrowser,
  });
}
