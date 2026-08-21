import 'dart:convert';

import '../../../core/constants/image_gen_patterns.dart';

/// The images one image block carries, which of them is on screen, and the
/// instruction that produced them.
///
/// A block keeps every image it has generated so the reader can page back
/// through them, so the tag payload is a list rather than a single path:
///
///     [IMG:RESULT:/a.png;;*/b.png|{"prompt":"…"}]
///     [IMG:GEN:@/a.png;;/b.png|{"prompt":"…"}]
///
/// Rules that keep older messages readable and newer ones unambiguous:
///
/// * the instruction is always the last segment, so a `|` inside a prompt is
///   never mistaken for a separator;
/// * a result block with one image keeps the historical `path|instruction`
///   spelling, and gains `;;` separators only once it holds a second image;
/// * `*` marks the visible image, and is only written when there is more than
///   one — without it the first image is the visible one;
/// * a pending block introduces its carried images with `@`, because its
///   payload is otherwise a bare instruction (JSON or plain prompt text) that
///   must keep parsing exactly as before.
class ImageBlockPayload {
  const ImageBlockPayload({
    this.paths = const [],
    this.activeIndex = 0,
    this.instruction = '',
  });

  /// Every image generated for this block, oldest first.
  final List<String> paths;

  /// Position in [paths] of the image the message shows.
  final int activeIndex;

  /// Instruction JSON (or raw prompt text) carried by the block.
  final String instruction;

  static const String _separator = ';;';
  static const String _activeMarker = '*';
  static const String _pendingMarker = '@';

  /// The image on screen, or empty when the block has none yet.
  String get activePath => paths.isEmpty
      ? ''
      : paths[activeIndex.clamp(0, paths.length - 1)];

  bool get hasVariants => paths.length > 1;

  /// Reads a `[IMG:RESULT:…]` payload, whose leading segment is the path list.
  static ImageBlockPayload parseResult(String payload) {
    final pipeIdx = payload.indexOf('|');
    final head = pipeIdx == -1 ? payload : payload.substring(0, pipeIdx);
    final instruction = pipeIdx == -1 ? '' : payload.substring(pipeIdx + 1);
    return _fromPathList(head, instruction);
  }

  /// Reads a `[IMG:GEN:…]` payload: a bare instruction, or images carried
  /// through the regeneration behind the `@` marker.
  static ImageBlockPayload parsePending(String payload) {
    if (!payload.startsWith(_pendingMarker)) {
      return ImageBlockPayload(instruction: payload);
    }
    final rest = payload.substring(_pendingMarker.length);
    final pipeIdx = rest.indexOf('|');
    final head = pipeIdx == -1 ? rest : rest.substring(0, pipeIdx);
    final instruction = pipeIdx == -1 ? '' : rest.substring(pipeIdx + 1);
    return _fromPathList(head, instruction);
  }

  static ImageBlockPayload _fromPathList(String head, String instruction) {
    final paths = <String>[];
    var active = 0;
    for (final entry in head.split(_separator)) {
      if (entry.isEmpty) continue;
      if (entry.startsWith(_activeMarker)) {
        active = paths.length;
        paths.add(entry.substring(_activeMarker.length));
      } else {
        paths.add(entry);
      }
    }
    return ImageBlockPayload(
      paths: paths,
      activeIndex: paths.isEmpty ? 0 : active.clamp(0, paths.length - 1),
      instruction: instruction,
    );
  }

  String encodeResult() {
    final head = _encodePathList();
    return instruction.isEmpty ? head : '$head|$instruction';
  }

  String encodePending() {
    if (paths.isEmpty) return instruction;
    final head = '$_pendingMarker${_encodePathList()}';
    return instruction.isEmpty ? head : '$head|$instruction';
  }

  String _encodePathList() {
    if (paths.length < 2) return paths.isEmpty ? '' : paths.first;
    final active = activeIndex.clamp(0, paths.length - 1);
    return [
      for (var i = 0; i < paths.length; i++)
        i == active ? '$_activeMarker${paths[i]}' : paths[i],
    ].join(_separator);
  }

  /// Appends [path] and puts it on screen — what a finished (re)generation
  /// does, so the previous images stay reachable through the block switcher.
  ImageBlockPayload withNewImage(String path) => ImageBlockPayload(
    paths: [...paths, path],
    activeIndex: paths.length,
    instruction: instruction,
  );

  ImageBlockPayload withActiveIndex(int index) => ImageBlockPayload(
    paths: paths,
    activeIndex: paths.isEmpty ? 0 : index.clamp(0, paths.length - 1),
    instruction: instruction,
  );

