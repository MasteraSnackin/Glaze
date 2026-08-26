import '../../../core/llm/transport/codex_account_service.dart';
import '../../../core/llm/transport/codex_app_server_client.dart';
import 'codex_account_bridge_types.dart';

CodexSettingsAccountClient createCodexSettingsAccountClient() =>
    _IoCodexSettingsAccountClient(CodexAccountService());

class _IoCodexSettingsAccountClient implements CodexSettingsAccountClient {
  const _IoCodexSettingsAccountClient(this._service);

  final CodexAccountService _service;

  @override
  Future<CodexSettingsAccount?> readAccount() => _guard(() async {
    final account = await _service.readAccount();
    return account == null
        ? null
        : CodexSettingsAccount(
            isChatGpt: account.isChatGpt,
            planType: account.planType,
          );
  });

  @override
  Future<List<Map<String, dynamic>>> listModels() =>
      _guard(_service.listModels);

  @override
  Future<CodexSettingsAccount> signInWithChatGpt({
    required Future<bool> Function(Uri uri) openBrowser,
  }) => _guard(() async {
    final account = await _service.signInWithChatGpt(openBrowser: openBrowser);
    return CodexSettingsAccount(
      isChatGpt: account.isChatGpt,
      planType: account.planType,
    );
  });

  @override
  Future<void> resetAuthentication() =>
      _guard(CodexIsolatedHome.clearAuthentication);

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on CodexChatGptSignInRequiredException catch (error) {
      throw CodexSettingsException(
        CodexSettingsFailureKind.signedOut,
        error.message,
      );
    } on CodexChatGptAccountRequiredException catch (error) {
      throw CodexSettingsException(
        CodexSettingsFailureKind.apiKeyAccount,
        error.message,
      );
    } on CodexNotInstalledException catch (error) {
      throw CodexSettingsException(
        CodexSettingsFailureKind.notInstalled,
        error.message,
      );
    } on CodexUnsupportedPlatformException catch (error) {
      throw CodexSettingsException(
        CodexSettingsFailureKind.unsupportedPlatform,
        error.message,
      );
    } on CodexAppServerException catch (error) {
      throw CodexSettingsException(
        CodexSettingsFailureKind.other,
        error.message,
      );
    } catch (_) {
      throw const CodexSettingsException(
        CodexSettingsFailureKind.other,
        'Codex App Server request failed unexpectedly.',
      );
    }
  }
}
