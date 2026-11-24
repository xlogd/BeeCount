import 'dart:typed_data';

import 'package:beecount_ui/beecount_ui.dart';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Keeps the image still while the user positions and resizes the crop frame.
class AttachmentCropPage extends StatefulWidget {
  const AttachmentCropPage({super.key, required this.image});

  final Uint8List image;

  @override
  State<AttachmentCropPage> createState() => _AttachmentCropPageState();
}

class _AttachmentCropPageState extends State<AttachmentCropPage> {
  final CropController _controller = CropController();
  CropStatus _status = CropStatus.loading;
  int _undoCount = 0;
  int _redoCount = 0;
  String? _error;

  bool get _busy => _status == CropStatus.cropping;

  void _finish(CropResult result) {
    if (!mounted) return;
    switch (result) {
      case CropSuccess(:final croppedImage) when croppedImage.isNotEmpty:
        Navigator.of(context).pop(croppedImage);
      case CropSuccess():
      case CropFailure():
        setState(() => _error = AppLocalizations.of(context).imageCropFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    const background = Color(0xff111716);
    Widget action(String key, String icon, String tooltip, VoidCallback? onTap,
            {bool flipped = false}) =>
        IconButton(
            key: ValueKey(key),
            tooltip: tooltip,
            onPressed: onTap,
            constraints: const BoxConstraints.tightFor(width: 42, height: 44),
            icon: Transform.flip(
                flipX: flipped,
                child: BeeLineIcon(icon,
                    size: 22,
                    color: onTap == null ? Colors.white38 : Colors.white)));

    return PopScope(
        canPop: !_busy,
        child: Scaffold(
            backgroundColor: background,
            appBar: AppBar(
                backgroundColor: background,
                foregroundColor: Colors.white,
                titleSpacing: 0,
                leadingWidth: 48,
                title: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(l.imageCropTitle,
                            maxLines: 1,
                            style: const TextStyle(fontSize: 17)))),
                leading: action('attachment-crop-cancel', 'X', l.commonCancel,
                    _busy ? null : () => Navigator.of(context).pop()),
                actions: [
                  action('attachment-crop-undo', 'Undo2', l.imageCropUndo,
                      _busy || _undoCount == 0 ? null : _controller.undo),
                  action('attachment-crop-redo', 'Undo2', l.imageCropRedo,
                      _busy || _redoCount == 0 ? null : _controller.redo,
                      flipped: true),
                  action(
                      'attachment-crop-save',
                      'Check',
                      l.commonSave,
                      _status != CropStatus.ready
                          ? null
                          : () {
                              setState(() => _error = null);
                              _controller.crop();
                            }),
                  const SizedBox(width: 4),
                ]),
            body: SafeArea(
                child: Column(children: [
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Crop(
                          key: const ValueKey('attachment-crop-editor'),
                          image: widget.image,
                          controller: _controller,
                          interactive: false,
                          initialRectBuilder:
                              InitialRectBuilder.withSizeAndRatio(size: .82),
                          baseColor: background,
                          maskColor: const Color(0x99000000),
                          progressIndicator: const CircularProgressIndicator(),
                          cornerDotBuilder: (_, __) =>
                              const DotControl(color: Colors.white, padding: 5),
                          overlayBuilder: (_, __) => DecoratedBox(
                              decoration: BoxDecoration(
                                  border: Border.all(
                                      color: Colors.white, width: 2))),
                          onHistoryChanged: (history) {
                            if (mounted) {
                              setState(() {
                                _undoCount = history.undoCount;
                                _redoCount = history.redoCount;
                              });
                            }
                          },
                          onStatusChanged: (status) {
                            if (mounted) setState(() => _status = status);
                          },
                          onCropped: _finish))),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(_error!,
                        style: const TextStyle(color: Color(0xffffb4ab)))),
            ]))));
  }
}
