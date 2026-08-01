import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';

/// The preset editor's dashboard: one glass card holding the preset identity
/// (leading art/icon, name, subtitle, overflow menu), a row of utility buttons
/// and stat badges, and the preset's block list with an "Add Block" row.
///
/// Shared by the plain preset editor and the agentic (Studio) preset editor so
/// both screens render the same frame — they differ only in what they hand to
/// the slots.
class PresetDashboardCard extends StatelessWidget {
  /// Cover thumbnail or circular icon shown left of the title. Null renders the
  /// title flush against the card edge.
  final Widget? leading;
  final String title;

  /// Second line under the title (e.g. `by <author>`). Null hides the line.
  final String? subtitle;
  final VoidCallback? onTitleTap;
  final VoidCallback onMenuTap;

  /// Utility buttons pinned to the left of the utils row.
  final List<Widget> utilsLeading;

  /// Stat badges pinned to the right of the utils row.
  final List<Widget> utilsTrailing;

  /// Optional strip between the utils row and the block list (e.g. the Studio
  /// editor's injection-point filter chips). Supplies its own padding.
  final Widget? belowUtils;

  final Widget? blockList;
  final VoidCallback onAddBlock;

  /// Mirrors the `addBlockAtTop` app setting: puts the add row above the list.
  final bool addBlockAtTop;
  final String addBlockLabel;

  const PresetDashboardCard({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.onTitleTap,
    required this.onMenuTap,
    this.utilsLeading = const [],
    this.utilsTrailing = const [],
    this.belowUtils,
    this.blockList,
    required this.onAddBlock,
    this.addBlockAtTop = false,
    this.addBlockLabel = 'Add Block',
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.cs.outline),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: leading art + name/subtitle + three-dot menu
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 12)],
                  Expanded(
                    child: GestureDetector(
                      onTap: onTitleTap,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: context.cs.onSurface,
                              ),
                            ),
                            if (subtitle != null)
                              Text(
                                subtitle!,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: context.cs.primary.withValues(
                                    alpha: 0.8,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  PresetDotsButton(onTap: onMenuTap),
                ],
              ),
            ),
            // Utils row: buttons | spacer | stat badges
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Row(
                children: [
                  ...utilsLeading,
                  const Spacer(),
                  ...utilsTrailing,
                ],
              ),
            ),
            if (belowUtils != null) belowUtils!,
            const SizedBox(height: 12),
            if (addBlockAtTop)
              PresetAddBlockRow(
                onTap: onAddBlock,
                atTop: true,
                label: addBlockLabel,
              ),
            if (blockList != null) blockList!,
            if (!addBlockAtTop)
              PresetAddBlockRow(onTap: onAddBlock, label: addBlockLabel),
          ],
        ),
      ),
    );
  }
}

// ─── PresetAddBlockRow ────────────────────────────────────────────────────────

class PresetAddBlockRow extends StatelessWidget {
  final VoidCallback onTap;

  /// When true the row sits above the block list: drop the bottom-rounded
  /// corners and use a bottom divider instead of a top one.
  final bool atTop;
  final String label;

  const PresetAddBlockRow({
    super.key,
    required this.onTap,
    this.atTop = false,
    this.label = 'Add Block',
  });

  @override
  Widget build(BuildContext context) {
    final radius = atTop
        ? BorderRadius.zero
        : const BorderRadius.only(
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(14),
          );
    return Material(
      color: Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              top: atTop
                  ? BorderSide.none
                  : const BorderSide(color: Color(0x33808080), width: 1),
              bottom: atTop
                  ? const BorderSide(color: Color(0x33808080), width: 1)
                  : BorderSide.none,
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 30), // align with drag handle column
              Icon(Icons.add, size: 16, color: context.cs.primary),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: context.cs.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── PresetDotsButton ─────────────────────────────────────────────────────────

class PresetDotsButton extends StatelessWidget {
  final VoidCallback onTap;
  const PresetDotsButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.cs.primary.withValues(alpha: 0.1),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            Icons.more_vert,
            size: 20,
            color: context.cs.primary.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}

// ─── PresetUtilButton ─────────────────────────────────────────────────────────

/// Round utility button in the dashboard's utils row, with an optional red
/// count bubble (regex scripts on a plain preset, enabled agents on an agentic
/// one).
class PresetUtilButton extends StatelessWidget {
  final IconData icon;
  final int count;
  final VoidCallback onTap;
  const PresetUtilButton({
    super.key,
    required this.icon,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: context.cs.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              icon,
              size: 14,
              color: context.cs.primary.withValues(alpha: 0.7),
            ),
          ),
          if (count > 0)
            Positioned(
              top: -4,
              right: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                height: 12,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF4444),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: context.cs.surface, width: 1),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── PresetStatBadge ──────────────────────────────────────────────────────────

/// Pill badge in the dashboard's utils row (token estimate, requests/turn…).
class PresetStatBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  const PresetStatBadge({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: context.cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
