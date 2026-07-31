import 'context_calculator.dart';
import 'history_assembler.dart';
import 'macro_engine.dart';
import 'prompt_builder.dart';
import 'prompt/effective_canon_prompt_formatter.dart';
import '../models/chat_message.dart';

PromptResult buildFallbackPrompt(PromptPayload payload) {
  final canon = payload.effectiveCanonProjection == null
      ? null
      : EffectiveCanonPromptFormatter.format(
          payload.effectiveCanonProjection!,
          sessionId: payload.sessionId ?? '',
          latestUserText: _latestText(payload.history, 'user'),
          latestAssistantText: _latestText(payload.history, 'assistant'),
        );
  final macroCtx = MacroContext(
    charName: payload.character.name,
    charDescription: payload.character.description,
    charScenario: payload.character.scenario,
    charPersonality: payload.character.personality,
    charMesExample: payload.character.mesExample,
    userName: payload.persona?.name ?? 'User',
    personaPrompt: payload.persona?.prompt,
    charId: payload.character.id,
    sessionId: '',
    sessionVars: payload.sessionVars,
    globalVars: payload.globalVars,
    macroName: payload.character.macroName,
  );

  const systemMessage = PromptMessage(
    role: 'system',
    content: 'You are a helpful assistant.',
  );
  final history = <PromptMessage>[];

  for (final msg in payload.history) {
    final macroResult = replaceMacros(msg.content, macroCtx);
    history.add(
      PromptMessage(
        role: msg.role,
        content: macroResult.text,
        reasoningContent: msg.reasoning,
        isHistory: true,
        sourceMessageId: msg.id,
        imagePath: msg.imageHidden ? null : msg.imagePath,
      ),
    );
  }

  final calculator = ContextCalculator(
    contextSize: payload.apiConfig.contextSize,
    maxTokens: payload.apiConfig.maxTokens,
    reasoningHistoryCount: payload.apiConfig.reasoningHistoryCount,
  );
  final breakdown = calculator.calculate(
    staticBlocks: const [
      StaticBlock(
        id: 'fallback_system',
        content: 'You are a helpful assistant.',
      ),
    ],
    historyMessages: history,
  );

  return PromptResult(
    messages: [
      systemMessage,
      if (canon?.characterKnowledge case final content? when content.isNotEmpty)
        PromptMessage(role: 'system', content: content, blockId: 'current_character_state'),
      if (canon?.sessionState case final content? when content.isNotEmpty)
        PromptMessage(role: 'system', content: content, blockId: 'studio_session_state'),
      ...breakdown.trimmedHistory,
    ],
    breakdown: breakdown,
    sessionVars: payload.sessionVars,
    globalVars: payload.globalVars,
  );
}

String _latestText(List<ChatMessage> history, String role) => history
    .lastWhere((message) => message.role == role, orElse: () => const ChatMessage(id: '', role: '', content: ''))
    .content;
