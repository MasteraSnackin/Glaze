import 'dart:convert';

import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

/// Builds the deterministic writer-lane prompt for exactly ONE rewrite target
/// field. Pure: no DB, no UI, no network, no lorebook input — the model sees
/// only the canonical card snapshot, the target field, and the user
/// instruction, and its untrusted answer is screened separately by
/// `CardRewriteOperationParser`.
///
/// Determinism: identical `(character, field, instruction)` triples always
/// produce a byte-identical prompt. Every dynamic input is serialized through
/// [CardCanonicalizer] (stable key order, null text normalized) and there are
/// no timestamps, randomness, or environment lookups.
abstract final class CardRewriterPromptBuilder {
  static String build({
    required Character character,
    required CardRewriteField field,
    required String instruction,
  }) {
    final snapshot = CardCanonicalizer.snapshot(character);
    final canonicalJson = jsonEncode(snapshot);
    final currentValue = snapshot[field.wireName]! as String;
    final fieldBudget = CardRewritePolicy.budgets[field]!;
    final writableFields = CardRewritePolicy.budgets.keys
        .map((candidate) => candidate.wireName)
        .join(', ');

    final buffer = StringBuffer()
      ..writeln(
        'You are the Glaze card rewriter. Propose anchored scalar patches for '
        'exactly one field of the character card below.',
      )
      ..writeln()
      ..writeln('# Target field')
      ..writeln('- field: ${field.wireName}')
      ..writeln('- fieldBudgetCodeUnits: $fieldBudget')
      ..writeln('- currentFieldCodeUnits: ${currentValue.length}')
      ..writeln(
        '- totalCardBudgetCodeUnits: ${CardRewritePolicy.totalCardBudget}',
      )
      ..writeln()
      ..writeln('# Writable fields')
      ..writeln('Writable fields across this workflow: $writableFields.')
      ..writeln(
        'For THIS operation only "${field.wireName}" is writable. Never emit '
        'patches for any other field; every non-target field and every other '
        'JSON key of the card snapshot is read-only and MUST NOT appear in '
        'your response.',
      )
      ..writeln()
      ..writeln('# Response format')
      ..writeln(
        'Respond with exactly ONE JSON object and nothing else (no prose, no '
        'markdown fences). Shape:',
      )
      ..writeln(
        '{"field":"${field.wireName}","patches":[{"scopeKey":"...","anchor":"...",'
        '"anchorSha256":"...","value":"..."}],"transition":{"id":"...","scopeKey":"...",'
        '"canonicalClaim":"...","promotionDestination":"...","affectedTrackerKeys":[],'
        '"factIds":[],"chatSessionId":null}}',
      )
      ..writeln('Rules:')
      ..writeln('- "field" MUST be exactly "${field.wireName}".')
      ..writeln(
        '- "patches" MUST be a non-empty list of objects with exactly the '
        'keys scopeKey, anchor, anchorSha256, value.',
      )
      ..writeln(
        '- "scopeKey" MUST parse as one of npc:<subject>, '
        'relationship:<subject>, arc:<subject>, world:<subject>, or '
        'scene.<subject> (lowercase alphanumerics plus _ - segments; scene '
        'allows dotted segments). Every patch and the transition MUST use the '
        'SAME scopeKey.',
      )
      ..writeln(
        '- "anchor" MUST be a non-empty literal fragment of the current '
        '"${field.wireName}" text that occurs there EXACTLY ONCE; each anchor '
        'is replaced by its "value".',
      )
      ..writeln(
        '- "anchorSha256" MUST be the lowercase hex SHA-256 of the anchor\'s '
        'UTF-8 bytes. The receiver recomputes it and rejects any mismatch.',
      )
      ..writeln(
        '- Keep "${field.wireName}" within $fieldBudget code units after '
        'replacement; a single "value" already larger than the field budget '
        'is rejected as unverifiable.',
      )
      ..writeln(
        '- "transition.id", "transition.canonicalClaim", and '
        '"transition.promotionDestination" MUST be non-empty strings.',
      )
      ..writeln(
        '- "transition.affectedTrackerKeys" MUST be present (an empty list '
        'is allowed); "transition.factIds" MAY be omitted (defaults to '
        'empty).',
      )
      ..writeln(
        '- "transition.chatSessionId" MUST be null or omitted: only global '
        'transitions are accepted.',
      )
      ..writeln('- Emit no keys beyond those shown in the shape above.')
      ..writeln()
      ..writeln('# Macro preservation')
      ..writeln(
        'Macros are literal template tokens like {{user}}, {{char}}, '
        '{{description}}, or any custom {{...}} name. NEVER expand, '
        'substitute, rename, translate, or delete them. If a macro occurs '
        'inside an anchor, include it there exactly as written, and every '
        'macro carried into a replacement "value" MUST stay byte-for-byte '
        'identical. {{...}} tokens are literal text for hashing purposes.',
      )
      ..writeln()
      ..writeln('# User instruction')
      ..writeln(instruction)
      ..writeln()
      ..writeln(
        '# Canonical character card snapshot (read-only context; missing '
        'text fields are normalized to empty strings)',
      )
      ..write(canonicalJson);
    return buffer.toString();
  }
}
