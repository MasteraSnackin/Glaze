import '../../models/chat_message.dart';
import '../history_assembler.dart';
import '../macro_engine.dart';

enum StudioContextSlot {
  characterCard,
  characterPersonality,
  userPersona,
  scenario,
  exampleDialogue,
  authorsNote,
  summary,
  memory,
  loreBefore,
  loreAfter,
  loreMacro,
  recalledMessages,
  characterKnowledge,
  studioSessionState,
  runtimeDynamic,
}

StudioContextSlot? studioContextSlotForLegacyKind(String kind) =>
    switch (kind) {
      'char_card' => StudioContextSlot.characterCard,
      'char_personality' => StudioContextSlot.characterPersonality,
      'user_persona' => StudioContextSlot.userPersona,
      'scenario' => StudioContextSlot.scenario,
      'example_dialogue' => StudioContextSlot.exampleDialogue,
      'authors_note' => StudioContextSlot.authorsNote,
      'summary' => StudioContextSlot.summary,
      'memory' => StudioContextSlot.memory,
      'worldInfoBefore' => StudioContextSlot.loreBefore,
      'worldInfoAfter' => StudioContextSlot.loreAfter,
      'lorebooks' => StudioContextSlot.loreMacro,
      'recalled_messages' => StudioContextSlot.recalledMessages,
      'character_knowledge' => StudioContextSlot.characterKnowledge,
      'studio_session_state' => StudioContextSlot.studioSessionState,
      'guided_generation' => StudioContextSlot.runtimeDynamic,
      _ => null,
    };

final class StudioContextDiagnostics {
  final List<TriggeredEntry> triggeredLorebooks;
  final List<TriggeredEntry> triggeredMemories;
  final Map<String, dynamic> memoryCoverage;
  final int vectorLoreTokens;
  final Set<String> visibleMessageIds;

  const StudioContextDiagnostics({
    this.triggeredLorebooks = const [],
    this.triggeredMemories = const [],
    this.memoryCoverage = const {},
    this.vectorLoreTokens = 0,
    this.visibleMessageIds = const {},
  });
}

/// Preset-independent context prepared for one explicit Studio source window.
final class StudioContext {
  final Map<StudioContextSlot, List<PromptMessage>> slots;
  final List<PromptMessage> history;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;
  final MacroContext macroContext;
  final StudioContextDiagnostics diagnostics;

  const StudioContext({
    required this.slots,
    required this.history,
    required this.sessionVars,
    required this.globalVars,
    required this.macroContext,
    required this.diagnostics,
  });

  List<PromptMessage> messagesFor(StudioContextSlot slot) =>
      slots[slot] ?? const <PromptMessage>[];

  String join(StudioContextSlot slot) =>
      messagesFor(slot).map((message) => message.content).join('\n\n');

  List<PromptMessage> get staticContext => [
    ...messagesFor(StudioContextSlot.characterCard),
    ...messagesFor(StudioContextSlot.characterPersonality),
    ...messagesFor(StudioContextSlot.userPersona),
    ...messagesFor(StudioContextSlot.scenario),
    ...messagesFor(StudioContextSlot.exampleDialogue),
    ...messagesFor(StudioContextSlot.authorsNote),
  ];

  List<PromptMessage> get dynamicContext => [
    ...messagesFor(StudioContextSlot.characterKnowledge),
    ...messagesFor(StudioContextSlot.studioSessionState),
    ...messagesFor(StudioContextSlot.summary),
    ...messagesFor(StudioContextSlot.memory),
    ...messagesFor(StudioContextSlot.loreBefore),
    ...messagesFor(StudioContextSlot.loreAfter),
    ...messagesFor(StudioContextSlot.loreMacro),
    ...messagesFor(StudioContextSlot.recalledMessages),
    ...messagesFor(StudioContextSlot.runtimeDynamic),
  ];
}
