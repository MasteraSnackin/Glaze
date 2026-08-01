import 'dart:convert';

import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

/// Builds deterministic writer-lane prompts. Pure: no DB, UI, network, or
/// lorebook reads; untrusted output is screened separately by
/// `CardRewriteOperationParser`.
///
/// Determinism: identical inputs always produce byte-identical prompts. Every
/// dynamic input is serialized through [CardCanonicalizer] (stable key order,
/// null text normalized) and there are no timestamps, randomness, or
/// environment lookups.
abstract final class CardRewriterPromptBuilder {
  static String buildEvolution({
    required Character character,
    required String instruction,
  }) {
    final writableFields = CardRewritePolicy.nonEmptyEvolutionFields(character);
    final snapshot = Map<String, Object?>.from(CardCanonicalizer.snapshot(character));
    for (final field in CardRewritePolicy.evolutionFields) {
      if (!writableFields.contains(field)) snapshot.remove(field.wireName);
    }
    final writableFieldNames = writableFields.map((field) => field.wireName).join(', ');
    final buffer = StringBuffer()
      ..writeln(
        'You are the Glaze card rewriter. Propose small anchored scalar patches '
        'for the character card below.',
      )
      ..writeln()
      ..writeln('# Writable fields')
      ..writeln(
        writableFields.isEmpty
            ? 'No card field is writable: description, personality, and scenario '
                  'are all empty and are intentionally omitted from this request.'
            : 'Only these non-empty fields are writable: $writableFieldNames. '
                  'Empty fields are omitted and MUST NOT appear in operations. '
                  'Omit a field when its current text does not need a durable change.',
      )
      ..writeln()
      ..writeln('# Response format')
      ..writeln(
        'Respond with exactly one JSON object and nothing else: '
        '{"operations":[{"field":"description|personality|scenario",'
        '"patches":[{"scopeKey":"...","anchor":"...",'
        '"anchorSha256":"...","value":"..."}],"transition":'
        '{"id":"...","scopeKey":"...","canonicalClaim":"...",'
        '"promotionDestination":"...","affectedTrackerKeys":[],'
        '"factIds":[],"chatSessionId":null}}]}.',
      )
      ..writeln(
        'Each field may occur at most once. Return an empty "operations" list '
        'ONLY when the chat and Ledger contain no supported durable change for '
        'any writable field. A Ledger fact is accepted evidence, not a reason '
        'to omit a card patch. Use one or more exact anchors per changed field, '
        'never a full-field rewrite.',
      )
      ..writeln()
      ..writeln('# Patch rules')
      ..writeln(
        '- scopeKey supports npc:<subject>, relationship:<subject>, '
        'arc:<subject>, world:<subject>, or scene.<subject>. Every patch and '
        'its transition must use the same scopeKey. Use ASCII lowercase IDs '
        'only: for example relationship:danvi, never relationship:Danvi.',
      )
      ..writeln(
        '- Each anchor must occur exactly once in its current field and its '
        'anchorSha256 must be the lowercase SHA-256 of the anchor UTF-8 bytes. '
        'Empty anchors are forbidden. Never '
        'use chat-history text as an anchor: anchors are copied only from the '
        'canonical card field you are patching.',
      )
      ..writeln(
        '- Preserve every {{...}} macro token byte-for-byte in a replacement.',
      )
      ..writeln(
        '- Treat the immutable chat history and Ledger facts as evidence for '
        'card evolution. A supported change remains eligible even when Ledger '
        'already records it. Avoid duplication only against the supplied '
        'injected lorebook entries, not against chat history or Ledger.',
      )
      ..writeln('- Emit no keys beyond those shown above.')
      ..writeln()
      ..writeln('# User instruction')
      ..writeln(instruction)
      ..writeln()
      ..writeln('# Canonical character card snapshot (read-only)')
      ..write(jsonEncode(snapshot));
    return buffer.toString();
  }

  static String buildLorebookEvolution({required String instruction}) {
    return '''You are the Glaze lorebook rewriter. The shared read-only context below contains the character card, recent chat, Ledger facts, and exact lorebook entries actually injected into that chat.

# Writable targets
Only the supplied lorebookId/entryId pairs are writable. Do not create, delete, move, rename, or change keys/settings. Do not output card patches. The shared context includes the current card and the card writer's proposed operations. Avoid only card-lorebook duplication: do not patch an entry with a fact already represented in the current card or proposed card operations. Chat history and Ledger are evidence, not alternate durable targets; do not omit a supported lorebook patch merely because Ledger already records the fact.

# Response format
Respond with exactly one JSON object and nothing else:
{"operations":[{"lorebookId":"...","entryId":"...","baseContent":"...","expectedContentHash":"...","patches":[{"anchor":"...","anchorSha256":"...","value":"..."}]}]}
Each target may occur at most once. Return an empty "operations" list ONLY when no supported durable update belongs in any supplied target. A Ledger fact is accepted evidence, not a reason to omit an eligible lorebook patch. baseContent and expectedContentHash must exactly echo the supplied target. Each anchor must occur exactly once in its supplied current content; anchorSha256 is its lowercase SHA-256 UTF-8 hash. Use smallest exact fragment replacements, never rewrite an entire entry. Preserve every {{...}} macro token byte-for-byte.

# Instruction
$instruction''';
  }

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
        '- "anchor" MUST be a literal fragment of the current '
        '"${field.wireName}" text that occurs there EXACTLY ONCE; each anchor '
        'is replaced by its "value". If and only if the current field is empty, '
        'use an empty anchor with its SHA-256 to initialize it.',
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
