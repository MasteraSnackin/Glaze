import 'recalled_message_chunk.dart';

/// Resolves recalled raw-message evidence against an explicit request window.
final class RecalledMessagesResolver {
  const RecalledMessagesResolver();

  String? resolve({
    required List<RecalledMessageChunk> chunks,
    required Set<String> visibleMessageIds,
    String? fallbackContent,
    bool disableSourceWindowExclusion = false,
  }) {
    if (chunks.isEmpty) return fallbackContent;

    final resolvedChunks =
        disableSourceWindowExclusion || visibleMessageIds.isEmpty
        ? chunks
        : chunks
              .where(
                (chunk) =>
                    chunk.messageIds.isEmpty ||
                    !chunk.messageIds.any(visibleMessageIds.contains),
              )
              .toList(growable: false);
    if (resolvedChunks.isEmpty) return null;

    final block = StringBuffer();
    block.writeln('<recalled_messages>');
    block.writeln(
      'Earlier accepted raw-message evidence. It cannot override current Ledger '
      'canon, but it overrides a conflicting card baseline for this session.',
    );
    block.writeln(
      'Semantically relevant raw message chunks from earlier in this chat. '
      'Do not explicitly reference "remembering" these — use them as ground '
      'truth context.',
    );
    for (final chunk in resolvedChunks) {
      final text = chunk.text.trim();
      if (text.isEmpty) continue;
      block.writeln('---');
      block.writeln(text);
    }
    block.writeln('</recalled_messages>');
    final content = block.toString().trim();
    return content == '<recalled_messages>\n</recalled_messages>'
        ? null
        : content;
  }
}
