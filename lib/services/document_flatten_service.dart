import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

final documentFlattenServiceProvider =
    Provider<DocumentFlattenService>((ref) => const DocumentFlattenService());

bool get supportsDocumentFlatten =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

class DocumentFlattenService {
  const DocumentFlattenService({
    this.channel =
        const MethodChannel('com.tntlikely.beecount/document_flatten'),
  });

  final MethodChannel channel;

  Future<File> flatten(File source) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(source.path);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    late final int width;
    late final int height;
    late final Uint8List rgba;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final scale =
          math.min(1.0, 1920 / math.max(descriptor.width, descriptor.height));
      width = (descriptor.width * scale).round();
      height = (descriptor.height * scale).round();
      if (width < 64 || height < 64) {
        throw const FormatException('Image is too small for UVDoc');
      }
      codec = await descriptor.instantiateCodec(
          targetWidth: width, targetHeight: height);
      final frame = (await codec.getNextFrame()).image;
      try {
        if (frame.width != width || frame.height != height) {
          throw const FormatException('Unexpected decoded dimensions');
        }
        final data = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) throw const FormatException('Could not read pixels');
        rgba = Uint8List.sublistView(data);
      } finally {
        frame.dispose();
      }
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }

    final pixels = await compute(_toBgr, rgba);
    final flattened = await channel.invokeMethod<Float32List>(
        'flatten', {'pixels': pixels, 'width': width, 'height': height});
    if (flattened == null || flattened.length != width * height * 3) {
      throw const FormatException('Unexpected UVDoc output');
    }
    final output = await compute(_toRgba, flattened);
    final outputBuffer = await ui.ImmutableBuffer.fromUint8List(output);
    final outputDescriptor = ui.ImageDescriptor.raw(outputBuffer,
        width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
    try {
      final outputCodec = await outputDescriptor.instantiateCodec();
      try {
        final image = (await outputCodec.getNextFrame()).image;
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          if (png == null) {
            throw const FormatException('Could not encode image');
          }
          final directory = await getTemporaryDirectory();
          final file =
              File(p.join(directory.path, 'uvdoc_${const Uuid().v4()}.png'));
          try {
            return await file.writeAsBytes(Uint8List.sublistView(png));
          } catch (_) {
            await discardFlattenedPreview(file);
            rethrow;
          }
        } finally {
          image.dispose();
        }
      } finally {
        outputCodec.dispose();
      }
    } finally {
      outputDescriptor.dispose();
      outputBuffer.dispose();
    }
  }
}

// UVDoc expects planar BGR scaled to [0, 1]. Composite transparent pixels
// over white, using Flutter's premultiplied RGBA representation.
Float32List _toBgr(Uint8List rgba) {
  final count = rgba.length ~/ 4;
  final bgr = Float32List(count * 3);
  for (var i = 0; i < count; i++) {
    final offset = i * 4;
    final white = 255 - rgba[offset + 3];
    bgr[i] = (rgba[offset + 2] + white) / 255;
    bgr[count + i] = (rgba[offset + 1] + white) / 255;
    bgr[2 * count + i] = (rgba[offset] + white) / 255;
  }
  return bgr;
}

Uint8List _toRgba(Float32List bgr) {
  final count = bgr.length ~/ 3;
  final rgba = Uint8List(count * 4);
  for (var i = 0; i < count; i++) {
    rgba[i * 4] = _byte(bgr[2 * count + i]);
    rgba[i * 4 + 1] = _byte(bgr[count + i]);
    rgba[i * 4 + 2] = _byte(bgr[i]);
    rgba[i * 4 + 3] = 255;
  }
  return rgba;
}

int _byte(double value) {
  if (!value.isFinite) throw const FormatException('Invalid UVDoc pixel');
  return (value.clamp(0.0, 1.0) * 255).round();
}

Future<void> discardFlattenedPreview(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // Temporary files may already have been evicted by the OS.
  }
}
