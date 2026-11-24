import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_doc_scanner/flutter_doc_scanner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

final documentScanServiceProvider =
    Provider<DocumentScanService>((ref) => DocumentScanService());

class DocumentScanService {
  DocumentScanService({
    FlutterDocScanner? scanner,
    MethodChannel? androidChannel,
    bool? android,
  })  : _scanner = scanner ?? FlutterDocScanner(),
        _androidChannel = androidChannel ??
            const MethodChannel('com.tntlikely.beecount/document_scan'),
        _android = android ?? Platform.isAndroid;

  final FlutterDocScanner _scanner;
  final MethodChannel _androidChannel;
  final bool _android;

  Future<List<File>> scan({
    required int remaining,
    void Function(int skipped)? onPageLimit,
  }) async {
    if (remaining <= 0) return const [];
    final result = await _scanner.getScannedDocumentAsImages(page: remaining);
    if (result == null) return const [];
    final images = result.images.take(remaining).toList(growable: false);
    if (images.isEmpty) {
      throw const FormatException('No scanned pages returned');
    }
    final skipped = result.images.length - images.length;

    final files = _android
        ? await _copyAndroidImages(images)
        : await _copyIosImages(images, result.images);
    if (skipped > 0) onPageLimit?.call(skipped);
    return files;
  }

  Future<List<File>> _copyAndroidImages(List<String> images) async {
    for (final value in images) {
      final uri = Uri.tryParse(value);
      if (uri == null ||
          (uri.scheme != 'content' && uri.scheme != 'file') ||
          (uri.scheme == 'content' && uri.host.isEmpty) ||
          (uri.scheme == 'file' &&
              (uri.host.isNotEmpty || !uri.path.startsWith('/')))) {
        throw const FormatException('Invalid scanned image URI');
      }
    }
    final paths = await _androidChannel
        .invokeListMethod<String>('copyImages', {'uris': images});
    if (paths == null || paths.length != images.length) {
      throw const FormatException('Scanned images were not copied');
    }
    final files = paths.map(File.new).toList(growable: false);
    for (final file in files) {
      if (!await file.exists() || await file.length() == 0) {
        throw const FormatException('Scanned image is empty');
      }
    }
    return files;
  }

  Future<List<File>> _copyIosImages(
      List<String> selected, List<String> returned) async {
    final cache = Directory(
        p.join((await getTemporaryDirectory()).path, 'beecount_scans'));
    await cache.create(recursive: true);
    final documents = await getApplicationDocumentsDirectory();
    final copied = <File>[];
    try {
      for (final value in selected) {
        final source = _localImage(value);
        if (source == null) {
          throw const FormatException('Invalid scanned image path');
        }
        final extension = p.extension(source.path).toLowerCase();
        if (!{'.png', '.jpg', '.jpeg'}.contains(extension) ||
            !await source.exists() ||
            await source.length() == 0) {
          throw const FormatException('Invalid scanned image');
        }
        final destination =
            File(p.join(cache.path, 'scan_${const Uuid().v4()}$extension'));
        copied.add(destination);
        await source.copy(destination.path);
      }
      return copied;
    } catch (_) {
      for (final file in copied) {
        await _deleteImage(file);
      }
      rethrow;
    } finally {
      for (final value in returned) {
        final source = _localImage(value);
        // VisionKit's plugin writes its generated PNGs directly to Documents.
        if (source != null &&
            p.equals(p.dirname(source.path), documents.path) &&
            RegExp(r'^\d{8}-\d{6}-\d+\.png$')
                .hasMatch(p.basename(source.path))) {
          await _deleteImage(source);
        }
      }
    }
  }

  File? _localImage(String value) {
    final uri = Uri.tryParse(value);
    if (uri?.scheme == 'file' &&
        uri!.host.isEmpty &&
        uri.path.startsWith('/')) {
      return File.fromUri(uri);
    }
    if (p.isAbsolute(value)) return File(value);
    return null;
  }

  Future<void> _deleteImage(File file) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await file.delete();
      }
    } on FileSystemException {
      // Cleanup must not invalidate a completed copy.
    }
  }
}
