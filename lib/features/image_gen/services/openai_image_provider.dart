import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'image_gen_http.dart';

class OpenaiImageProvider {
  final ImageGenHttp _http = ImageGenHttp();

  Future<Uint8List> generate({
    required String endpoint,
    required String apiKey,
    required String model,
    required String prompt,
    required String size,
    required String quality,
    CancelToken? cancelToken,
  }) async {
    String url = endpoint;
    if (!url.contains('/v1') && !url.contains('/images')) {
      url = '$url/v1/images/generations';
    } else if (!url.contains('/images/generations')) {
      url = '$url/images/generations';
    }

    return _http.postAndExtract(
      url: url,
      apiKey: apiKey,
      body: {
        'model': model,
        'prompt': prompt,
        'n': 1,
        'size': size,
        'quality': quality,
        'response_format': 'b64_json',
      },
      cancelToken: cancelToken,
      extract: (json) async {
        final data = json['data'] as List?;
        if (data == null || data.isEmpty) {
          throw Exception('No image data in response');
        }
        for (final item in data) {
          if (item is! Map) continue;
          final imageObj = Map<String, dynamic>.from(item);
          final b64 = imageObj['b64_json'] as String?;
          if (b64 != null && b64.isNotEmpty) {
            return ImageGenHttp.base64ToBytes(
              ImageGenHttp.stripBase64Prefix(b64),
            );
          }
          final imgUrl = imageObj['url'] as String?;
          if (imgUrl != null && imgUrl.isNotEmpty) {
            return await ImageGenHttp.downloadImage(
              imgUrl,
              cancelToken: cancelToken,
            );
          }
        }
        throw Exception('No b64_json or url in image response');
      },
    );
  }
}
