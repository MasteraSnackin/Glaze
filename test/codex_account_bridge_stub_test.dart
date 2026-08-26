import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/settings/widgets/codex_account_bridge_stub.dart';
import 'package:glaze_flutter/features/settings/widgets/codex_account_bridge_types.dart';

void main() {
  test(
    'non-IO settings bridge fails closed without starting sign-in',
    () async {
      final client = createCodexSettingsAccountClient();

      await expectLater(
        client.readAccount(),
        throwsA(
          isA<CodexSettingsException>().having(
            (error) => error.kind,
            'kind',
            CodexSettingsFailureKind.unsupportedPlatform,
          ),
        ),
      );
      await expectLater(
        client.listModels(),
        throwsA(
          isA<CodexSettingsException>().having(
            (error) => error.kind,
            'kind',
            CodexSettingsFailureKind.unsupportedPlatform,
          ),
        ),
      );
      var openedBrowser = false;
      await expectLater(
        client.signInWithChatGpt(
          openBrowser: (_) async {
            openedBrowser = true;
            return true;
          },
        ),
        throwsA(
          isA<CodexSettingsException>().having(
            (error) => error.kind,
            'kind',
            CodexSettingsFailureKind.unsupportedPlatform,
          ),
        ),
      );
      expect(openedBrowser, isFalse);
    },
  );
}
