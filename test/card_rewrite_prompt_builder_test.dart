import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewrite_prompt_builder.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

void main() {
  Character character() => Character(
    id: 'local-id',
    name: 'Ada',
    description: 'A {{char}} who assists {{user}}.',
    personality: 'Precise.',
    scenario: 'Set in the study of {{description}}.',
    systemPrompt: 'Stay in character.',
    creatorNotes: 'Keep the tone dry.',
    alternateGreetings: const ['Hello'],
  );

  String buildPrompt({
    Character? card,
    CardRewriteField field = CardRewriteField.description,
    String instruction = 'Tighten the prose.',
  }) => CardRewriterPromptBuilder.build(
    character: card ?? character(),
    field: field,
    instruction: instruction,
  );

  test(
    'identical character, field, and instruction produce a byte-identical prompt',
    () {
      final first = buildPrompt();
      final second = buildPrompt();
      expect(first, equals(second));
      expect(first.codeUnits, equals(second.codeUnits));
    },
  );

  test('a different instruction changes the prompt', () {
    expect(
      buildPrompt(instruction: 'Make it warmer.'),
      isNot(equals(buildPrompt())),
    );
  });

  test('a different target field changes the prompt', () {
    expect(
      buildPrompt(field: CardRewriteField.personality),
      isNot(equals(buildPrompt())),
    );
  });

  test('a character differing only outside the snapshot yields the same prompt', () {
    final uiOnly = character().copyWith(
      avatarPath: '/tmp/avatar.png',
      color: '#fff',
      updatedAt: 5,
      currentSessionIndex: 9,
      fav: true,
      hidden: true,
    );
    expect(buildPrompt(card: uiOnly), equals(buildPrompt()));
  });

  test('prompt names the target field and lists the field budget', () {
    final prompt = buildPrompt(field: CardRewriteField.creatorNotes);
    expect(prompt, contains('- field: creatorNotes'));
    expect(prompt, contains('- fieldBudgetCodeUnits: 12000'));
    expect(
      prompt,
      contains(
        '- totalCardBudgetCodeUnits: ${CardRewritePolicy.totalCardBudget}',
      ),
    );
    expect(
      prompt,
      contains('- currentFieldCodeUnits: ${'Keep the tone dry.'.length}'),
    );
    expect(
      prompt,
      contains('Respond with exactly ONE JSON object and nothing else'),
    );
  });

  test('prompt lists the writable fields and forbids non-target fields', () {
    final prompt = buildPrompt(field: CardRewriteField.scenario);
    expect(
      prompt,
      contains(
        'Writable fields across this workflow: '
        'description, personality, scenario, systemPrompt, '
        'postHistoryInstructions, creatorNotes.',
      ),
    );
    expect(prompt, contains('For THIS operation only "scenario" is writable.'));
    expect(prompt, contains('read-only'));
  });

  test(
    'prompt describes the operation snapshot shape, hash rule, and scope grammar',
    () {
      final prompt = buildPrompt();
      expect(
        prompt,
        contains('"patches":[{"scopeKey":"...","anchor":"...",'
            '"anchorSha256":"...","value":"..."}]'),
      );
      expect(prompt, contains('"affectedTrackerKeys":[]'));
      expect(prompt, contains('"chatSessionId":null'));
      expect(prompt, contains('- "field" MUST be exactly "description".'));
      expect(prompt, contains('- "patches" MUST be a non-empty list'));
      expect(prompt, contains('npc:<subject>'));
      expect(prompt, contains('relationship:<subject>'));
      expect(prompt, contains('arc:<subject>'));
      expect(prompt, contains('world:<subject>'));
      expect(prompt, contains('scene.<subject>'));
      expect(
        prompt,
        contains('lowercase hex SHA-256 of the anchor'),
      );
      expect(prompt, contains('EXACTLY ONCE'));
    },
  );

  test(
    'prompt forbids macro expansion and demands literal {{...}} preservation',
    () {
      final prompt = buildPrompt();
      expect(prompt, contains('{{user}}'));
      expect(prompt, contains('{{char}}'));
      expect(prompt, contains('{{description}}'));
      expect(prompt, contains('NEVER expand, substitute, rename, translate, or delete'));
      expect(prompt, contains('byte-for-byte'));
    },
  );

  test('prompt embeds the canonical snapshot and macros verbatim', () {
    final prompt = buildPrompt();
    expect(prompt, contains(CardCanonicalizer.serialize(character())));
    expect(prompt, contains('A {{char}} who assists {{user}}.'));
    expect(prompt, contains('Set in the study of {{description}}.'));
  });

  test('prompt embeds the user instruction', () {
    final prompt = buildPrompt(
      instruction: 'Fold the backstory near {{user}} references.\nLine two.',
    );
    expect(prompt, contains('# User instruction'));
    expect(
      prompt,
      contains('Fold the backstory near {{user}} references.\nLine two.'),
    );
  });
}
