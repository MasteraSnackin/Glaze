import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/debug/perf_debug.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../bridge/chat_bridge_controller.dart';
import '../bridge/chat_bridge_registry.dart';
import '../bridge/chat_webview_bridge_host.dart';
import '../bridge/chat_webview_environment.dart';
import '../bridge/chat_webview_keep_alive.dart';
import '../bridge/chat_webview_settings.dart';
import '../../settings/app_settings_provider.dart';
import 'chat_webview_callbacks.dart';
import 'chat_webview_ext_block_callbacks.dart';
import 'chat_webview_trackpad_scroll.dart';
import 'message_scripts_prompt_sheet.dart';
import 'webview_callbacks.dart';

/// `InAppWebView` widget with the chat-specific settings, the
/// `onWebViewCreated` bridge-wiring sequence, the `onLoadStop`
/// init kick, and bridge callback wiring.
///
/// Extracted from `chat_webview_widget.dart` so the widget's
/// `build` method does not have to inline the ~120 lines of
/// `InAppWebViewSettings` + `onWebViewCreated` callback wiring.
/// The widget still owns lifecycle: the surface is given hooks
/// (`onBridgeReady`, `onInitWebView`) and the
/// [ChatWebViewBridgeHost] via constructor injection.
///
/// The surface is a thin widget — it does not own any state and
/// rebuilds when its parent does.
class ChatWebViewSurface extends ConsumerWidget {
  const ChatWebViewSurface({
    super.key,
    required this.bridgeHost,
    required this.charId,
    required this.sessionId,
    required this.messageActions,
    required this.editActions,
    required this.imageGenActions,
    required this.scrollActions,
    required this.miscActions,
    required this.isCurrentSession,
    required this.lifecycleEpoch,
    required this.isActive,
    required this.sessionSwitching,
    required this.refreshPanel,
    required this.bgImageBytes,
    required this.bgBlur,
    required this.bgDim,
    required this.chatBgMode,
    required this.chatBgColor,
    required this.chatBgAvatarPath,
    required this.bottomInset,
    required this.onBridgeReady,
    required this.onInitWebView,
  });

  final ChatWebViewBridgeHost bridgeHost;
  final String charId;
  final String? sessionId;
  final MessageActionsCallbacks messageActions;
  final EditActionsCallbacks editActions;
  final ImageGenCallbacks imageGenActions;
  final ScrollCallbacks scrollActions;
  final MiscCallbacks miscActions;

  /// Prevents an async `onWebViewCreated` continuation from installing
  /// callbacks captured for a session that has already been replaced.
  final bool Function(String? sessionId) isCurrentSession;
  final int lifecycleEpoch;
  final bool Function(int epoch) isActive;
  final bool sessionSwitching;
  final Future<void> Function(String sessionId, String messageId) refreshPanel;
  final Uint8List? bgImageBytes;
  final double bgBlur;
  final double bgDim;

  /// Chat-area background source: 'inherit' | 'color' | 'avatar' | 'custom'.
  /// For 'inherit' and 'custom', [bgImageBytes] already carries the right
  /// decoded image (global or chat-custom); 'color' uses [chatBgColor];
  /// 'avatar' loads [chatBgAvatarPath] from disk.
  final String chatBgMode;
  final Color? chatBgColor;
  final String? chatBgAvatarPath;
  final double bottomInset;

  /// Called by the surface after the bridge is created and
  /// registered in [chatBridgeRegistryProvider]. The parent widget
  /// assigns the bridge to its own `_bridge` field.
  final void Function(ChatBridgeController bridge) onBridgeReady;

  /// Called by the surface when the WebView reports it is alive
  /// (`onWebViewCreated`) or when `onLoadStop` fires and the bridge
  /// has not run init yet.
  final Future<void> Function() onInitWebView;

