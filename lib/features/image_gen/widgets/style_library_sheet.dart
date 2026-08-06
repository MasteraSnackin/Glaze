import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/services/file_export_service.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../image_gen_models.dart';
import '../services/image_style_io.dart';

/// Style library: a list of named prompt styles plus the "no style" entry that
/// hands control back to the style written into the image tag by the model.
///
/// Styles can be exported to and imported from JSON so they can be shared.
class StyleLibrarySheet extends StatefulWidget {
  const StyleLibrarySheet({
    super.key,
    required this.settings,
    required this.onUpdate,
  });

  final ImageGenSettings settings;
  final ValueChanged<ImageGenSettings> onUpdate;

  @override
  State<StyleLibrarySheet> createState() => _StyleLibrarySheetState();
}

class _StyleLibrarySheetState extends State<StyleLibrarySheet> {
  late ImageGenSettings _settings = widget.settings;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _valueController = TextEditingController();
  String _selectedId = '';

  @override
  void initState() {
    super.initState();
    _select(
      _settings.activeStyleId.isNotEmpty
          ? _settings.activeStyleId
          : (_settings.styles.isNotEmpty ? _settings.styles.first.id : ''),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  /// Selects a style for editing and refills the editor fields. Controllers
  /// are owned by the state so typing does not reset the caret on rebuild.
  void _select(String id) {
    _selectedId = id;
    final style = _selected;
    _nameController.text = style?.name ?? '';
    _valueController.text = style?.value ?? '';
  }

  void _update(ImageGenSettings next) {
    setState(() => _settings = next);
    widget.onUpdate(next);
  }

  ImageStyle? get _selected {
    for (final style in _settings.styles) {
      if (style.id == _selectedId) return style;
    }
    return null;
  }

  void _addStyle() {
    final style = ImageStyle(
      id: ImageStyleIo.newStyleId(),
      name: 'imggen_style_default_name'.tr(
        args: ['${_settings.styles.length + 1}'],
      ),
    );
    _update(_settings.copyWith(styles: [..._settings.styles, style]));
    setState(() => _select(style.id));
  }

  void _patchSelected(ImageStyle Function(ImageStyle) mutate) {
    final index = _settings.styles.indexWhere((s) => s.id == _selectedId);
    if (index < 0) return;
    final copy = List<ImageStyle>.from(_settings.styles);
    copy[index] = mutate(copy[index]);
    _update(_settings.copyWith(styles: copy));
  }

  void _removeSelected() {
    final copy = _settings.styles.where((s) => s.id != _selectedId).toList();
    _update(
      _settings.copyWith(
        styles: copy,
        activeStyleId: _settings.activeStyleId == _selectedId
            ? ''
            : _settings.activeStyleId,
      ),
    );
    setState(() => _select(copy.isNotEmpty ? copy.first.id : ''));
  }

  Future<void> _export() async {
    if (_settings.styles.isEmpty) {
      GlazeToast.show(
        context,
        'imggen_styles_export_empty'.tr(),
        isError: true,
      );
      return;
    }
    try {
      await FileExportService.export(
        data: ImageStyleIo.encode(_settings.styles),
        filename: ImageStyleIo.fileName('glaze_styles'),
        subfolder: 'styles',
      );
      if (mounted) {
        GlazeToast.show(context, 'imggen_styles_exported'.tr());
      }
    } catch (error) {
      if (mounted) {
        GlazeToast.show(context, '$error', isError: true);
      }
    }
  }

  Future<void> _import() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    try {
      final bytes =
          picked.bytes ??
          (picked.path == null ? null : await File(picked.path!).readAsBytes());
      if (bytes == null) return;
      final imported = ImageStyleIo.decode(utf8.decode(bytes));
      _update(_settings.copyWith(styles: [..._settings.styles, ...imported]));
      setState(() => _select(imported.first.id));
      if (mounted) {
        GlazeToast.show(
          context,
          'imggen_styles_imported'.tr(args: ['${imported.length}']),
        );
      }
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          '${'imggen_styles_import_failed'.tr()}: $error',
          isError: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      titleWidget: Row(
        children: [
          Text(
            'imggen_styles'.tr(),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'imggen_styles_import'.tr(),
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _import,
          ),
          IconButton(
            tooltip: 'imggen_styles_export'.tr(),
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: _export,
          ),
          IconButton(
            tooltip: 'imggen_style_add'.tr(),
            icon: const Icon(Icons.add),
            onPressed: _addStyle,
          ),
        ],
      ),
      fitContent: false,
      enableHeaderBlur: false,
      body: ListView(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 16,
          bottom: MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          _noStyleTile(context),
          for (final style in _settings.styles) _styleTile(context, style),
          if (_selected != null) _editor(context, _selected!),
        ],
      ),
    );
  }

  Widget _noStyleTile(BuildContext context) {
    final active = _settings.activeStyleId.isEmpty;
    return ListTile(
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? context.cs.primary : context.cs.onSurfaceVariant,
      ),
      title: Text('imggen_style_none'.tr()),
      subtitle: Text(
        'imggen_style_none_desc'.tr(),
        style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
      ),
      onTap: () => _update(_settings.copyWith(activeStyleId: '')),
    );
  }

  Widget _styleTile(BuildContext context, ImageStyle style) {
    final active = _settings.activeStyleId == style.id;
    return ListTile(
      leading: IconButton(
        icon: Icon(
          active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: active ? context.cs.primary : context.cs.onSurfaceVariant,
        ),
        onPressed: () =>
            _update(_settings.copyWith(activeStyleId: active ? '' : style.id)),
      ),
      title: Text(style.name),
      subtitle: Text(
        style.value.isEmpty ? 'imggen_style_empty'.tr() : style.value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
      ),
      selected: style.id == _selectedId,
      onTap: () => setState(() => _select(style.id)),
    );
  }

  Widget _editor(BuildContext context, ImageStyle style) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'imggen_style_name'.tr(),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => _patchSelected(
              (s) => s.copyWith(name: v.trim().isEmpty ? s.name : v),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _valueController,
            minLines: 4,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: 'imggen_style_value'.tr(),
              hintText: 'masterpiece, cinematic lighting, painterly',
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) => _patchSelected((s) => s.copyWith(value: v)),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _removeSelected,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text('imggen_style_delete'.tr()),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
}
