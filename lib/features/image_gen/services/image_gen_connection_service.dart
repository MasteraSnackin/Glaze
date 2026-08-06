import 'package:dio/dio.dart';

import '../image_gen_models.dart';

/// Lightweight connectivity and model-discovery requests for the image-gen
/// settings sheet. Generation itself remains in the provider-specific clients.
class ImageGenConnectionService {
  final Dio _dio;

  ImageGenConnectionService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ),
          );

  Future<void> checkConnection({
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
  }) async {
    switch (settings.apiType) {
      case ImageGenApiType.openai:
        final connection = _openAiConnection(
          settings: settings,
          llmEndpoint: llmEndpoint,
          llmApiKey: llmApiKey,
        );
        await _get(_openAiModelsUrl(connection.endpoint), connection.apiKey);
      case ImageGenApiType.gemini:
        final connection = _openAiConnection(
          settings: settings,
          llmEndpoint: llmEndpoint,
          llmApiKey: llmApiKey,
        );
        await _get(_geminiModelsUrl(connection.endpoint), connection.apiKey);
      case ImageGenApiType.naistera:
        if (settings.naisteraApiKey.trim().isEmpty) {
          throw StateError('Naistera API key not configured');
        }
        await _get('https://naistera.org', null);
      case ImageGenApiType.routmy:
        if (settings.routmyApiKey.trim().isEmpty) {
          throw StateError('rout.my API key not configured');
        }
        await _get(
          '${RoutMyConstants.baseUrl}/v1/models',
          settings.routmyApiKey,
        );
      case ImageGenApiType.ruRoutmy:
        if (settings.ruRoutmyApiKey.trim().isEmpty) {
          throw StateError('RU-rout.my API key not configured');
        }
        await _get(
          '${RuRoutMyConstants.baseUrl}/v1/models',
          settings.ruRoutmyApiKey,
        );
    }
  }

  Future<List<String>> fetchOpenAiModels({
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
  }) async {
    final connection = _openAiConnection(
      settings: settings,
      llmEndpoint: llmEndpoint,
      llmApiKey: llmApiKey,
    );
    final data = await _get(
      _openAiModelsUrl(connection.endpoint),
      connection.apiKey,
    );
    final models = data is Map ? data['data'] : null;
    if (models is! List) return const [];

    const imageKeywords = [
      'dall-e',
      'midjourney',
      'stable-diffusion',
      'sdxl',
      'flux',
      'imagen',
      'image',
      'seedream',
      'hidream',
      'ideogram',
      'gpt-image',
      'wanx',
      'qwen',
      'drawing',
    ];
    const videoKeywords = [
      'sora',
      'kling',
      'veo',
      'pika',
      'runway',
      'luma',
      'video',
      'cogvideo',
    ];

    return models
        .whereType<Map<Object?, Object?>>()
        .map((model) => model['id']?.toString() ?? '')
        .where((id) {
          final lower = id.toLowerCase();
          return id.isNotEmpty &&
              !videoKeywords.any(lower.contains) &&
              imageKeywords.any(lower.contains);
        })
        .toList();
  }

  ({String endpoint, String apiKey}) _openAiConnection({
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
  }) {
    final endpoint =
        (settings.useSameEndpoint ? llmEndpoint : settings.customEndpoint)
            .trim();
    final apiKey =
        (settings.useSameEndpoint ? llmApiKey : settings.customApiKey).trim();
    if (endpoint.isEmpty) throw StateError('Image endpoint not configured');
    if (apiKey.isEmpty) throw StateError('Image API key not configured');
    return (endpoint: endpoint, apiKey: apiKey);
  }

  Future<dynamic> _get(String url, String? apiKey) async {
    final response = await _dio.get<dynamic>(
      url,
      options: Options(
        headers: {
          if (apiKey != null && apiKey.isNotEmpty)
            'Authorization': 'Bearer $apiKey',
        },
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw StateError('HTTP $status');
    }
    return response.data;
  }

  static String _openAiModelsUrl(String endpoint) {
    final normalized = endpoint.replaceFirst(RegExp(r'/+$'), '');
    if (normalized.endsWith('/v1/models')) return normalized;
    if (normalized.endsWith('/v1/images/generations')) {
      return normalized.replaceFirst(
        RegExp(r'/images/generations$'),
        '/models',
      );
    }
    if (normalized.endsWith('/v1')) return '$normalized/models';
    return '$normalized/v1/models';
  }

  static String _geminiModelsUrl(String endpoint) {
    final normalized = endpoint.replaceFirst(RegExp(r'/+$'), '');
    if (normalized.endsWith('/v1beta/models')) return normalized;
    if (normalized.endsWith('/v1beta')) return '$normalized/models';
    return '$normalized/v1beta/models';
  }

  void dispose() => _dio.close();
}
