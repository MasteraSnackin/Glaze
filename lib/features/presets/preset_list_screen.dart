import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/import/silly_tavern_preset_parser.dart';
import '../../core/llm/preset_macro_attribution.dart';
import '../../core/models/preset.dart';
import '../../core/models/studio_config.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/studio_feature_provider.dart';
import '../../core/state/active_studio_preset_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/sheet_view.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import 'preset_connections_sheet.dart';
import 'preset_editor_screen.dart';
import 'preset_image.dart';
import 'preset_list_provider.dart';

class PresetListScreen extends ConsumerStatefulWidget {
  final bool startExpanded;

  /// Active chat, forwarded to the preset editor so the Author's Note block can
  /// edit the session-scoped note. Null when opened outside a chat.
  final String? charId;
  const PresetListScreen({
    super.key,
    this.startExpanded = false,
    this.charId,
  });

  @override
  ConsumerState<PresetListScreen> createState() => _PresetListScreenState();
}

class _PresetListScreenState extends ConsumerState<PresetListScreen> {
  Preset? _editingPreset;
  bool _isCreating = false;
  GlobalKey<PresetEditorBodyState> _editorKey = GlobalKey<PresetEditorBodyState>();

  bool get _inEditor => _isCreating || _editingPreset != null;

  void _openEditor(Preset? preset) {
    setState(() {
      _editingPreset = preset;
      _isCreating = preset == null;
      // Recreate the editor key so PresetEditorBody's initState fires
      // and picks up the new preset's blocks instead of the old ones.
      _editorKey = GlobalKey<PresetEditorBodyState>();
    });
  }

  void _closeEditor() {
    setState(() {
      _editingPreset = null;
      _isCreating = false;
    });
  }

  void _handleBack() {
    if (_inEditor) {
      final handled = _editorKey.currentState?.handleBack() ?? false;
      if (!handled) {
        _closeEditor();
      }
    } else {
      if (widget.startExpanded) {
        context.go('/tools');
      } else {
        Navigator.of(context).maybePop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final presets = ref.watch(presetListProvider);
    final activeId = ref.watch(activePresetIdProvider);
    final studioPresets = ref.watch(studioPresetListProvider);
    final activeStudioId = ref.watch(activeStudioPresetProvider).value ?? 'default';

    return SheetView(
      startExpanded: widget.startExpanded,
      showRouteBackground: false,
      title: _inEditor
          ? (_editingPreset != null ? 'Edit Preset' : 'New Preset')
          : 'Presets',
      showBack: true,
      onBack: _handleBack,
      body: _inEditor
          ? PresetEditorBody(
              key: _editorKey,
              preset: _editingPreset,
              charId: widget.charId,
              onDeleted: _closeEditor,
            )
          : presets.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
              data: (list) => _buildBody(
                context, ref, list, activeId,
                studioPresets.value ?? [], activeStudioId,
              ),
            ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    List<Preset> list,
    String? activeId,
    List<StudioPreset> studioList,
    String activeStudioId,
  ) {
    final items = <_PresetItem>[
      for (final p in list) _PresetItem(preset: p),
      for (final sp in studioList) _PresetItem(studioPreset: sp),
    ];
    return Builder(
      builder: (context) => ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          16,
          12,
          16,
          16,
        ).add(EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top,
          bottom: MediaQuery.paddingOf(context).bottom,
        )),
        itemCount: items.length + 1,
        itemBuilder: (_, i) {
          if (i == items.length) return _buildAddButton(context, ref);
          final item = items[i];
          final isActive = item.isAgentic
              ? item.studioPreset!.id == activeStudioId
              : activeId == item.preset!.id;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PsCard(
              item: item,
              isActive: isActive,
              onActivate: () {
                if (!isActive) {
                  if (item.isAgentic) {
                    ref.read(activeStudioPresetProvider.notifier)
                        .set(item.studioPreset!.id);
                    ref.read(studioFeatureEnabledProvider.notifier).enable();
                  } else {
                    setActivePreset(ref, item.preset!.id);
                  }
                }
              },
              onConnections: item.isAgentic
                  ? null
                  : () => showPresetConnections(context, item.preset!.id),
              onEdit: item.isAgentic
                  ? null
                  : () => _openEditor(item.preset),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAddButton(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: context.cs.primary,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () => _showAddSheet(context, ref),
          borderRadius: BorderRadius.circular(14),
          splashColor: Colors.white.withValues(alpha: 0.1),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Text(
                  'Add / Import',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAddSheet(BuildContext context, WidgetRef ref) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Add Preset',
      items: [
        BottomSheetItem(
          icon: Icons.add_circle_outline,
          label: 'Create New Preset',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openEditor(null);
          },
        ),
        BottomSheetItem(
          icon: Icons.file_upload_outlined,
          label: 'Import from File',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _importPreset();
          },
        ),
      ],
    );
  }

  Future<void> _importPreset() async {
    final ctx = context;
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: Platform.isIOS ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isIOS ? null : ['json'],
        allowMultiple: true,
        withData: true,
      );
    } catch (_) {}
    if (!mounted) return;
    if (result == null || result.files.isEmpty) return;

    final notifier = ref.read(presetListProvider.notifier);
    final imported = <Preset>[];
    Object? lastError;
    var unreadable = 0;

    for (final picked in result.files) {
      try {
        String jsonString;
        if (picked.bytes != null && picked.bytes!.isNotEmpty) {
          jsonString = utf8.decode(picked.bytes!);
        } else if (picked.path != null && picked.path!.isNotEmpty) {
          jsonString = await File(picked.path!).readAsString();
        } else {
          unreadable++;
          continue;
        }

        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final preset = parseSillyTavernPreset(json, picked.name);
        await notifier.add(preset);
        imported.add(preset);
      } catch (e) {
        lastError = e;
      }
    }

    if (!ctx.mounted) return;

    if (imported.isEmpty) {
      if (lastError != null) {
        GlazeErrorDialog.show(ctx, lastError, prefix: 'Import failed: ');
      } else if (unreadable > 0) {
        GlazeToast.show(ctx, 'Cannot read file');
      }
      return;
    }

    if (imported.length == 1 && result.files.length == 1) {
      final preset = imported.single;
      GlazeToast.show(
        ctx,
        'Imported "${preset.name}" (${preset.blocks.length} blocks)',
      );
      return;
    }

    final failed = result.files.length - imported.length;
    GlazeToast.show(
      ctx,
      'Imported ${imported.length} presets'
      '${failed > 0 ? ' — $failed failed' : ''}',
    );
  }
}

int _presetTokenCount(Preset preset) => presetOnlyTokenCount(preset);



// ─── preset item wrapper ──────────────────────────────────────────────────────

class _PresetItem {
  final Preset? preset;
  final StudioPreset? studioPreset;
  _PresetItem({this.preset, this.studioPreset});
  bool get isAgentic => studioPreset != null;
}

// ─── ps-card ─────────────────────────────────────────────────────────────────

class _PsCard extends ConsumerWidget {
  final _PresetItem item;
  final bool isActive;
  final VoidCallback onActivate;
  final VoidCallback? onConnections;
  final VoidCallback? onEdit;

