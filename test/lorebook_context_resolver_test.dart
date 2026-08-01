import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/lorebook_scanner.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/prompt/lorebook_context_resolver.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

void main() {
  const character = Character(id: 'char', name: 'Mira');
  const macroContext = MacroContext(
    charName: 'Mira',
    charId: 'char',
    sessionId: '',
  );
  const resolver = LorebookContextResolver();

  test('merges and classifies keyword and normalized vector entries', () {
    const canonicalVectorContent = 'Canonical vector fact about {{char}}';
    final result = resolver.resolve(
      history: const [],
      character: character,
      sessionId: 'session',
      lorebooks: const [
        Lorebook(
          id: 'book',
          name: 'World',
          entries: [
            LorebookEntry(
              id: 'vector',
              comment: 'Vector fact',
              content: canonicalVectorContent,
              position: 'worldInfoAfter',
            ),
          ],
        ),
      ],
      settings: const LorebookGlobalSettings(maxInjectedEntries: 4),
      activations: const LorebookActivations(),
      vectorEntries: const [
        LorebookEntry(
          id: 'vector',
          comment: 'Vector fact',
          content: 'stale indexed content',
          position: 'worldInfoAfter',
          lorebookId: 'book',
          lorebookName: 'World',
        ),
      ],
      macroContext: macroContext,
      preScannedEntries: const [
        ScannedEntry(
          id: 'keyword',
          comment: 'Keyword fact',
          content: 'Keyword fact about {{char}}',
          position: 'lorebooksMacro',
          order: 0,
          lorebookName: 'World',
          lorebookId: 'book',
          constant: false,
        ),
      ],
    );

    expect(result.mergedEntries.map((entry) => entry.id), [
      'keyword',
      'vector',
    ]);
    expect(result.loreMacroBuffer, ['Keyword fact about Mira']);
    expect(result.loreAfter.single.content, 'Canonical vector fact about Mira');
    expect(result.triggeredEntries.map((entry) => entry.source), [
      'keyword',
      'vector',
    ]);
    expect(result.triggeredEntries.last.lorebookId, 'book');
    expect(result.vectorLoreTokens, estimateTokens(canonicalVectorContent));
    expect(
      result.vectorEntries['book_vector']?.content,
      canonicalVectorContent,
    );
  });

  test('scans only visible history and returns semantic lore slots', () {
    const lorebook = Lorebook(
      id: 'book',
      name: 'World',
      entries: [
        LorebookEntry(
          id: 'keyword',
          comment: 'Visible keyword',
          keys: ['anchor'],
          content: 'Visible fact',
          position: 'worldInfoBefore',
        ),
      ],
    );

    LorebookContextResolution resolve(List<ChatMessage> history) =>
        resolver.resolve(
          history: history,
          character: character,
          sessionId: 'session',
          lorebooks: const [lorebook],
          settings: const LorebookGlobalSettings(),
          activations: const LorebookActivations(),
          vectorEntries: const [],
          macroContext: macroContext,
        );

    final hiddenOnly = resolve(const [
      ChatMessage(
        id: 'hidden',
        role: 'user',
        content: 'anchor',
        isHidden: true,
      ),
      ChatMessage(id: 'visible', role: 'user', content: 'nothing relevant'),
    ]);
    expect(hiddenOnly.mergedEntries, isEmpty);

    final visible = resolve(const [
      ChatMessage(id: 'visible', role: 'user', content: 'anchor'),
    ]);
    expect(visible.loreBefore.single.content, 'Visible fact');
    expect(visible.triggeredEntries.single.source, 'keyword');
  });
}
