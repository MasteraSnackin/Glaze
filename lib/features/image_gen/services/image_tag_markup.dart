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

  static List<String> extractImageResultPaths(String text) {
    return ImgGenPatterns.imgResultRegex
        .allMatches(text)
        .map((m) => normalizeImageResultPayload(m.group(1) ?? ''))
        .where((p) => p.isNotEmpty)
        .toList();
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
