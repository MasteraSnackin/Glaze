import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/utils/platform_paths.dart';
import '../image_gen_capabilities.dart';
import '../image_gen_models.dart';
import 'image_tag_markup.dart';
import 'reference_matcher.dart';

/// Builds the reference-image list for one generation request.
///
/// Order follows https://github.com/0xl0cal/sillyimages: character avatar,
/// persona avatar, matched library references, then previously generated
/// context images. The list is clipped to what the active provider/model
/// accepts ([providerMaxReferences]).
///
/// Every entry is a flat map so the provider clients can stay independent of
/// this class: `name`, `image` (bare base64), `mime`, `description` and
/// `source` (`char` | `user` | `additional` | `context`).
class ImageReferenceCollector {
  const ImageReferenceCollector();

  Future<List<Map<String, String>>> collect({
    required ImageGenSettings settings,
    required String prompt,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
  }) async {
    final maxRefs = providerMaxReferences(settings);
    if (maxRefs <= 0) return const [];

    // rout.my rejects oversized JSON payloads, so its references are
    // downscaled before they are encoded.
    final resize =
        settings.apiType == ImageGenApiType.routmy ||
        settings.apiType == ImageGenApiType.ruRoutmy;

    final refs = <Map<String, String>>[];

    if (settings.sendCharAvatar && character?.avatarPath != null) {
      final entry = await _fromFile(
        character!.avatarPath!,
        name: character.name,
        description: character.name,
        source: 'char',
        resize: resize,
      );
      if (entry != null) refs.add(entry);
    }
    if (settings.sendUserAvatar && persona?.avatarPath != null) {
      final entry = await _fromFile(
        persona!.avatarPath!,
        name: persona.name,
        description: persona.name,
        source: 'user',
        resize: resize,
      );
      if (entry != null) refs.add(entry);
    }

    for (final ref in matchReferences(prompt, settings.references)) {
      final image = _stripDataUrl(ref.imageData);
      if (image.isEmpty) continue;
      refs.add({
        'name': ref.name.trim(),
        'image': image,
        'mime': _mimeFromDataUrl(ref.imageData),
        'description': ref.description.trim().isEmpty
            ? ref.name.trim()
            : ref.description.trim(),
        'source': 'additional',
      });
    }

    if (settings.imageContextEnabled && recentImageContexts != null) {
      final count = settings.imageContextCount.clamp(1, 3);
      for (final context in recentImageContexts.take(count)) {
        final path = ImageTagMarkup.normalizeImageResultPayload(context);
        final entry = await _fromFile(
          path,
          name: 'context',
          description: '',
          source: 'context',
          resize: resize,
        );
        if (entry != null) refs.add(entry);
      }
    }

    return refs.length > maxRefs ? refs.sublist(0, maxRefs) : refs;
  }

  Future<Map<String, String>?> _fromFile(
    String path, {
    required String name,
    required String description,
    required String source,
    required bool resize,
  }) async {
    final image = resize
        ? await _fileToBase64Resized(path)
        : _fileToBase64(path);
    if (image.isEmpty) return null;
    return {
      'name': name,
      'image': image,
      'mime': resize ? 'image/jpeg' : _mimeFromPath(path),
      'description': description,
      'source': source,
    };
  }

  String _fileToBase64(String path) {
    try {
      final resolved = resolveGlazeFilePath(path) ?? path;
      final file = File(resolved);
      if (!file.existsSync()) return '';
      return base64Encode(file.readAsBytesSync());
    } catch (_) {
      return '';
    }
  }

  /// Reads an image file, resizes so the longest side ≤ [maxSide] px and
  /// re-encodes as JPEG. Falls back to the raw bytes on any error.
  Future<String> _fileToBase64Resized(
    String path, {
    int maxSide = 512,
    int jpegQuality = 85,
  }) async {
    try {
      final resolved = resolveGlazeFilePath(path) ?? path;
      final file = File(resolved);
      if (!file.existsSync()) return '';
      final bytes = file.readAsBytesSync();

      final decoded = await compute(
        _decodeAndResizeJpeg,
        _ResizeArgs(bytes, maxSide, jpegQuality),
      );
      if (decoded == null) return base64Encode(bytes);
      return base64Encode(decoded);
    } catch (_) {
      return _fileToBase64(path);
    }
  }

  static String _stripDataUrl(String dataUrl) {
    final commaIndex = dataUrl.indexOf(',');
    if (commaIndex == -1) return dataUrl;
    return dataUrl.substring(commaIndex + 1);
  }

  static String _mimeFromDataUrl(String dataUrl) {
    if (!dataUrl.startsWith('data:')) return 'image/png';
    final end = dataUrl.indexOf(';');
    return end > 5 ? dataUrl.substring(5, end) : 'image/png';
  }

  static String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }
}

// ─── Isolate helpers for JPEG resize ────────────────────────────────────────

class _ResizeArgs {
  const _ResizeArgs(this.bytes, this.maxSide, this.jpegQuality);
  final Uint8List bytes;
  final int maxSide;
  final int jpegQuality;
}

/// Runs in a separate isolate via [compute]. Returns null on any error so the
/// caller can fall back to the raw bytes.
Uint8List? _decodeAndResizeJpeg(_ResizeArgs args) {
  try {
    final src = img.decodeImage(args.bytes);
    if (src == null) return null;
    final resized = img.copyResize(
      src,
      width: src.width >= src.height ? args.maxSide : -1,
      height: src.height > src.width ? args.maxSide : -1,
      interpolation: img.Interpolation.linear,
    );
    return Uint8List.fromList(
      img.encodeJpg(resized, quality: args.jpegQuality),
    );
  } catch (_) {
    return null;
  }
}
