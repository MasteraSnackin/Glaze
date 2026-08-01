import 'package:easy_localization/easy_localization.dart';

/// The injection points a block can be addressed to, in pipeline order (§5).
/// Shared by the editor's section list and the block editor's dropdown so the
/// two can never drift apart.
const studioInjectionPoints = <String>[
  'pregen',
  'specificAgent',
  'final',
  'cleaner',
  'ledger',
];

/// Localized label for an injection point. `final` reads as "Main Writer" — the
/// stage that writes the visible reply — rather than as the stored id. An
/// unknown point (a legacy row that escaped the §5 migration) falls back to the
/// raw value instead of being mislabelled.
String studioInjectionPointLabel(String point) => switch (point) {
  'pregen' => 'studio_point_pregen'.tr(),
  'specificAgent' => 'studio_point_specific_agent'.tr(),
  'final' => 'studio_point_final'.tr(),
  'cleaner' => 'studio_point_cleaner'.tr(),
  'ledger' => 'studio_point_ledger'.tr(),
  _ => point,
};

/// Localized label for a block's mode (§5 "Режим") — what the block emits.
String studioBlockModeLabel(String mode) => switch (mode) {
  'pregenBrief' => 'studio_mode_pregen_brief'.tr(),
  'agentResponse' => 'studio_mode_agent_response'.tr(),
  _ => 'studio_mode_direct'.tr(),
};