  ImageBlockPayload withPaths(List<String> newPaths, {int? activeIndex}) =>
      ImageBlockPayload(
        paths: newPaths,
        activeIndex: newPaths.isEmpty
            ? 0
            : (activeIndex ?? this.activeIndex).clamp(0, newPaths.length - 1),
        instruction: instruction,
      );

  ImageBlockPayload withInstruction(String value) => ImageBlockPayload(
    paths: paths,
    activeIndex: activeIndex,
    instruction: value,
  );

  /// The path list on its own, as carried through an error card.
  String encodePathList() => _encodePathList();

  static List<String> decodePathList(String value) =>
      _fromPathList(value, '').paths;
}

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
    this.paths = const [],
    this.activeIndex = 0,
  });

  final int start;
  final int end;
  final ImageBlockKind kind;

  /// Instruction JSON carried by the block, or empty when it has none.
  final String instruction;

  /// Visible image of a finished block; empty for the other kinds.
  final String imagePath;

  /// Every image this block has generated, oldest first. A pending or failed
  /// block carries the images of its earlier attempts here.
  final List<String> paths;

  /// Position of [imagePath] inside [paths].
  final int activeIndex;

  /// The block written back as a pending tag, prompt and earlier images
  /// included, so a regeneration neither asks the model for the prompt again
  /// nor loses the images the block already holds.
  String get asPendingTag {
    final payload = ImageBlockPayload(
      paths: paths,
      activeIndex: activeIndex,
      instruction: instruction,
    ).encodePending();
    return payload.isEmpty ? '[IMG:GEN]' : '[IMG:GEN:$payload]';
  }
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
    final instruction = ImageBlockPayload.parsePending(tag.payload).instruction;
    if (instruction.isEmpty) return <String, dynamic>{'prompt': ''};
    try {
      final decoded = jsonDecode(instruction);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return <String, dynamic>{'prompt': instruction};
  }

  static String replaceTagWithResult(String text, int index, String imagePath) {
    final tags = scanPendingTags(text);
    if (index < 0 || index >= tags.length) return text;
    final tag = tags[index];
    final instruction = _decodeInstruction(tag);
    final instrJson = instruction.isNotEmpty ? jsonEncode(instruction) : '';
    final payload = ImageBlockPayload.parsePending(tag.payload)
        .withInstruction(instrJson)
        .withNewImage(imagePath)
        .encodeResult();
    return text.replaceRange(tag.start, tag.end, '[IMG:RESULT:$payload]');
  }

  static String replaceTagWithError(String text, int index, String error) {
    final tags = scanPendingTags(text);
    if (index < 0 || index >= tags.length) return text;
    final tag = tags[index];
    final instructionJson = jsonEncode(_decodeInstruction(tag));
    // The path list rides along as a plain string: the error payload is JSON,
    // and a JSON array would close the tag on its own `]`.
    final carried = ImageBlockPayload.parsePending(tag.payload).encodePathList();
    final encoded = jsonEncode({
      'error': error,
      if (instructionJson.isNotEmpty) 'instruction': instructionJson,
      if (carried.isNotEmpty) 'variants': carried,
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

  static String resetErrorTags(String text) =>
      resetResultTags(resetImageErrorTags(text));

  /// Sends every `[IMG:ERROR:…]` card back to pending, keeping its prompt and
  /// the images its earlier attempts produced.
  static String resetImageErrorTags(String text) {
    return text.replaceAllMapped(ImgGenPatterns.imgErrorRegex, (m) {
      try {
        final json = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        return _pendingTag(
          ImageBlockPayload(
            paths: ImageBlockPayload.decodePathList(
              json['variants'] as String? ?? '',
            ),
            instruction: json['instruction'] as String? ?? '',
          ),
        );
      } catch (_) {}
      return '[IMG:GEN]';
    });
  }

  /// Sends every finished `[IMG:RESULT:…]` block back to pending, keeping its
  /// prompt and the images it already holds.
  static String resetResultTags(String text) {
    return text.replaceAllMapped(ImgGenPatterns.imgResultRegex, (m) {
      return _pendingTag(ImageBlockPayload.parseResult(m.group(1) ?? ''));
    });
  }

  static String _pendingTag(ImageBlockPayload payload) {
    final encoded = payload.encodePending();
    return encoded.isEmpty ? '[IMG:GEN]' : '[IMG:GEN:$encoded]';
  }

  /// Every image block of [text] in document order, whatever state it is in.
  ///
  /// This is the numbering the chat webview renders against, so a block index
  /// coming back from a tap addresses exactly one image of the message.
  static List<ImageBlock> scanImageBlocks(String text) {
    final blocks = <ImageBlock>[
      for (final tag in scanPendingTags(text))
        _pendingBlock(tag),
    ];

    // A resolved token can never sit inside a pending tag; the guard just keeps
    // a tag whose payload happens to quote one from being counted twice.
    bool insidePendingTag(RegExpMatch match) => blocks.any(
      (block) => match.start < block.end && block.start < match.end,
    );

    for (final match in ImgGenPatterns.imgResultRegex.allMatches(text)) {
      if (insidePendingTag(match)) continue;
      final payload = ImageBlockPayload.parseResult(match.group(1) ?? '');
      blocks.add(
        ImageBlock(
          start: match.start,
          end: match.end,
          kind: ImageBlockKind.result,
          instruction: payload.instruction,
          imagePath: payload.activePath,
          paths: payload.paths,
          activeIndex: payload.activeIndex,
        ),
      );
    }

    for (final match in ImgGenPatterns.imgErrorRegex.allMatches(text)) {
      if (insidePendingTag(match)) continue;
      var instruction = '';
      var carried = const <String>[];
      try {
        final parsed = jsonDecode(match.group(1) ?? '');
        if (parsed is Map) {
          instruction = parsed['instruction'] as String? ?? '';
          carried = ImageBlockPayload.decodePathList(
            parsed['variants'] as String? ?? '',
          );
        }
      } catch (_) {}
      blocks.add(
        ImageBlock(
          start: match.start,
          end: match.end,
          kind: ImageBlockKind.error,
          instruction: instruction,
          paths: carried,
        ),
      );
    }

    blocks.sort((a, b) => a.start.compareTo(b.start));
    return blocks;
  }

  static ImageBlock _pendingBlock(PendingImageTag tag) {
    final payload = ImageBlockPayload.parsePending(tag.payload);
    return ImageBlock(
      start: tag.start,
      end: tag.end,
      kind: ImageBlockKind.pending,
      instruction: payload.instruction,
      paths: payload.paths,
      activeIndex: payload.activeIndex,
    );
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
    final payload = ImageBlockPayload(
      paths: block.paths,
      activeIndex: block.activeIndex,
      instruction: block.instruction,
    ).withNewImage(imagePath).encodeResult();
    return text.replaceRange(block.start, block.end, '[IMG:RESULT:$payload]');
  }

  /// Puts the [variantIndex]-th image of the [blockIndex]-th block on screen.
  ///
  /// Returns [text] unchanged when either index addresses nothing or the block
  /// already shows that image, which the caller reads as "nothing to do".
  static String setImageBlockVariant(
    String text,
    int blockIndex,
    int variantIndex,
  ) {
    final blocks = scanImageBlocks(text);
    if (blockIndex < 0 || blockIndex >= blocks.length) return text;
    final block = blocks[blockIndex];
    if (block.kind != ImageBlockKind.result) return text;
    if (variantIndex < 0 || variantIndex >= block.paths.length) return text;
    if (variantIndex == block.activeIndex) return text;
    final payload = ImageBlockPayload(
      paths: block.paths,
      activeIndex: variantIndex,
      instruction: block.instruction,
    ).encodeResult();
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
      final payload = ImageBlockPayload.parseResult(match.group(1) ?? '');
      // Every variant is resolved, not just the visible one: the switcher
      // swaps the image in the page, and a variant it cannot address would
      // read as a picture that vanished. A variant that cannot be served is
      // dropped from the block instead.
      final resolved = <String>[];
      var active = 0;
      for (var i = 0; i < payload.paths.length; i++) {
        final url = resolve(payload.paths[i]);
        if (url == null) continue;
        if (i == payload.activeIndex) active = resolved.length;
        resolved.add(url);
      }
      if (resolved.isEmpty) return '';
      final rewritten = payload
          .withPaths(resolved, activeIndex: active)
          .encodeResult();
      return '[IMG:RESULT:$rewritten]';
    });
  }

  /// The image an `[IMG:RESULT:…]` payload shows — instruction suffix and the
  /// block's other variants stripped.
  static String normalizeImageResultPayload(String payload) =>
      ImageBlockPayload.parseResult(payload).activePath;

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
      final payload = ImageBlockPayload.parseResult(match.group(1)!)
          .withNewImage(newPath)
          .encodeResult();
      return '[IMG:RESULT:$payload]';
    });
  }
}
