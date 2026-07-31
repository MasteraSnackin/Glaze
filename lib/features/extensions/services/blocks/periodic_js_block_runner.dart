import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../core/services/generation_notification_service.dart';
import '../../../chat/bridge/chat_bridge_registry.dart';
import '../../models/block_config.dart';
import '../js_engine_service.dart';
import 'js_block_executor.dart';

class PeriodicJsBlockRunner {
  const PeriodicJsBlockRunner({required this.ref});

  final Ref ref;

  Future<String?> run({
    required String charId,
    required String sessionId,
    required BlockConfig block,
    required List<ChatMessage> contextMessages,
    bool Function()? isAuthorized,
  }) async {
    if (!(isAuthorized?.call() ?? true)) return null;
    if (block.type != BlockType.jsRunner) {
      throw ArgumentError(
        'runJsBlock only supports BlockType.jsRunner (got ${block.type.name})',
      );
    }
    final script = block.prompt.isNotEmpty ? block.prompt : block.script;
    if (script.isEmpty) {
      return null;
    }
    final engine = JsEngineService.instance;
    final bridge = ref.read(chatBridgeRegistryProvider(charId));
    if (!engine.isReady && bridge == null) {
      debugPrint(
        '[ExtPostGen] runJsBlock: no engine or bridge (block "${block.name}")',
      );
      return null;
    }
    final cancelToken = CancelToken();
    final authoritySub = GenerationNotificationService.instance
        .activeChatContextChanges
        .listen((_) {
          if (!(isAuthorized?.call() ?? true) && !cancelToken.isCancelled) {
            cancelToken.cancel('Periodic chat authority changed');
          }
        });
    try {
      if (cancelToken.isCancelled || !(isAuthorized?.call() ?? true)) {
        return null;
      }
      if (engine.isReady) {
        try {
          final contextMap = JsBlockExecutor.jsContextMap(
            messages: contextMessages
                .map((m) => {'role': m.role, 'text': m.content})
                .toList(),
            character: null, // no character payload for periodic
            sessionId: sessionId,
            previousOutput: null,
          );
          final patchedContext = Map<String, dynamic>.from(contextMap)
            ..['characterId'] = charId
            ..['sessionId'] = sessionId;
          final result = await engine.runScript(
            script: script,
            context: patchedContext,
            host: bridge == null
                ? null
                : JsEngineBridgeHost(
                    bridge: bridge.extensionBridgeService,
                    currentCharIdProvider: () => charId,
                  ),
            cancelToken: cancelToken,
          );
          return !cancelToken.isCancelled && (isAuthorized?.call() ?? true)
              ? result
              : null;
        } on HeadlessUnavailableError catch (_) {
          // Fall through to visual bridge.
        }
      }
      final visualBridge = bridge;
      if (visualBridge == null) {
        return null;
      }
      if (cancelToken.isCancelled || !(isAuthorized?.call() ?? true)) return null;
      final result = await visualBridge.runJsBlock(
        script: script,
        messages: contextMessages,
        character: null,
        sessionId: sessionId,
        previousOutput: null,
        contextMessageCount: -1,
        cancelToken: cancelToken,
      );
      return !cancelToken.isCancelled && (isAuthorized?.call() ?? true)
          ? result
          : null;
    } catch (e) {
      debugPrint('[ExtPostGen] runJsBlock failed: $e');
      return null;
    } finally {
      unawaited(authoritySub.cancel());
    }
  }
}
