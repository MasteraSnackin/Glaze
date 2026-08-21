import 'dart:convert';

import '../../../core/constants/image_gen_patterns.dart';

/// One pending image tag located in a message: the span it occupies and the
/// raw instruction payload it carries.
class PendingImageTag {
  const PendingImageTag(this.start, this.end, this.payload);

  /// Offset of the first character of the tag inside the scanned text.
  final int start;

  /// Offset just past the last character of the tag.
  final int end;

  /// Raw instruction payload — the `data-iig-instruction` attribute value or
  /// whatever follows `[IMG:GEN:`. Empty when the tag carries no instruction.
  final String payload;
}

/// State of one image block inside a message.
enum ImageBlockKind {
  /// `[IMG:GEN…]` — still waiting for its image.
  pending,

  /// `[IMG:RESULT:…]` — the image arrived and is on disk.
  result,

  /// `[IMG:ERROR:…]` — the image did not arrive; the block offers a retry.
  error,
}

/// One image block of a message, whatever state it is in. Its position in
/// [ImageTagMarkup.scanImageBlocks] is the index the chat webview tags each
/// rendered block with, so a per-image action addresses exactly this block.
class ImageBlock {
  const ImageBlock({
    required this.start,
    required this.end,
    required this.kind,
    required this.instruction,
    this.imagePath = '',
  });

  final int start;
  final int end;
  final ImageBlockKind kind;

  /// Instruction JSON carried by the block, or empty when it has none.
  final String instruction;

  /// Saved file of a finished block; empty for the other kinds.
  final String imagePath;

  /// The block written back as a pending tag, prompt included, so a
  /// regeneration does not have to ask the model for the prompt again.
  String get asPendingTag =>
      instruction.isEmpty ? '[IMG:GEN]' : '[IMG:GEN:$instruction]';
}

/// Pure text transformations for `[IMG:GEN]` / `[IMG:RESULT:]` / `[IMG:ERROR]`
/// image-gen tag markup. Has no dependency on image generation, file I/O, or
/// network — only on [ImgGenPatterns] and JSON encoding.
///
/// Every operation is anchored on [scanPendingTags], a single document-ordered
/// pass over the four tag spellings. Resolving one tag rewrites only that tag's
/// span, so the other pending tags of the same message survive untouched —
/// a message with several images keeps every block until its own image lands.
class ImageTagMarkup {
  ImageTagMarkup._();

  /// Pending image tags in document order, deduplicated across the spellings
  /// that can match the same `<img>` element.
  ///
  /// HTML forms win over the bare `[IMG:GEN…]` they wrap, so an
  /// `<img data-iig-instruction='…' src="[IMG:GEN]">` counts once and is
  /// replaced as a whole element.
  static List<PendingImageTag> scanPendingTags(String text) {
    if (!text.contains('[IMG:GEN') && !text.contains('data-iig-instruction')) {
      return const [];
    }

    final tags = <PendingImageTag>[];
    bool overlapsExisting(int start, int end) =>
        tags.any((tag) => start < tag.end && tag.start < end);

    void collect(RegExp pattern, String? Function(RegExpMatch) payloadOf) {
      for (final match in pattern.allMatches(text)) {
        if (overlapsExisting(match.start, match.end)) continue;
        tags.add(
          PendingImageTag(match.start, match.end, payloadOf(match) ?? ''),
        );
      }
    }

    collect(ImgGenPatterns.htmlIigTagRegex, (m) => m.group(1));
    collect(ImgGenPatterns.htmlIigTagDoubleRegex, (m) => m.group(1));
    // `<img src="[IMG:GEN:…]">` without the instruction attribute: the payload
    // lives in the src, but the whole element is what gets replaced.
    collect(
      ImgGenPatterns.imgSrcGenRegex,
      (m) => ImgGenPatterns.imgGenRegex.firstMatch(m.group(0)!)?.group(1),
    );
    collect(ImgGenPatterns.imgGenRegex, (m) => m.group(1));

    tags.sort((a, b) => a.start.compareTo(b.start));
    return tags;
  }

  static bool hasImageGenTags(String text) => scanPendingTags(text).isNotEmpty;

  /// How many image tags of [text] are still waiting for their image.
  static int pendingImageGenTagCount(String text) =>
      scanPendingTags(text).length;

  static List<Map<String, dynamic>> extractImageGenInstructions(String text) =>
      scanPendingTags(text).map(_decodeInstruction).toList();

