import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_bottom_sheet.dart';

/// One row of a [showGlazePickerSheet] list.
class GlazePickerItem {
  final String label;
  final bool isActive;
  final dynamic value;

  /// Leading glyph. When null the row falls back to the plain check-mark
  /// treatment (icon shown only while active).
  final IconData? icon;

  const GlazePickerItem({
    required this.label,
    required this.isActive,
    required this.value,
    this.icon,
  });
}

/// Single-choice picker opened by a [GlazeDropdownChip]: each row carries its
/// own glyph, and the active one is tinted plus tagged with a trailing check.
void showGlazePickerSheet(
  BuildContext context, {
  required String title,
  required List<GlazePickerItem> items,
  required ValueChanged<dynamic> onSelect,
  Widget? headerAction,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: title,
    headerAction: headerAction,
    items: items.map((item) {
      void select() {
        Navigator.of(context, rootNavigator: true).pop();
        onSelect(item.value);
      }

      return BottomSheetItem(
        icon: item.icon ?? (item.isActive ? Icons.check_rounded : null),
        iconColor: item.icon != null
            ? (item.isActive ? context.cs.primary : context.cs.onSurfaceVariant)
            : context.cs.primary,
        label: item.label,
        actions: item.icon != null && item.isActive
            ? [
                BottomSheetAction(
                  icon: Icons.check_rounded,
                  color: context.cs.primary,
                  onTap: select,
                ),
              ]
            : const [],
        onTap: select,
      );
    }).toList(),
  );
}

/// Glass pill that opens a picker sheet — the dropdown trigger of a list's
/// control row (catalog provider/sort, presets type).
class GlazeDropdownChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const GlazeDropdownChip({
    super.key,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        height: 32,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          tint: context.cs.surface,
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.18)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.cs.primary,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: context.cs.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass button that opens a filter sheet, badged with how many filters are
/// currently applied.
class GlazeFilterIconButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const GlazeFilterIconButton({
    super.key,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            GlassSurface(
              borderRadius: BorderRadius.circular(16),
              tint: context.cs.surface,
              border: Border.all(
                color: context.cs.primary.withValues(alpha: 0.18),
              ),
              child: Center(
                child: Icon(
                  Icons.filter_list_rounded,
                  size: 18,
                  color: context.cs.primary,
                ),
              ),
            ),
            if (count > 0)
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: context.cs.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
