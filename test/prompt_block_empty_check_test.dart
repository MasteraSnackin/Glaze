import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/prompt_block_resolver.dart';
import 'package:glaze_flutter/core/models/character.dart';

/// A preset block counts as empty only when nothing at all is left of it —
/// the same rule SillyTavern applies in `openai.js` (`getChat` keeps every
/// string a JS truthiness check accepts). A block holding just spaces or
/// newlines is content the author typed on purpose, so it survives and is
/// sent, and the text it carries is never trimmed on the way out.
void main() {
  Character makeChar() => Character(
    id: 'c1',
    name: 'Alice',
    description: 'A test character.',
    personality: 'Cheerful and helpful.',
    scenario: 'Meeting at a cafe.',
  );

  MacroContext makeCtx() =>
      const MacroContext(charName: 'Alice', charId: 'c1', sessionId: 's1');

  ResolvedContent? resolve(String rawContent) => resolveBlockContent(
    id: 'custom',
    rawContent: rawContent,
    role: 'system',
    char: makeChar(),
    persona: null,
    macroCtx: makeCtx(),
    sessionVars: const {},
    globalVars: const {},
    summaryContent: null,
    summaryPrefix: null,
    notifyObj: NotifyObj(),
  );

  group('block emptiness', () {
    test('a zero-length block is dropped', () {
      expect(resolve(''), isNull);
    });

    test('a spaces-only block survives', () {
      final result = resolve('   ');
      expect(result, isNotNull);
      expect(result!.content, '   ');
    });

    test('a newlines-only block survives', () {
      final result = resolve('\n\n');
      expect(result, isNotNull);
      expect(result!.content, '\n\n');
    });

    test('a block that macros expand down to whitespace survives', () {
      // {{summary}} resolves to nothing here, leaving only the newline the
      // author typed around it.
      final result = resolve('{{summary}}\n');
      expect(result, isNotNull);
      expect(result!.content, '\n');
    });

    test('a block that macros expand down to nothing is dropped', () {
      expect(resolve('{{summary}}'), isNull);
    });

    test('surrounding whitespace is preserved, not trimmed away', () {
      final result = resolve('\n  You are a helpful assistant.  \n');
      expect(result, isNotNull);
      expect(result!.content, '\n  You are a helpful assistant.  \n');
    });

    test('a setvar-only block still resolves to accounting content only', () {
      final result = resolve('{{setvar::flag::1}}');
      expect(result, isNotNull);
      expect(result!.content, isEmpty);
      expect(result.contentForAccounting, isNotEmpty);
    });
  });

  group('buildApiMessages', () {
    test('drops zero-length messages and keeps whitespace ones', () {
      final messages = buildApiMessages(const [
        PromptMessage(role: 'system', content: 'kept'),
        PromptMessage(role: 'system', content: ''),
        PromptMessage(role: 'system', content: '   '),
      ]);

      expect(messages, hasLength(2));
      expect(messages[0]['content'], 'kept');
      expect(messages[1]['content'], '   ');
    });

    test('does not trim the content it sends', () {
      final messages = buildApiMessages(const [
        PromptMessage(role: 'system', content: '\nmain prompt\n'),
      ]);

      expect(messages.single['content'], '\nmain prompt\n');
    });
  });
}