  const _PsCard({
    required this.item,
    required this.isActive,
    required this.onActivate,
    this.onConnections,
    this.onEdit,
  });

  /// Height of a card that shows a cover image. Plain cards keep their
  /// intrinsic (single-row) height.
  static const double _coverHeight = 132;

  /// Border width of the active card, and of any card carrying artwork.
  static const double _accentBorderWidth = 2;

  /// How long the active highlight takes to cross-fade when the selection
  /// moves between presets.
  static const _activeFade = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (item.isAgentic) return _buildAgenticCard(context, ref);
    final preset = item.preset!;
    final connections = ref.watch(presetConnectionsProvider);
    final hasCharBinding = connections.character.values.contains(preset.id);
    final hasChatBinding = connections.chat.values.contains(preset.id);
    final cover = presetCoverImage(preset);

    // A card filled with artwork needs a real frame even when idle — a hairline
    // disappears against the cover (same treatment as the Tools hero card).
    final idleBorder = cover != null
        ? context.cs.outlineVariant
        : context.cs.outline;
    final idleWidth = cover != null ? _accentBorderWidth : 1.0;
    final activeBorder = context.cs.primary.withValues(alpha: 0.5);
    // GlassSurface multiplies a tint's own alpha into the theme's element
    // opacity, and only falls back to `surface × elementOpacity` when no tint
    // is given. A theme whose UI colour is translucent (8-digit hex) therefore
    // renders a card handed `surfaceContainerHighest` verbatim thinner than
    // every other glass surface in the app. Pinning both tints to full alpha
    // makes the multiplication a no-op, so an idle card is exactly the app's
    // plain glass and the active one is that same glass plus the highlight.
    final baseTint = context.cs.surfaceContainerHighest.withValues(alpha: 1.0);
    final activeTint = Color.alphaBlend(
      context.cs.primary.withValues(alpha: 0.12),
      baseTint,
    );

    final content = cover == null
        ? Padding(
            padding: const EdgeInsets.all(10),
            child: _buildRow(
              context,
              hasChatBinding: hasChatBinding,
              hasCharBinding: hasCharBinding,
              onCover: false,
            ),
          )
        : _buildCover(
            context,
            cover,
            hasChatBinding: hasChatBinding,
            hasCharBinding: hasCharBinding,
          );

