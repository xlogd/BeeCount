import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// App-owned boundary for the existing system save/share contract.
abstract interface class TransactionExportPlatform {
  bool get shareAfterSave;
  Future<String> exportDirectory();
  Future<void> writeCsv(String path, String csv);
  Future<void> writePackage(
      String path, String csv, List<TransactionExportFile> attachments);
  Future<void> shareCsv(String path, String text);
}

class TransactionExportFile {
  const TransactionExportFile(this.source, this.archivePath);
  final File source;
  final String archivePath;
}

final transactionExportPlatformProvider = Provider<TransactionExportPlatform>(
    (ref) => const SystemTransactionExportPlatform());

class SystemTransactionExportPlatform implements TransactionExportPlatform {
  const SystemTransactionExportPlatform();

  @override
  bool get shareAfterSave => Platform.isIOS;

  @override
  Future<String> exportDirectory() async {
    if (Platform.isIOS) {
      // iOS: 写入应用文档目录，然后使用系统分享
      final docDir = await getApplicationDocumentsDirectory();
      return docDir.path;
    }
    // Android: 直接保存到公共 Download/BeeCount 目录
    const downloadPath = '/storage/emulated/0/Download/BeeCount';
    final dir = Directory(downloadPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return downloadPath;
  }

  @override
  Future<void> writeCsv(String path, String csv) async {
    // 添加UTF-8 BOM标记，确保Excel正确识别中文编码
    const utf8Bom = '\uFEFF';
    final temporary = File('$path.part');
    try {
      await temporary.writeAsString(utf8Bom + csv, encoding: utf8, flush: true);
      await temporary.rename(path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  @override
  Future<void> writePackage(
      String path, String csv, List<TransactionExportFile> attachments) async {
    for (final attachment in attachments) {
      if (!await attachment.source.exists()) {
        throw FileSystemException(
            'Attachment file is missing', attachment.source.path);
      }
    }
    final temporary = File('$path.part');
    final encoder = ZipFileEncoder();
    var opened = false;
    try {
      encoder.create(temporary.path);
      opened = true;
      final csvBytes = utf8.encode('\uFEFF$csv');
      encoder.addArchiveFile(
          ArchiveFile('transactions.csv', csvBytes.length, csvBytes));
      for (final attachment in attachments) {
        await encoder.addFile(attachment.source, attachment.archivePath);
      }
      await encoder.close();
      opened = false;
      await temporary.rename(path);
    } catch (_) {
      if (opened) {
        try {
          await encoder.close();
        } catch (_) {
          // The partial archive is removed below even if closing fails.
        }
      }
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  @override
  Future<void> shareCsv(String path, String text) async {
    // Keep the original sharing API and dismissal contract for this UI migration.
    // ignore: deprecated_member_use
    await Share.shareXFiles([XFile(path)], text: text);
  }
}
