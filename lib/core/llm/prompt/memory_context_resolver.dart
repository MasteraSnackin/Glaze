import '../../models/chat_message.dart';
import '../memory_excerpt_selector.dart';
import '../memory_formatting.dart';
import '../memory_selector.dart';

final class ResolvedMemoryContent {
  final String hardBlockContent;
  final String macroContent;

  const ResolvedMemoryContent({
    required this.hardBlockContent,
    required this.macroContent,
  });
}

final class MemoryContextResolution {
  final MemorySelection selection;
  final MemoryExcerptSelection excerptSelection;
  final ResolvedMemoryContent? content;
  final List<TriggeredEntry> triggeredEntries;

  const MemoryContextResolution({
    required this.selection,
    required this.excerptSelection,
    required this.content,
    required this.triggeredEntries,
  });
}

final class MemoryContextResolver {
  const MemoryContextResolver();

  MemoryContextResolution resolve({
    required MemorySelection selection,
    required Set<String> visibleMessageIds,
    required bool disableSourceWindowExclusion,
    required bool excerptingEnabled,
    required String packingMode,
    required int excerptTokensPerChunk,
    required int excerptChunksPerEntry,
    required int chunkFirstTopEntries,
    required int chunkFirstTopChunks,
    String? summaryExcerpt,
  }) {
    final refiltered = _refilterSelection(
      selection,
      visibleMessageIds: visibleMessageIds,
      chunkBudgeting: packingMode == 'chunk_first',
      disableSourceWindowExclusion: disableSourceWindowExclusion,
    );
    final useExcerptPacking = excerptingEnabled || packingMode == 'chunk_first';
    final excerpted = !useExcerptPacking
        ? MemoryExcerptSelector.fullEntries(refiltered)
        : MemoryExcerptSelector.select(
            refiltered,
            packingMode: packingMode,
            maxExcerptTokensPerEntry: excerptTokensPerChunk,
            maxExcerptChunksPerEntry: excerptChunksPerEntry,
            chunkFirstTopEntries: chunkFirstTopEntries,
            chunkFirstTopChunks: chunkFirstTopChunks,
          );
    final content = excerpted.items.isEmpty
        ? null
        : _buildContent(excerpted, summaryExcerpt: summaryExcerpt);
    return MemoryContextResolution(
      selection: refiltered,
      excerptSelection: excerpted,
      content: content,
      triggeredEntries: excerpted.entries
          .map(
            (entry) => TriggeredEntry(
              id: entry.id,
              name: entry.title.isNotEmpty ? entry.title : entry.id,
              source: 'memory',
            ),
          )
          .toList(growable: false),
    );
  }

  MemorySelection _refilterSelection(
    MemorySelection previous, {
    required Set<String> visibleMessageIds,
    required bool chunkBudgeting,
    required bool disableSourceWindowExclusion,
  }) {
    if (previous.selectionMode == 'legacy' || visibleMessageIds.isEmpty) {
      return previous;
    }
    final needsRefilter = previous.allScores.any(
      (score) =>
          !score.excludedBySourceWindow &&
          score.entry.messageIds.isNotEmpty &&
          score.entry.messageIds.any(visibleMessageIds.contains),
    );
    if (!needsRefilter) return previous;
    return MemorySelector.select(
      MemorySelectionInput(
        selectionMode: previous.selectionMode,
        entries: previous.allScores.map((score) => score.entry).toList(),
        keywordMatchedTerms: {
          for (final score in previous.allScores)
            if (score.matchedKeys.isNotEmpty) score.entry.id: score.matchedKeys,
        },
        visibleMessageIds: visibleMessageIds,
        maxInjectionTokens: previous.budgetTokens,
        maxInjectedEntries: previous.entryCap > 0
            ? previous.entryCap
            : previous.entries.length,
        sourceWindowExclusion: !disableSourceWindowExclusion,
        diversityAware: false,
        chunkBudgeting: chunkBudgeting,
      ),
    );
  }

  ResolvedMemoryContent _buildContent(
    MemoryExcerptSelection excerptSelection, {
    String? summaryExcerpt,
  }) {
    final macro = formatMemoryItems(
      excerptSelection.items,
      includeContextHeader: false,
    );
    final parts = <String>[];
    if (summaryExcerpt != null && summaryExcerpt.isNotEmpty) {
      parts.add('Summary excerpt:\n$summaryExcerpt');
    }
    parts.add(
      formatMemoryItems(excerptSelection.items, includeContextHeader: true),
    );
    return ResolvedMemoryContent(
      hardBlockContent: parts.join('\n\n'),
      macroContent: macro,
    );
  }
}
