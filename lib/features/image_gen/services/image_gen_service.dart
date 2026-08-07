import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/services/image_storage_service.dart';
import '../image_gen_models.dart';
import 'image_gen_dispatcher.dart';
import 'image_prompt_builder.dart';
import 'image_reference_collector.dart';
import 'image_tag_markup.dart';

/// Turns `[IMG:GEN]` tags in a message into generated images.
///
/// Prompt assembly (style block, reference descriptions, critical reference
/// instruction) lives in [image_prompt_builder], reference collection in
/// [ImageReferenceCollector] and the provider calls in [ImageGenDispatcher].
class ImageGenService {
  ImageGenService(this._imageStorage);

  final ImageStorageService _imageStorage;
  final ImageReferenceCollector _references = const ImageReferenceCollector();
  final ImageGenDispatcher _dispatcher = const ImageGenDispatcher();

  Future<String> processMessageImages({
    required String text,
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    CancelToken? cancelToken,
    void Function(String updatedText)? onUpdate,
    void Function(String error)? onError,
  }) async {
    if (!settings.enabled) {
      final disabledText = ImageTagMarkup.replaceAllImageGenTagsWithDisabled(
        text,
      );
      if (disabledText != text) onUpdate?.call(disabledText);
      return disabledText;
    }

    final instructions = ImageTagMarkup.extractImageGenInstructions(text);
    if (instructions.isEmpty) return text;

    String currentText = text;

    for (int i = 0; i < instructions.length; i++) {
      if (cancelToken?.isCancelled == true) break;

      final instruction = instructions[i];
      final rawPrompt = instruction['prompt'] as String? ?? '';

      if (rawPrompt.isEmpty) {
        currentText = ImageTagMarkup.replaceTagWithError(
          currentText,
          0,
          'Image prompt is empty',
        );
        onUpdate?.call(currentText);
        onError?.call('Image prompt is empty');
        continue;
      }

      final prompt = rawPrompt.replaceFirst(RegExp(r'^SCENE_PROMPT:\s*'), '');

      try {
        final imageBytes = await generateImage(
          settings: settings,
          prompt: prompt,
          tagStyle: instruction['style'] as String?,
          llmEndpoint: llmEndpoint,
          llmApiKey: llmApiKey,
          llmModel: llmModel,
          character: character,
          persona: persona,
          recentImageContexts: recentImageContexts,
          instructionAspectRatio: instruction['aspect_ratio'] as String?,
          instructionImageSize: instruction['image_size'] as String?,
          cancelToken: cancelToken,
        );
        if (cancelToken?.isCancelled == true) break;

        final filename = 'imggen_${DateTime.now().microsecondsSinceEpoch}.png';
        final savedPath = await _saveGeneratedImage(filename, imageBytes);
        if (cancelToken?.isCancelled == true) break;

        currentText = ImageTagMarkup.replaceTagWithResult(
          currentText,
          0,
          savedPath,
        );
        onUpdate?.call(currentText);
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) break;
        final errorMsg = _formatError(e);
        currentText = ImageTagMarkup.replaceTagWithError(
          currentText,
          0,
          errorMsg,
        );
        onUpdate?.call(currentText);
        onError?.call(errorMsg);
      } catch (e) {
        final errorMsg = _formatErrorString(e.toString());
        currentText = ImageTagMarkup.replaceTagWithError(
          currentText,
          0,
          errorMsg,
        );
        onUpdate?.call(currentText);
        onError?.call(errorMsg);
      }
    }

    return currentText;
  }

  /// Generates a single image for [prompt].
  ///
  /// [tagStyle] is the `style` field of the image tag; the active style from
  /// the style library overrides it, and with "no style" selected it is used
  /// as written.
  Future<Uint8List> generateImage({
    required ImageGenSettings settings,
    required String prompt,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    String? tagStyle,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  }) async {
    final references = await _references.collect(
      settings: settings,
      prompt: prompt,
      character: character,
      persona: persona,
      recentImageContexts: recentImageContexts,
    );

    var finalPrompt = buildFinalGenerationPrompt(
      prompt: prompt,
      tagStyle: tagStyle,
      settings: settings,
      references: references,
    );
    finalPrompt = withReferenceInstruction(
      finalPrompt,
      settings,
      hasReferences: references.isNotEmpty,
    );

    return _dispatcher.generate(
      settings: settings,
      prompt: finalPrompt,
      references: references,
      llmEndpoint: llmEndpoint,
      llmApiKey: llmApiKey,
      instructionAspectRatio: instructionAspectRatio,
      instructionImageSize: instructionImageSize,
      cancelToken: cancelToken,
    );
  }

  String _formatError(DioException e) {
    final data = e.response?.data;
    String? responseMessage;
    if (data is Map) {
      final error = data['error'];
      if (error is Map) {
        responseMessage = error['message']?.toString();
      } else if (error != null) {
        responseMessage = error.toString();
      }
      responseMessage ??= data['message']?.toString();
      responseMessage ??= data['detail']?.toString();
    } else if (data != null) {
      responseMessage = data.toString();
    }
    final status = e.response?.statusCode;
    final msg = responseMessage?.trim().isNotEmpty == true
        ? [if (status != null) 'HTTP $status', responseMessage!].join(': ')
        : status != null
        ? [
            'HTTP $status',
            if (e.response?.statusMessage?.trim().isNotEmpty == true)
              e.response!.statusMessage!.trim(),
          ].join(': ')
        : e.message ?? e.toString();
    return _formatErrorString(msg);
  }

  String _formatErrorString(String msg) {
    if (msg.length > 200) msg = '${msg.substring(0, 197)}...';
    return msg;
  }

  Future<String> _saveGeneratedImage(String filename, Uint8List bytes) async {
    final dir = Directory(p.join(_imageStorage.baseDir, 'generated'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final extension = imageExtensionForBytes(bytes);
    final path = p.join(
      dir.path,
      '${p.basenameWithoutExtension(filename)}.$extension',
    );
    await File(path).writeAsBytes(bytes);
    return path;
  }
}
