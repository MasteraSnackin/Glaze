import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_policy.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/chat/services/stages/ledger_stage.dart';

void main() {
  test(
    'legacy engine skips automation while per-turn mode remains selected',
    () {
      expect(
        shouldRunAutomaticLedgerReconciliation(
          engine: StudioLedgerEngine.legacyTurnOnly,
          isManualRerun: false,
        ),
        isFalse,
      );
      expect(
        shouldRunAutomaticLedgerReconciliation(
          engine: StudioLedgerEngine.currentReconciled,
          isManualRerun: false,
        ),
        isTrue,
      );
    },
  );

  test(
    'generation projection hard opt-out is independent of Ledger engine',
    () {
      const disabledProjection = LedgerPromptInjectionPolicy(
        presetOptIn: false,
        mode: LedgerPromptInjectionMode.disabled,
      );

      expect(
        disabledProjection.effectiveMode,
        LedgerPromptInjectionMode.disabled,
      );
      expect(
        shouldRunAutomaticLedgerReconciliation(
          engine: StudioLedgerEngine.currentReconciled,
          isManualRerun: false,
        ),
        isTrue,
        reason: 'projection opt-out must not disable post-generation Ledger',
      );
      expect(
        shouldRunAutomaticLedgerReconciliation(
          engine: StudioLedgerEngine.legacyTurnOnly,
          isManualRerun: false,
        ),
        isFalse,
        reason: 'engine choice must not mutate projection policy',
      );
      expect(
        disabledProjection.effectiveMode,
        LedgerPromptInjectionMode.disabled,
      );
    },
  );
}