    // `begin` only applies on the first build, so a card that is already active
    // when the list opens starts highlighted instead of animating in; later
    // changes to `end` fade the border (and its tint) between the two states.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(
        begin: isActive ? 1.0 : 0.0,
        end: isActive ? 1.0 : 0.0,
      ),
      duration: _activeFade,
      curve: Curves.easeOut,
      child: content,
      builder: (context, t, child) => GlassSurface(
        enableRipple: true,
        tint: Color.lerp(baseTint, activeTint, t),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Color.lerp(idleBorder, activeBorder, t)!,
          width: idleWidth + (_accentBorderWidth - idleWidth) * t,
        ),
        onTap: onActivate,
        child: child!,
      ),
    );
  }

  /// Taller card: the cover fills it, a scrim keeps the text legible and the
  /// usual info row sits at the bottom.
  Widget _buildCover(
    BuildContext context,
    ImageProvider cover, {
    required bool hasChatBinding,
    required bool hasCharBinding,
  }) {
    return SizedBox(
      height: _coverHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image(
            image: cover,
            fit: BoxFit.cover,
            // A missing/corrupt file falls back to the plain glass surface
            // rather than Flutter's error box.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x33000000), Color(0xD9000000)],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildRow(
                  context,
                  hasChatBinding: hasChatBinding,
                  hasCharBinding: hasCharBinding,
                  onCover: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Shared info row. Over a cover the leading icon is dropped (the art already
  /// identifies the preset) and the text switches to light-on-dark.
  Widget _buildRow(
    BuildContext context, {
    required bool hasChatBinding,
    required bool hasCharBinding,
    required bool onCover,
  }) {
    final primaryText = onCover ? Colors.white : context.cs.onSurface;
    final secondaryText = onCover
        ? Colors.white.withValues(alpha: 0.75)
        : context.cs.onSurfaceVariant;
    final preset = item.preset!;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (!onCover) ...[
          // Circular icon
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.cs.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.description_outlined,
              size: 20,
              color: context.cs.primary,
            ),
          ),
          const SizedBox(width: 12),
        ],
        // Info
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                preset.name,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: primaryText,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _SmallBadge(
                    icon: Icons.description,
                    label: '${_presetTokenCount(preset)}',
                    foreground: secondaryText,
                    onCover: onCover,
                  ),
                  if (preset.author != null && preset.author!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'by ${preset.author}',
                        style: TextStyle(fontSize: 12, color: secondaryText),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Connection badge — tappable, colour shows binding type
        _ConnBadge(
          isActive: isActive,
          hasChatBinding: hasChatBinding,
          hasCharBinding: hasCharBinding,
          onTap: onConnections ?? () {},
        ),
        const SizedBox(width: 8),
        // Edit button
        SizedBox(
          width: 34,
          height: 34,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(8),
              child: Icon(
                Icons.edit_outlined,
                size: 18,
                color: secondaryText,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAgenticCard(BuildContext context, WidgetRef ref) {
    final sp = item.studioPreset!;
    final tokens = _estimateTokens(sp);
    final requests = _estimateRequests(sp);
    return GlassSurface(
      enableRipple: true,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: isActive
            ? context.cs.primary.withValues(alpha: 0.5)
            : context.cs.outline,
        width: isActive ? 2.0 : 1.0,
      ),
      onTap: onActivate,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Icon(Icons.smart_toy_outlined, size: 20, color: context.cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    sp.name.isNotEmpty ? sp.name : 'Agentic Preset',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${sp.blocks.length} blocks',
                    style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            _SmallBadge(icon: Icons.memory, label: tokens),
            const SizedBox(width: 6),
            _SmallBadge(icon: Icons.bolt, label: requests),
          ],
        ),
      ),
    );
  }

  static String _estimateTokens(StudioPreset sp) {
    var total = 0;
    for (final b in sp.blocks) {
      total += b.content.length ~/ 4;
    }
    if (total >= 1000) return '${total ~/ 1000}K';
    return '$total';
  }

  static String _estimateRequests(StudioPreset sp) {
    int count = 1;
    final enabled = sp.agentEnabled;
    for (final block in sp.blocks) {
      if (block.kind == 'tracker_instruction' && block.enabled) count++;
      if (block.kind == 'agent_instruction' && block.enabled) count++;
    }
    if (enabled['post_clean'] == true || (!enabled.containsKey('post_clean'))) count += 2;
    if (enabled['ledger'] == true || (!enabled.containsKey('ledger'))) count += 1;
    return '$count/ход';
  }
}

// ─── shared small widgets ─────────────────────────────────────────────────────

class _SmallBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Overrides the icon/label colour (set when the badge sits on a cover).
  final Color? foreground;

  /// Over a cover the near-transparent black pill disappears, so a light
  /// scrim is used instead.
  final bool onCover;
  const _SmallBadge({
    required this.icon,
    required this.label,
    this.foreground,
    this.onCover = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = foreground ?? context.cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: onCover
            ? Colors.black.withValues(alpha: 0.35)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tappable link badge that shows the preset's binding scope visually.

class _ConnBadge extends StatelessWidget {
  final bool isActive;
  final bool hasChatBinding;
  final bool hasCharBinding;
  final VoidCallback onTap;

  const _ConnBadge({
    required this.isActive,
    required this.hasChatBinding,
    required this.hasCharBinding,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (hasChatBinding) {
      color = const Color(0xFFFF9500); // orange — chat binding
    } else if (hasCharBinding) {
      color = const Color(0xFFAF52DE); // purple — character binding
    } else if (isActive) {
      color = const Color(0xFF34C759); // green — global active
    } else {
      color = context.cs.onSurfaceVariant.withValues(alpha: 0.5); // grey
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: (hasChatBinding || hasCharBinding || isActive)
              ? color.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.link, size: 16, color: color),
      ),
    );
  }
}