  /// The chat's own background — surface color, optional bg image, and dim.
  /// Rendered both *behind* the transparent WebView (so there's no white flash
  /// and `backdrop-filter` has something to sample) and, during a session
  /// switch, *over* the WebView as an opaque cover so the kept-alive native
  /// surface can't flash the previous session's content while the new one is
  /// being pushed in.
  Widget _background(BuildContext context) {
    // In 'color' mode the base layer is the chosen solid color; otherwise the
    // theme surface shows behind/around any image.
    final Color base = chatBgMode == 'color' && chatBgColor != null
        ? chatBgColor!
        : Theme.of(context).colorScheme.surface;

    // The image layer: 'avatar' loads from a file path, 'inherit'/'custom'
    // use the pre-decoded [bgImageBytes]. 'color' has no image layer.
    Widget? image;
    if (chatBgMode == 'avatar') {
      final path = chatBgAvatarPath;
      if (path != null && path.isNotEmpty) {
        image = Image.file(
          File(path),
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
      }
    } else if (chatBgMode != 'color' && bgImageBytes != null) {
      // Decoded bytes (same as GlazeBackground) because the data is a base64
      // data URI, not a file path.
      image = Image.memory(
        bgImageBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: base),
        if (image != null) ...[
          if (bgBlur > 0)
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: bgBlur,
                sigmaY: bgBlur,
                tileMode: TileMode.clamp,
              ),
              child: image,
            )
          else
            image,
          // Darkening only — the image itself stays opaque so the theme
          // surface under it never bleeds through.
          if (bgDim > 0)
            Container(color: Colors.black.withValues(alpha: bgDim)),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final webViewEnvironment = chatWebViewEnvironment;
    ref.listen<AsyncValue<AppSettings>>(appSettingsProvider, (previous, next) {
      final oldValue = previous?.value?.allowMessageScripts ?? false;
      final newValue = next.value?.allowMessageScripts ?? false;
      if (oldValue == newValue) return;
      ref
          .read(chatBridgeRegistryProvider(charId))
          ?.evalJs('window.bridge?.setAllowMessageScripts($newValue)');
    });
    return Stack(
      children: [
        // Background behind the transparent WebView.
        Positioned.fill(child: _background(context)),
        // NOTE: the glass overlays (header, input pill, buttons) are NOT
        // blurred here on the Flutter side. Their blur is reproduced entirely
        // by CSS `backdrop-filter` strips *inside* the WebView (mirrored via
        // setOverlayBlurRegions), which sample the WebView's own background
        // copy (#bg-layer, with baked bg-blur + dim + noise) AND the messages
        // in a single pass — the one source of truth for anything blurred.
        // This removes the old Flutter BackdropFilter "sandwich" that could
        // not reconcile with the in-WebView bg blur/dim and re-blurred every
        // keyboard frame.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: sessionSwitching,
            // Windows touchpad panning never reaches WebView2 on its own —
            // see ChatWebViewTrackpadScroll. Sits inside the IgnorePointer so
            // a session switch freezes it along with the rest of the input.
            child: ChatWebViewTrackpadScroll(
              charId: charId,
              child: InAppWebView(
                webViewEnvironment: webViewEnvironment,
                keepAlive: chatWebViewKeepAliveForPlatform(),
                initialFile: chatWebViewInitialFile(),
                initialUrlRequest: chatWebViewInitialUrlRequest(),
                initialSettings: chatWebViewInAppSettings(),
                onWebViewCreated: (controller) async {
                  final epoch = lifecycleEpoch;
                  bool callbackIsActive() =>
                      isActive(epoch) && isCurrentSession(sessionId);
                  if (!callbackIsActive()) return;
                  PerfDebug.chatWebViewSurfaceCreated();
                  final jsBridgeService = await bridgeHost
                      .buildJsBridgeService();
                  if (!callbackIsActive() || jsBridgeService == null) return;
                  final bridge = ChatBridgeController(
                    controller,
                    jsBridgeService,
                  );
                  if (!callbackIsActive()) return;
                  final allowMessageScripts =
                      ref
                          .read(appSettingsProvider)
                          .value
                          ?.allowMessageScripts ??
                      false;
                  await bridge.evalJs(
                    'window.bridge?.setAllowMessageScripts('
                    '$allowMessageScripts)',
                  );
                  if (!callbackIsActive()) return;
                  onBridgeReady(bridge);
                  PerfDebug.chatWebViewBridgeReady();

                  // Do not call clearAll() here — it races with _initWebViewOnce
                  // (shows #loading-screen via JS) and broke UseVirtualScroll on
                  // keep-alive re-attach. Initializer.setMessages resets the DOM.

                  final callbacks = ChatWebViewCallbacks(
                    ref: ref,
                    charId: charId,
                    messageActions: messageActions,
                    editActions: editActions,
                    imageGenActions: imageGenActions,
                    scrollActions: scrollActions,
                    miscActions: miscActions,
                  );
                  bridge.onMessageContext = callbacks.onMessageContext;
                  bridge.onSwipe = callbacks.onSwipe;
                  bridge.onChangeGreeting = callbacks.onChangeGreeting;
                  bridge.onHeaderScroll = callbacks.onHeaderScroll;
                  bridge.onScrollToBottomVisibility =
                      callbacks.onScrollToBottomVisibility;
                  bridge.onRegenerate = callbacks.onRegenerate;
                  bridge.onSelectionAction = callbacks.onSelectionAction;
                  bridge.onSelectionChange = callbacks.onSelectionChange;
                  bridge.onEditSave = callbacks.onEditSave;
                  bridge.onEditCancel = callbacks.onEditCancel;
                  bridge.onEditFocusChange = callbacks.onEditFocusChange;
                  bridge.onImageClick = callbacks.onImageClick;
                  bridge.onImgDownload = callbacks.onImgDownload;
                  bridge.onGuidedSwipe = callbacks.onGuidedSwipe;
                  bridge.onMemoryClick = callbacks.onMemoryClick;
                  bridge.onToggleHidden = callbacks.onToggleHidden;
                  bridge.onToggleImageHidden = callbacks.onToggleImageHidden;
                  bridge.onInjectClick = callbacks.onInjectClick;
                  bridge.onImgRetry = callbacks.onImgRetry;
                  bridge.onImgEnableRetry = callbacks.onImgEnableRetry;
                  bridge.onImgFind = callbacks.onImgFind;
                  bridge.onImgRegen = callbacks.onImgRegen;
                  bridge.onImgOptions = callbacks.onImgOptions;
                  bridge.onImgCancel = callbacks.onImgCancel;
                  bridge.onStop = callbacks.onStop;
                  bridge.onLinkClick = callbacks.onLinkClick;
                  bridge.onLoadMore = callbacks.onLoadMore;
                  bridge.onMessageScriptBlocked = () {
                    if (!callbackIsActive()) return;
                    // ignore: use_build_context_synchronously
                    unawaited(maybeShowMessageScriptsPrompt(context, ref));
                  };
                  if (!callbackIsActive()) return;

                  // The ext-block callbacks run after `await` paths. The
                  // controller is created once per WebView lifetime so
                  // the context capture is safe.
                  final extBlocks = ChatWebViewExtBlockCallbacks(
                    ref: ref,
                    charId: charId,
                    sessionId: sessionId,
                    // ignore: use_build_context_synchronously
                    context: context,
                    isMounted: callbackIsActive,
                    refreshPanel: refreshPanel,
                  );
                  bridge.onExtBlocksRunAll = extBlocks.onRunAll();
                  bridge.onExtBlockStop = extBlocks.onStop();
                  bridge.onExtBlockRegen = extBlocks.onRegen();
                  bridge.onExtBlockRegenImage = extBlocks.onRegenImage();
                  bridge.onExtBlockEdit = extBlocks.onEdit();
                  bridge.onExtBlockDelete = extBlocks.onDelete();

                  final isAlive = await controller.isLoading() == false;
                  if (!callbackIsActive()) return;
                  if (isAlive) {
                    await onInitWebView();
                    if (!callbackIsActive()) return;
                  }
                },
                onLoadStop: (controller, url) async {
                  final epoch = lifecycleEpoch;
                  bool callbackIsActive() =>
                      isActive(epoch) && isCurrentSession(sessionId);
                  if (!callbackIsActive()) return;
                  PerfDebug.chatWebViewLoadStopped();
                  // The init path is also wired through onWebViewCreated. When
                  // load stop wins the race, run init here.
                  await ref
                      .read(chatBridgeRegistryProvider(charId))
                      ?.evalJs(
                        'window.bridge?.setAllowMessageScripts('
                        '${ref.read(appSettingsProvider).value?.allowMessageScripts ?? false})',
                      );
                  if (!callbackIsActive()) return;
                  await onInitWebView();
                  if (!callbackIsActive()) return;
                },
                shouldOverrideUrlLoading: (controller, request) async {
                  return chatWebViewNavigationPolicy(request.request.url);
                },
              ),
            ),
          ),
        ),
        // Opaque cover over the WebView while a new session is being pushed in.
        // Hides the kept-alive native surface's previous-session content (which
        // it composites for a frame on re-attach) behind the chat's own
        // background, so switching shows an empty chat rather than a stale flash.
        if (sessionSwitching)
          Positioned.fill(child: IgnorePointer(child: _background(context))),
        if (sessionSwitching) const Center(child: GlazeSpinner()),
        if (bottomInset > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.02),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
