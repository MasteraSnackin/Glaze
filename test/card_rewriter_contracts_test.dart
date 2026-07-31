import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

void main() {
  Character character({Map<String, dynamic> extensions = const {}}) =>
      Character(
        id: 'local-id',
        name: 'Ada',
        description: null,
        alternateGreetings: const ['Hello', 'Again'],
        depthPrompt: 'Stay in character.',
        depthPromptDepth: 6,
        depthPromptRole: 'system',
        extensions: extensions,
      );

  test('canonical card serialization is stable and normalizes null text', () {
    final first = character(
      extensions: {
        'z': {'beta': 2, 'alpha': 1},
        'a': true,
      },
    );
    final second = character(
      extensions: {
        'a': true,
        'z': {'alpha': 1, 'beta': 2},
      },
    ).copyWith(description: '');

    expect(
      CardCanonicalizer.serialize(first),
      CardCanonicalizer.serialize(second),
    );
    expect(CardCanonicalizer.sha256(first), CardCanonicalizer.sha256(second));
    expect(
      CardCanonicalizer.serialize(first),
      contains('"alternateGreetings"'),
    );
    expect(
      CardCanonicalizer.serialize(first),
      contains('"depthPromptDepth":6'),
    );
  });

  test(
    'canonical card excludes UI and gallery metadata but includes extensions',
    () {
      final base = character(extensions: {'custom': 'one'});
      final uiOnly = base.copyWith(
        avatarPath: '/tmp/avatar.png',
        color: '#fff',
        updatedAt: 5,
        currentSessionIndex: 9,
        fav: true,
        hidden: true,
        characterVersion: '999',
      );
      final changedExtension = base.copyWith(extensions: {'custom': 'two'});

      expect(CardCanonicalizer.sha256(uiOnly), CardCanonicalizer.sha256(base));
      expect(
        CardCanonicalizer.sha256(changedExtension),
        isNot(CardCanonicalizer.sha256(base)),
      );
    },
  );

  test(
    'policy has the exact writable field allowlist and explicit budgets',
    () {
      expect(
        CardRewritePolicy.budgets.keys,
        unorderedEquals(CardRewriteField.values),
      );
      expect(
        CardRewritePolicy.budgets.values.every((budget) => budget > 0),
        isTrue,
      );
    },
  );

  test('scope grammar accepts only the defined semantic mappings', () {
    for (final key in const [
      'npc:ada',
      'relationship:ada-lovelace',
      'arc:act_1',
      'world:earth-2',
      'scene.opening.bridge',
    ]) {
      expect(CardRewriteScope.tryParse(key), isNotNull, reason: key);
    }
    for (final key in const [
      'character:ada',
      'scene:opening',
      'npc:',
      'world:Bad',
    ]) {
      expect(CardRewriteScope.tryParse(key), isNull, reason: key);
    }
  });

  test(
    'anchored patch validator reports stale, duplicate, full-set, and budget violations',
    () {
      final current = {
        for (final field in CardRewriteField.values)
          field: 'old-${field.wireName}',
      };
      AnchoredScalarPatch patch(
        CardRewriteField field, {
        String? anchor,
        String? value,
      }) => AnchoredScalarPatch(
        scopeKey: 'npc:ada',
        field: field,
        anchor: current[field]!,
        anchorSha256: anchor ?? CardCanonicalizer.scalarSha256(current[field]!),
        value: value ?? 'new-${field.wireName}',
      );

      final invalid = AnchoredScalarPatchValidator.validate(
        currentCardValues: current,
        fullCardBaselineSize: current.values.fold(
          0,
          (total, value) => total + value.length,
        ),
        patches: [
          patch(CardRewriteField.description),
          patch(CardRewriteField.description),
          patch(CardRewriteField.personality, anchor: 'outdated'),
          patch(CardRewriteField.scenario, value: 'x' * 12001),
        ],
        requiredFields: CardRewriteField.values,
      );

      expect(invalid.isValid, isFalse);
      expect(
        invalid.violations,
        containsAll([
          CardPatchViolation.duplicateAnchor,
          CardPatchViolation.staleAnchor,
          CardPatchViolation.incompleteSet,
          CardPatchViolation.overBudget,
        ]),
      );
    },
  );

  test('multiple distinct anchored fragments in one field are valid', () {
    final current = <CardRewriteField, String?>{
      CardRewriteField.description: 'first fragment second fragment',
    };
    final result = AnchoredScalarPatchValidator.validate(
      currentCardValues: current,
      fullCardBaselineSize: current.values.fold(
        0,
        (total, value) => total + (value?.length ?? 0),
      ),
      patches: [
        AnchoredScalarPatch(
          scopeKey: 'npc:ada',
          field: CardRewriteField.description,
          anchor: 'first fragment',
          anchorSha256: CardCanonicalizer.scalarSha256('first fragment'),
          value: 'first rewrite',
        ),
        AnchoredScalarPatch(
          scopeKey: 'npc:ada',
          field: CardRewriteField.description,
          anchor: 'second fragment',
          anchorSha256: CardCanonicalizer.scalarSha256('second fragment'),
          value: 'second rewrite',
        ),
      ],
    );

    expect(result.isValid, isTrue);
  });

  test(
    'anchors must occur exactly once and duplicate targets ignore scope',
    () {
      final anchor = CardCanonicalizer.scalarSha256('repeat');
      final result = AnchoredScalarPatchValidator.validate(
        currentCardValues: {CardRewriteField.description: 'repeat repeat'},
        fullCardBaselineSize: 'repeat repeat'.length,
        patches: [
          AnchoredScalarPatch(
            scopeKey: 'npc:ada',
            field: CardRewriteField.description,
            anchor: 'repeat',
            anchorSha256: anchor,
            value: 'one',
          ),
          AnchoredScalarPatch(
            scopeKey: 'npc:bob',
            field: CardRewriteField.description,
            anchor: 'repeat',
            anchorSha256: anchor,
            value: 'two',
          ),
        ],
      );
      expect(result.violations, contains(CardPatchViolation.ambiguousAnchor));
      expect(result.violations, contains(CardPatchViolation.duplicateAnchor));
    },
  );

  test('simulates projected field and total card budgets', () {
    final fieldAnchor = CardCanonicalizer.scalarSha256('old');
    final fieldResult = AnchoredScalarPatchValidator.validate(
      currentCardValues: {CardRewriteField.description: 'old'},
      fullCardBaselineSize: 3,
      patches: [
        AnchoredScalarPatch(
          scopeKey: 'npc:ada',
          field: CardRewriteField.description,
          anchor: 'old',
          anchorSha256: fieldAnchor,
          value: 'x' * 12001,
        ),
      ],
    );
    final totalResult = AnchoredScalarPatchValidator.validate(
      currentCardValues: {
        CardRewriteField.description: 'old',
        CardRewriteField.personality: 'x' * 10,
      },
      fullCardBaselineSize: 13,
      totalCardBudget: 12,
      patches: [
        AnchoredScalarPatch(
          scopeKey: 'npc:ada',
          field: CardRewriteField.description,
          anchor: 'old',
          anchorSha256: fieldAnchor,
          value: 'xxxx',
        ),
      ],
    );
    expect(fieldResult.violations, contains(CardPatchViolation.overBudget));
    expect(
      totalResult.violations,
      contains(CardPatchViolation.totalOverBudget),
    );
  });

  test('total budget includes non-writable canonical baseline content', () {
    final result = AnchoredScalarPatchValidator.validate(
      currentCardValues: {CardRewriteField.description: 'old'},
      // Full canonical snapshot size: most content is non-writable.
      fullCardBaselineSize: 99,
      totalCardBudget: 100,
      patches: [
        AnchoredScalarPatch(
          scopeKey: 'npc:ada',
          field: CardRewriteField.description,
          anchor: 'old',
          anchorSha256: CardCanonicalizer.scalarSha256('old'),
          value: 'newer',
        ),
      ],
    );
    expect(result.violations, contains(CardPatchViolation.totalOverBudget));
  });

  test('total budget applies writable replacement deltas to baseline', () {
    CardPatchValidation validate(String replacement) =>
        AnchoredScalarPatchValidator.validate(
          currentCardValues: {CardRewriteField.description: 'anchor'},
          fullCardBaselineSize: 100,
          totalCardBudget: 100,
          patches: [
            AnchoredScalarPatch(
              scopeKey: 'npc:ada',
              field: CardRewriteField.description,
              anchor: 'anchor',
              anchorSha256: CardCanonicalizer.scalarSha256('anchor'),
              value: replacement,
            ),
          ],
        );

    expect(
      validate('x').violations,
      isNot(contains(CardPatchViolation.totalOverBudget)),
    );
    expect(
      validate('anchor').violations,
      isNot(contains(CardPatchViolation.totalOverBudget)),
    );
    expect(
      validate('longer-than-anchor').violations,
      contains(CardPatchViolation.totalOverBudget),
    );
  });
}
