import 'package:flutter/material.dart';

import '../../../../core/platform/haptics.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';

/// Shared Glaze-styled building blocks for the memory-books sheet.
///
/// They replace the Material `OutlinedButton` / `FilledButton` / `FilterChip` /
/// `TextButton` widgets the sheet used before, so it renders with the same
/// glass surfaces, pills and ripples as the rest of the app.

/// Small colour-coded pill used for status markers on cards.
class MemoryPill extends StatelessWidget {
  final String label;
  final Color color;
  final double fontSize;
  final EdgeInsetsGeometry padding;

  const MemoryPill({
    super.key,
    required this.label,
    required this.color,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// Tappable text chip used for the per-card action row (Generate / Approve /
/// Edit / Delete). Glaze's flat, colour-tinted equivalent of a `TextButton`.
///
/// Deliberately a `Material` + `InkWell` rather than a [GlassSurface]: a chat
/// can carry dozens of memory cards, and a backdrop-blurred surface per chip
/// would put a blur pass on every one of them.
class MemoryActionChip extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const MemoryActionChip({
    super.key,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    return Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: radius,
      child: InkWell(
        onTap: () {
          Haptics.selectionClick();
          onTap();
        },
        borderRadius: radius,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// Icon + label tile used for the sheet's toolbar actions. Takes the place of
/// the Material outlined/filled buttons the sheet used to lay out in rows.
class MemoryActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// Colour of the icon, the label and the ripple. Defaults to the theme's
  /// `onSurface` for the label and `onSurfaceVariant` for the icon.
  final Color? accent;

  /// Renders the tile as the emphasised (primary-tinted) action.
  final bool emphasised;

  const MemoryActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent,
    this.emphasised = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final base = accent ?? (emphasised ? context.cs.primary : null);
    final iconColor = base ?? context.cs.onSurfaceVariant;
    final labelColor = base ?? context.cs.onSurface;
    final radius = BorderRadius.circular(14);

    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: GlassSurface(
        borderRadius: radius,
        tint: emphasised ? context.cs.primary.withValues(alpha: 0.18) : null,
        border: Border.all(
          color: base != null
              ? base.withValues(alpha: 0.3)
              : context.cs.outlineVariant,
        ),
        onTap: onTap,
        glowColor: base ?? context.cs.primary,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 8),
              // Flexible + ellipsis so a long localized label degrades
              // instead of overflowing its tile.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: labelColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Big-number counter tile used by the sheet's status row.
class MemoryStatTile extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const MemoryStatTile({
    super.key,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: color.withValues(alpha: 0.3)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: context.cs.onSurface,
              ),
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card shell shared by the entry and draft cards: the same rounded, bordered
/// surface the rest of Glaze's list rows use, with an optional accent border
/// and fill for "generating" / "needs rebuild" states.
class MemoryCard extends StatelessWidget {
  final Widget child;
  final Color? accent;

  const MemoryCard({super.key, required this.child, this.accent});

  @override
  Widget build(BuildContext context) {
    final accentColor = accent;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accentColor == null
            ? Colors.white.withValues(alpha: 0.05)
            : accentColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor == null
              ? context.cs.outlineVariant
              : accentColor.withValues(alpha: 0.4),
        ),
      ),
      child: child,
    );
  }
}

/// Section title with a trailing count pill, used above the entry / draft
/// lists inside each tab.
class MemorySectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Widget? action;

  const MemorySectionHeader({
    super.key,
    required this.title,
    required this.count,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: context.cs.onSurface,
              ),
            ),
          ),
          if (action != null) Flexible(child: action!),
          const SizedBox(width: 8),
          MemoryPill(
            label: '$count',
            color: context.cs.primary,
            fontSize: 12,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          ),
        ],
      ),
    );
  }
}
