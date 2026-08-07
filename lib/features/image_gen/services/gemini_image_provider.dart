import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'image_gen_http.dart';
import 'image_prompt_builder.dart';

class GeminiImageProvider {
  final ImageGenHttp _http = ImageGenHttp();

  Future<Uint8List> generate({
    required String endpoint,
    required String apiKey,
    required String model,
    required String prompt,
    required String aspectRatio,
    required String? imageSize,
    List<Map<String, String>>? referenceImages,
    CancelToken? cancelToken,
  }) async {
    final url = _generationUrl(endpoint, model);
    final parts = <Map<String, dynamic>>[];
    var index = 0;
    for (final reference in referenceImages ?? const <Map<String, String>>[]) {
      final image = reference['image'];
      if (image == null || image.isEmpty) continue;
      index++;
      // `IMAGE_1: red-haired mage` tells the model who the next picture shows.
      final label = geminiImageLabel(index, reference['description']);
      if (label.isNotEmpty) parts.add({'text': label});
      parts.add({
        'inlineData': {
          'mimeType': reference['mime'] ?? _mimeFromImage(image),
          'data': ImageGenHttp.stripBase64Prefix(image),
        },
      });
    }
    parts.add({'text': prompt});

    final json = await _http.post(
      url: url,
      apiKey: apiKey,
      body: {
        'contents': [
          {'role': 'user', 'parts': parts},
        ],
        'generationConfig': {
          'responseModalities': ['TEXT', 'IMAGE'],
          // Gemini 2.5 Flash Image rejects imageSize — the caller passes null.
          'imageConfig': {'aspectRatio': aspectRatio, 'imageSize': ?imageSize},
        },
      },
      cancelToken: cancelToken,
    );
    return ImageGenHttp.base64ToBytes(_extractImageBase64(json));
  }

  String _generationUrl(String endpoint, String model) {
    final normalized = endpoint.replaceFirst(RegExp(r'/+$'), '');
    if (normalized.endsWith(':generateContent')) return normalized;
    if (normalized.endsWith('/v1beta')) {
      return '$normalized/models/$model:generateContent';
    }
    return '$normalized/v1beta/models/$model:generateContent';
  }

  String _extractImageBase64(Map<String, dynamic> json) {
    final candidates = json['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('No candidates in response');
    }
    final candidate = candidates.first;
    if (candidate is! Map) throw Exception('Invalid candidate response');
    final content = candidate['content'];
    if (content is! Map) throw Exception('No content in response');
    final parts = content['parts'] as List?;
    if (parts == null) throw Exception('No parts in response');
    for (final part in parts) {
      if (part is! Map) continue;
      final inlineData = part['inlineData'] ?? part['inline_data'];
      if (inlineData is! Map) continue;
      final data = inlineData['data']?.toString();
      if (data != null && data.isNotEmpty) return data;
    }
    throw Exception('No image found in Gemini response');
  }

  String _mimeFromImage(String image) {
    if (image.startsWith('data:image/')) {
      final end = image.indexOf(';');
      if (end > 5) return image.substring(5, end);
    }
    if (image.startsWith('/9j/')) return 'image/jpeg';
    if (image.startsWith('UklGR')) return 'image/webp';
    if (image.startsWith('R0lGOD')) return 'image/gif';
    return 'image/png';
  }
}
