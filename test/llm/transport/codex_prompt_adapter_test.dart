import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/codex_prompt_adapter.dart';

void main() {
  group('CodexPromptAdapter', () {
    test('uses the final user message as turn input and injects history', () {
      final prepared = CodexPromptAdapter.prepare(const [
        {'role': 'system', 'content': 'Stay in character.'},
        {'role': 'user', 'content': 'Hello'},
        {'role': 'assistant', 'content': 'Hi there'},
        {'role': 'user', 'content': 'What happens next?'},
      ]);

      expect(prepared.assistantPrefill, isEmpty);
      expect(prepared.injectedItems, [
        {
          'type': 'message',
          'role': 'developer',
          'content': [
            {'type': 'input_text', 'text': 'Stay in character.'},
          ],
        },
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'Hello'},
          ],
        },
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'Hi there'},
          ],
        },
      ]);
      expect(prepared.turnInput, [
        {
          'type': 'text',
          'text': 'What happens next?',
          'text_elements': <Object>[],
        },
      ]);
    });

    test('preserves rich user text and inline images in turn input', () {
      final prepared = CodexPromptAdapter.prepare(const [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Describe this: '},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,aGVsbG8='},
            },
          ],
        },
      ]);

      expect(prepared.injectedItems, isEmpty);
      expect(prepared.turnInput, [
        {
          'type': 'text',
          'text': 'Describe this: ',
          'text_elements': <Object>[],
        },
        {'type': 'image', 'url': 'data:image/png;base64,aGVsbG8='},
      ]);
    });

    test('omits remote image URLs unsupported by the isolated App Server', () {
      final prepared = CodexPromptAdapter.prepare(const [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'https://example.test/scene.png'},
            },
          ],
        },
      ]);

      expect(prepared.turnInput, [
        {
          'type': 'text',
          'text': '[Image attachment omitted: unsupported source]',
          'text_elements': <Object>[],
        },
      ]);
    });

    test('never turns a chat image URL into a local file read', () {
      final prepared = CodexPromptAdapter.prepare(const [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'file:///private/secret.png'},
            },
          ],
        },
      ]);

      expect(prepared.turnInput, [
        {
          'type': 'text',
          'text': '[Image attachment omitted: unsupported source]',
          'text_elements': <Object>[],
        },
      ]);
      expect(prepared.turnInput.toString(), isNot(contains('secret.png')));
      expect(prepared.turnInput.toString(), isNot(contains('localImage')));
    });

    test('does not inject unsupported historical image sources', () {
      final prepared = CodexPromptAdapter.prepare(const [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'http://127.0.0.1/private.png'},
            },
          ],
        },
        {'role': 'user', 'content': 'Continue.'},
      ]);

      expect(prepared.injectedItems.single['content'], [
        {
          'type': 'input_text',
          'text': '[Image attachment omitted: unsupported source]',
        },
      ]);
      expect(prepared.injectedItems.toString(), isNot(contains('127.0.0.1')));
    });

    test('turns a trailing assistant message into an exact prefill', () {
      final prepared = CodexPromptAdapter.prepare(const [
        {'role': 'user', 'content': 'Begin the sentence.'},
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'Once upon '},
            {'type': 'text', 'text': 'a time'},
          ],
        },
      ]);

      expect(prepared.assistantPrefill, 'Once upon a time');
      expect(prepared.injectedItems.last, {
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': 'Once upon '},
          {'type': 'output_text', 'text': 'a time'},
        ],
      });
      expect(
        prepared.turnInput.single['text'],
        contains('do not repeat the prefix'),
      );
    });

    test('maps developer messages to injected developer items', () {
      final prepared = CodexPromptAdapter.prepare(const [
        {'role': 'developer', 'content': 'Use terse prose.'},
      ]);

      expect(prepared.injectedItems.single['role'], 'developer');
      expect(prepared.turnInput.single['text'], contains('next assistant'));
    });

    test('supplies a deterministic instruction for an empty conversation', () {
      final prepared = CodexPromptAdapter.prepare(const []);

      expect(prepared.injectedItems, isEmpty);
      expect(prepared.assistantPrefill, isEmpty);
      expect(prepared.turnInput, [
        {
          'type': 'text',
          'text': 'Write the next assistant message.',
          'text_elements': <Object>[],
        },
      ]);
    });

    test('represents inline assistant images as inert text in history', () {
      final prepared = CodexPromptAdapter.prepare(const [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,aGVsbG8='},
            },
          ],
        },
      ]);

      expect(prepared.injectedItems.single['content'], [
        {
          'type': 'output_text',
          'text': '[Image: data:image/png;base64,aGVsbG8=]',
        },
      ]);
    });
  });
}
