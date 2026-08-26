/// Provider-neutral Glaze messages prepared for Codex App Server.
class CodexPreparedConversation {
  const CodexPreparedConversation({
    required this.injectedItems,
    required this.turnInput,
    this.assistantPrefill = '',
  });

  final List<Map<String, dynamic>> injectedItems;
  final List<Map<String, dynamic>> turnInput;

  /// A trailing assistant prefix already rendered by Glaze. App Server is
  /// asked for its continuation; completion returns prefix + continuation,
  /// while streaming callbacks contain only the new continuation.
  final String assistantPrefill;
}

class CodexPromptAdapter {
  CodexPromptAdapter._();

  static CodexPreparedConversation prepare(
    List<Map<String, dynamic>> messages,
  ) {
    if (messages.isEmpty) {
      return const CodexPreparedConversation(
        injectedItems: [],
        turnInput: [
          {
            'type': 'text',
            'text': 'Write the next assistant message.',
            'text_elements': <Object>[],
          },
        ],
      );
    }

    final last = messages.last;
    final lastRole = _normalizedRole(last['role']);
    if (lastRole == 'user') {
      return CodexPreparedConversation(
        injectedItems: messages
            .take(messages.length - 1)
            .map(_responseItem)
            .toList(growable: false),
        turnInput: _turnInput(last['content']),
      );
    }

    final injected = messages.map(_responseItem).toList(growable: false);
    if (lastRole == 'assistant') {
      return CodexPreparedConversation(
        injectedItems: injected,
        turnInput: const [
          {
            'type': 'text',
            'text':
                'Continue the final assistant message from its exact '
                'supplied prefix. Return only the continuation and do not '
                'repeat the prefix.',
            'text_elements': <Object>[],
          },
        ],
        assistantPrefill: _textContent(last['content']),
      );
    }

    return CodexPreparedConversation(
      injectedItems: injected,
      turnInput: const [
        {
          'type': 'text',
          'text':
              'Continue the supplied conversation with the next assistant '
              'message. Return only that message.',
          'text_elements': <Object>[],
        },
      ],
    );
  }

  static Map<String, dynamic> _responseItem(Map<String, dynamic> message) {
    final role = _normalizedRole(message['role']);
    final responseRole = switch (role) {
      'assistant' => 'assistant',
      'system' || 'developer' => 'developer',
      _ => 'user',
    };
    final assistant = responseRole == 'assistant';
    return <String, dynamic>{
      'type': 'message',
      'role': responseRole,
      'content': _responseContent(message['content'], assistant: assistant),
    };
  }

  static List<Map<String, dynamic>> _responseContent(
    Object? content, {
    required bool assistant,
  }) {
    final parts = _contentParts(content);
    final converted = <Map<String, dynamic>>[];
    for (final part in parts) {
      final text = part.text;
      if (text != null) {
        converted.add(<String, dynamic>{
          'type': assistant ? 'output_text' : 'input_text',
          'text': text,
        });
      }
      final imageUrl = part.imageUrl;
      if (imageUrl != null) {
        if (assistant) {
          converted.add(<String, dynamic>{
            'type': 'output_text',
            'text': _safeImageUrl(imageUrl) == null
                ? '[Image attachment omitted: unsupported source]'
                : '[Image: $imageUrl]',
          });
        } else {
          final safeImageUrl = _safeImageUrl(imageUrl);
          converted.add(
            safeImageUrl == null
                ? <String, dynamic>{
                    'type': 'input_text',
                    'text': '[Image attachment omitted: unsupported source]',
                  }
                : <String, dynamic>{
                    'type': 'input_image',
                    'image_url': safeImageUrl,
                  },
          );
        }
      }
    }
    if (converted.isEmpty) {
      converted.add(<String, dynamic>{
        'type': assistant ? 'output_text' : 'input_text',
        'text': '',
      });
    }
    return converted;
  }

  static List<Map<String, dynamic>> _turnInput(Object? content) {
    final converted = <Map<String, dynamic>>[];
    for (final part in _contentParts(content)) {
      final text = part.text;
      if (text != null) {
        converted.add(<String, dynamic>{
          'type': 'text',
          'text': text,
          'text_elements': <Object>[],
        });
      }
      final imageUrl = part.imageUrl;
      if (imageUrl != null) {
        final safeImageUrl = _safeImageUrl(imageUrl);
        converted.add(
          safeImageUrl == null
              ? <String, dynamic>{
                  'type': 'text',
                  'text': '[Image attachment omitted: unsupported source]',
                  'text_elements': <Object>[],
                }
              : <String, dynamic>{'type': 'image', 'url': safeImageUrl},
        );
      }
    }
    if (converted.isEmpty) {
      converted.add(<String, dynamic>{
        'type': 'text',
        'text': '',
        'text_elements': <Object>[],
      });
    }
    return converted;
  }

  static List<_CodexContentPart> _contentParts(Object? content) {
    if (content is String) return [_CodexContentPart(text: content)];
    if (content is! List) {
      return [_CodexContentPart(text: content?.toString() ?? '')];
    }

    final parts = <_CodexContentPart>[];
    for (final rawPart in content) {
      if (rawPart is String) {
        parts.add(_CodexContentPart(text: rawPart));
        continue;
      }
      if (rawPart is! Map) continue;
      final part = Map<String, dynamic>.from(rawPart);
      final type = part['type']?.toString();
      if (type == 'image_url' || type == 'image') {
        final rawImage = part['image_url'] ?? part['url'];
        final url = rawImage is Map ? rawImage['url'] : rawImage;
        if (url is String && url.isNotEmpty) {
          parts.add(_CodexContentPart(imageUrl: url));
        }
        continue;
      }
      final text = part['text'];
      if (text is String) parts.add(_CodexContentPart(text: text));
    }
    return parts;
  }

  static String _textContent(Object? content) => _contentParts(
    content,
  ).map((part) => part.text ?? '').where((text) => text.isNotEmpty).join();

  /// App Server's `localImage` input reads a host path before model inference,
  /// which is outside this transport's no-file-operation boundary. Codex 0.147
  /// also rejects remote image URLs, so only validated inline image data is
  /// accepted here.
  static String? _safeImageUrl(String value) {
    try {
      final data = Uri.parse(value).data;
      if (data == null ||
          !data.mimeType.toLowerCase().startsWith('image/') ||
          data.contentAsBytes().isEmpty) {
        return null;
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  static String _normalizedRole(Object? role) =>
      role?.toString().trim().toLowerCase() ?? 'user';
}

class _CodexContentPart {
  const _CodexContentPart({this.text, this.imageUrl});

  final String? text;
  final String? imageUrl;
}
