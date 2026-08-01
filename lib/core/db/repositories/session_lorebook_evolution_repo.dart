import 'package:drift/drift.dart';

import '../../models/lorebook.dart';
import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

/// Owns session-local lorebook content. It never mutates global lorebooks.
class SessionLorebookEvolutionRepo {
  const SessionLorebookEvolutionRepo(this.db);

  final AppDatabase db;

  Future<List<Lorebook>> applyOverlays({
    required String sessionId,
    required List<Lorebook> lorebooks,
  }) async {
    if (sessionId.isEmpty || lorebooks.isEmpty) return lorebooks;
    final rows = await (db.select(
      db.sessionLorebookEvolutionRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).get();
    if (rows.isEmpty) return lorebooks;
    final contentByKey = {
      for (final row in rows) '${row.lorebookId}\u0000${row.entryId}': row.content,
    };
    return [
      for (final book in lorebooks)
        book.copyWith(
          entries: [
            for (final entry in book.entries)
              entry.copyWith(
                content:
                    contentByKey['${book.id}\u0000${entry.id}'] ?? entry.content,
              ),
          ],
        ),
    ];
  }

  Future<Map<String, SessionLorebookEvolutionRow>> getByTargets({
    required String sessionId,
    required Iterable<(String lorebookId, String entryId)> targets,
  }) async {
    final keys = targets
        .map((target) => '${target.$1}\u0000${target.$2}')
        .toSet();
    if (sessionId.isEmpty || keys.isEmpty) return const {};
    final rows = await (db.select(db.sessionLorebookEvolutionRows)
          ..where((row) => row.chatSessionId.equals(sessionId)))
        .get();
    return {
      for (final row in rows)
        if (keys.contains('${row.lorebookId}\u0000${row.entryId}'))
          '${row.lorebookId}\u0000${row.entryId}': row,
    };
  }

  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
  }) async {
    final source = await (db.select(
      db.sessionLorebookEvolutionRows,
    )..where((row) => row.chatSessionId.equals(fromSessionId))).get();
    final now = currentTimestampSeconds();
    for (final row in source) {
      await db.into(db.sessionLorebookEvolutionRows).insert(
        SessionLorebookEvolutionRowsCompanion.insert(
          chatSessionId: toSessionId,
          lorebookId: row.lorebookId,
          entryId: row.entryId,
          baseContent: row.baseContent,
          baseContentHash: row.baseContentHash,
          content: row.content,
          contentHash: row.contentHash,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  }

  /// Applies an exact-once patch batch to current session content. The caller
  /// owns the surrounding transaction and supplies immutable source evidence.
  Future<bool> applyPatchesInTransaction({
    required String sessionId,
    required String lorebookId,
    required String entryId,
    required String baseContent,
    required String expectedContentHash,
    required List<LorebookAnchoredPatch> patches,
  }) async {
    if (sessionId.isEmpty ||
        lorebookId.isEmpty ||
        entryId.isEmpty ||
        patches.isEmpty) {
      return false;
    }
    final existing = await (db.select(
      db.sessionLorebookEvolutionRows,
    )..where(
          (row) =>
              row.chatSessionId.equals(sessionId) &
              row.lorebookId.equals(lorebookId) &
              row.entryId.equals(entryId),
        ))
        .getSingleOrNull();
    var next = existing?.content ?? baseContent;
    if (CardCanonicalizer.scalarSha256(next) != expectedContentHash) {
      return false;
    }
    final seenAnchors = <String>{};
    for (final patch in patches) {
      if (!seenAnchors.add(patch.anchorSha256) ||
          CardCanonicalizer.scalarSha256(patch.anchor) != patch.anchorSha256 ||
          !AnchoredScalarPatchValidator.preservesMacroTokens(
            patch.anchor,
            patch.value,
          ) ||
          _occurrences(next, patch.anchor) != 1) {
        return false;
      }
      next = next.replaceFirst(patch.anchor, patch.value);
    }
    final nextHash = CardCanonicalizer.scalarSha256(next);
    final now = currentTimestampSeconds();
    if (existing == null) {
      try {
        await db.into(db.sessionLorebookEvolutionRows).insert(
          SessionLorebookEvolutionRowsCompanion.insert(
            chatSessionId: sessionId,
            lorebookId: lorebookId,
            entryId: entryId,
            baseContent: baseContent,
            baseContentHash: CardCanonicalizer.scalarSha256(baseContent),
            content: next,
            contentHash: nextHash,
            createdAt: now,
            updatedAt: now,
          ),
        );
        return true;
      } catch (_) {
        return false;
      }
    }
    final changed = await (db.update(db.sessionLorebookEvolutionRows)..where(
          (row) =>
              row.chatSessionId.equals(sessionId) &
              row.lorebookId.equals(lorebookId) &
              row.entryId.equals(entryId) &
              row.contentHash.equals(expectedContentHash),
        ))
        .write(
          SessionLorebookEvolutionRowsCompanion(
            content: Value(next),
            contentHash: Value(nextHash),
            updatedAt: Value(now),
          ),
        );
    return changed == 1;
  }

  static int _occurrences(String value, String anchor) {
    if (anchor.isEmpty) return value.isEmpty ? 1 : 0;
    var count = 0;
    var from = 0;
    while (true) {
      final index = value.indexOf(anchor, from);
      if (index == -1) return count;
      count++;
      from = index + anchor.length;
    }
  }
}