  static Map<String, dynamic> _decodeInstruction(PendingImageTag tag) {
    if (tag.payload.isEmpty) return <String, dynamic>{'prompt': ''};
    try {
      final decoded = jsonDecode(tag.payload);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return <String, dynamic>{'prompt': tag.payload};
  }

  static String replaceTagWithResult(String text, int index, String imagePath) {
    final tags = scanPendingTags(text);
    if (index < 0 || index >= tags.length) return text;
    final tag = tags[index];
    final instruction = _decodeInstruction(tag);
    final instrJson = instruction.isNotEmpty ? jsonEncode(instruction) : '';
    final payload = instrJson.isNotEmpty ? '$imagePath|$instrJson' : imagePath;
    return text.replaceRange(tag.start, tag.end, '[IMG:RESULT:$payload]');
  }

  static String replaceTagWithError(String text, int index, String error) {
    final tags = scanPendingTags(text);
    if (index < 0 || index >= tags.length) return text;
    final tag = tags[index];
    final instructionJson = jsonEncode(_decodeInstruction(tag));
    final encoded = jsonEncode({
      'error': error,
      if (instructionJson.isNotEmpty) 'instruction': instructionJson,
    });
    return text.replaceRange(tag.start, tag.end, '[IMG:ERROR:$encoded]');
  }

  /// Resolves every pending image tag to a retryable disabled-state error.
  /// Keeping the original instruction lets the UI enable image generation and
  /// immediately retry the same message without asking the model again.
  static String replaceAllImageGenTagsWithDisabled(String text) {
    var result = text;
    while (hasImageGenTags(result)) {
      final replaced = replaceTagWithError(
        result,
        0,
        'Image generation disabled',
      );
      if (replaced == result) break;
      result = replaced;
    }
    return result;
  }

  static String resetErrorTags(String text) {
    var result = text.replaceAllMapped(ImgGenPatterns.imgErrorRegex, (m) {
      try {
        final json = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        final instruction = json['instruction'] as String?;
        if (instruction != null && instruction.isNotEmpty) {
          return '[IMG:GEN:$instruction]';
        }
      } catch (_) {}
      return '[IMG:GEN]';
    });
    result = result.replaceAllMapped(ImgGenPatterns.imgResultRegex, (m) {
      final raw = m.group(1) ?? '';
      final pipeIdx = raw.indexOf('|');
      final instr = pipeIdx != -1 ? raw.substring(pipeIdx + 1) : null;
      if (instr != null && instr.isNotEmpty) {
        return '[IMG:GEN:$instr]';
      }
      return '[IMG:GEN]';
    });
    return result;
  }

  /// Every image block of [text] in document order, whatever state it is in.
  ///
  /// This is the numbering the chat webview renders against, so a block index
  /// coming back from a tap addresses exactly one image of the message.
  static List<ImageBlock> scanImageBlocks(String text) {
    final blocks = <ImageBlock>[
      for (final tag in scanPendingTags(text))
        ImageBlock(
          start: tag.start,
          end: tag.end,
          kind: ImageBlockKind.pending,
          instruction: tag.payload,
        ),
    ];

    // A resolved token can never sit inside a pending tag; the guard just keeps
    // a tag whose payload happens to quote one from being counted twice.
    bool insidePendingTag(RegExpMatch match) => blocks.any(
      (block) => match.start < block.end && block.start < match.end,
    );

    for (final match in ImgGenPatterns.imgResultRegex.allMatches(text)) {
      if (insidePendingTag(match)) continue;
      final raw = match.group(1) ?? '';
      final pipeIdx = raw.indexOf('|');
      blocks.add(
        ImageBlock(
          start: match.start,
          end: match.end,
          kind: ImageBlockKind.result,
          instruction: pipeIdx != -1 ? raw.substring(pipeIdx + 1) : '',
          imagePath: normalizeImageResultPayload(raw),
        ),
      );
    }

    for (final match in ImgGenPatterns.imgErrorRegex.allMatches(text)) {
      if (insidePendingTag(match)) continue;
      var instruction = '';
      try {
        final parsed = jsonDecode(match.group(1) ?? '');
        if (parsed is Map) instruction = parsed['instruction'] as String? ?? '';
      } catch (_) {}
      blocks.add(
        ImageBlock(
          start: match.start,
          end: match.end,
          kind: ImageBlockKind.error,
          instruction: instruction,
        ),
      );
    }

    blocks.sort((a, b) => a.start.compareTo(b.start));
    return blocks;
  }

  /// Sends the [index]-th image block back to pending, keeping its prompt.
  ///
  /// Returns [text] unchanged when the index addresses nothing or the block is
  /// already waiting for its image — the caller reads that as "nothing to do".
  static String resetImageBlockAt(String text, int index) {
    final blocks = scanImageBlocks(text);
    if (index < 0 || index >= blocks.length) return text;
    final block = blocks[index];
    if (block.kind == ImageBlockKind.pending) return text;
    return text.replaceRange(block.start, block.end, block.asPendingTag);
  }

  /// Points the [index]-th image block at [imagePath], keeping its prompt.
  static String replaceImageBlockWithResult(
    String text,
    int index,
    String imagePath,
  ) {
    final blocks = scanImageBlocks(text);
    if (index < 0 || index >= blocks.length) return text;
    final block = blocks[index];
    final payload = block.instruction.isEmpty
        ? imagePath
        : '$imagePath|${block.instruction}';
    return text.replaceRange(block.start, block.end, '[IMG:RESULT:$payload]');
  }

  static List<String> extractImageResultPaths(String text) {
    return ImgGenPatterns.imgResultRegex
        .allMatches(text)
        .map((m) => normalizeImageResultPayload(m.group(1) ?? ''))
        .where((p) => p.isNotEmpty)
        .toList();
  }

  /// Rewrites the file path inside every `[IMG:RESULT:…]` tag with [resolve],
  /// dropping the whole tag when it returns null.
  ///
  /// The payload is split exactly like the WebView formatter does — the tag
  /// ends at the first `]`, the path ends at the first `|` — so an instruction
  /// JSON carrying a `]` cannot leave the two sides disagreeing about which
  /// substring is the path. A stricter pattern skipped such a tag, and the raw
  /// filesystem path then reached the page as `file://…`, which the chat
  /// WebView (an https / loopback origin) cannot load at all: the message
  /// rendered a broken image.
  static String rewriteResultPaths(
    String text,
    String? Function(String path) resolve,
  ) {
    return text.replaceAllMapped(ImgGenPatterns.imgResultRegex, (match) {
      final payload = match.group(1) ?? '';
      final pipeIdx = payload.indexOf('|');
      final path = pipeIdx == -1 ? payload : payload.substring(0, pipeIdx);
      final suffix = pipeIdx == -1 ? '' : payload.substring(pipeIdx);
      final resolved = resolve(path);
      return resolved == null ? '' : '[IMG:RESULT:$resolved$suffix]';
    });
  }

  /// Strips optional `|instructionJson` suffix from [IMG:RESULT:…] payloads.
  static String normalizeImageResultPayload(String payload) {
    final pipeIdx = payload.indexOf('|');
    return pipeIdx != -1 ? payload.substring(0, pipeIdx) : payload;
  }

  /// [contentsNewestFirst] — text blobs ordered newest → oldest (e.g. ext-block bodies).
  static List<String> collectRecentImageResultPaths(
    Iterable<String> contentsNewestFirst, {
    int maxPaths = 3,
  }) {
    final collected = <String>[];
    for (final content in contentsNewestFirst) {
      if (collected.length >= maxPaths) break;
      for (final path in extractImageResultPaths(content)) {
        if (collected.length >= maxPaths) break;
        collected.add(path);
      }
    }
    return collected.reversed.toList();
  }

  /// Reads image instructions from pending [IMG:GEN] tags or finished
  /// [IMG:RESULT:path|json] tokens inside ext-block HTML.
  static List<Map<String, dynamic>> extractInstructionsFromImageContent(
    String text,
  ) {
    final fromGen = extractImageGenInstructions(text);
    if (fromGen.isNotEmpty) return fromGen;

    final fromResult = <Map<String, dynamic>>[];
    for (final match in ImgGenPatterns.imgResultRegex.allMatches(text)) {
      final raw = match.group(1) ?? '';
      final pipeIdx = raw.indexOf('|');
      if (pipeIdx < 0 || pipeIdx >= raw.length - 1) continue;
      try {
        fromResult.add(
          jsonDecode(raw.substring(pipeIdx + 1)) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    return fromResult;
  }

  /// Replaces the [index]-th [IMG:RESULT:…] token, preserving instruction JSON.
  static String replaceExtBlockImageResult(
    String text,
    String newPath, {
    int index = 0,
  }) {
    var count = 0;
    return text.replaceAllMapped(ImgGenPatterns.imgResultRegex, (match) {
      if (count++ != index) return match.group(0)!;
      final raw = match.group(1)!;
      final pipeIdx = raw.indexOf('|');
      final suffix = pipeIdx != -1 ? raw.substring(pipeIdx) : '';
      return '[IMG:RESULT:$newPath$suffix]';
    });
  }
}
