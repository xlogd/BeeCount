import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../utils/invoice_file.dart';
import '../data_import_service.dart';
import 'file_reader.dart';

/// A preview owns the temporary files until the import (possibly in the
/// background) finishes.
class TransactionZip {
  TransactionZip._(this._directory, this.rows, this.attachments);

  final Directory _directory;
  final List<List<String>> rows;
  final Map<int, List<ImportAttachment>> attachments;
  Future<void>? _activeImport;

  int get invoiceCount => attachments.values
      .expand((files) => files)
      .where((file) => isInvoiceFile(file.fileName))
      .length;

  int get attachmentCount =>
      attachments.values.fold(0, (count, files) => count + files.length);

  Future<T> import<T>(Future<T> Function() save) async {
    final pending = Future<T>.sync(save);
    _activeImport = pending.then<void>((_) {}, onError: (Object _) {});
    try {
      return await pending;
    } finally {
      _activeImport = null;
    }
  }

  Future<void> dispose() async {
    await _activeImport;
    await _directory.delete(recursive: true);
  }

  static Future<TransactionZip> read({
    required Directory temporaryDirectory,
    String? path,
    Uint8List? bytes,
  }) async {
    final directory = await temporaryDirectory.createTemp('transaction_zip_');
    try {
      return await compute(
        _readZip,
        (directory: directory, path: path, bytes: path == null ? bytes : null),
      );
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }
}

const _sequenceLabels = {'序号', '序號', 'No', '번호'};
final _fileSequence = RegExp(r'^(?:序号|序號|No|번호)-([1-9][0-9]*)-(.+)$');
final _attachmentIndex = RegExp(r'^([1-9][0-9]*)-');
final _safeExtension = RegExp(r'^\.[a-z0-9]{1,10}$');

TransactionZip _readZip(
  ({Directory directory, String? path, Uint8List? bytes}) request,
) {
  final InputStreamBase input = request.path != null
      ? InputFileStream(request.path!)
      : InputStream(request.bytes ?? Uint8List(0));
  try {
    final archive = _decodeArchive(input);
    final csv = archive.findFile('transactions.csv');
    if (csv == null) {
      throw const FormatException('Missing transactions.csv');
    }
    final text = FileReaderService.decodeBytes(_readEntry(csv));
    // Export writes LF record separators and can quote notes containing LF.
    final rows = const CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
      allowInvalid: false,
    )
        .convert(text.replaceAll('\r\n', '\n'))
        .map((row) => row.map((cell) => cell.toString()).toList())
        .where((row) => row.any((cell) => cell.trim().isNotEmpty))
        .toList();
    if (rows.isEmpty || !_sequenceLabels.contains(rows.first.first.trim())) {
      throw const FormatException(
          'Missing sequence column in transactions.csv');
    }
    final sequences = <int>{};
    for (final row in rows.skip(1)) {
      final sequence = int.tryParse(row.first.trim());
      if (sequence == null || sequence < 1 || !sequences.add(sequence)) {
        throw FormatException('Invalid or duplicate sequence: ${row.first}');
      }
    }

    final grouped = <int, List<({ArchiveFile file, int? index})>>{};
    for (final file in archive.files) {
      final parts = file.name.split('/');
      if (parts.first != '附件' && parts.first != '发票') continue;
      if (parts.length == 2 && parts.last.isEmpty && !file.isFile) continue;
      final match =
          parts.length == 2 ? _fileSequence.firstMatch(parts.last) : null;
      final sequence = int.tryParse(match?.group(1) ?? '');
      final extension = p.extension(parts.last).toLowerCase();
      if (sequence == null ||
          !sequences.contains(sequence) ||
          !_safeExtension.hasMatch(extension) ||
          (parts.first == '发票') != isInvoiceFile(parts.last)) {
        throw FormatException(
            'File cannot be matched to a transaction: ${file.name}');
      }
      final index = int.tryParse(
          _attachmentIndex.firstMatch(match!.group(2)!)?.group(1) ?? '');
      grouped.putIfAbsent(sequence, () => []).add((file: file, index: index));
    }

    final attachments = <int, List<ImportAttachment>>{};
    for (final entry in grouped.entries) {
      final files = entry.value;
      if (files.length > 1) {
        final indices = files.map((file) => file.index).toSet();
        if (indices.contains(null) || indices.length != files.length) {
          throw FormatException(
              'Ambiguous attachment order for sequence ${entry.key}');
        }
        files.sort((a, b) => a.index!.compareTo(b.index!));
      }
      final imported = <ImportAttachment>[];
      for (final file in files) {
        final name = p.posix.basename(file.file.name);
        final data = _readEntry(file.file);
        if (isInvoiceFile(name) &&
            (data.length < 5 ||
                String.fromCharCodes(data.take(5)) != '%PDF-')) {
          throw FormatException('Invalid PDF invoice: $name');
        }
        final storedName =
            '${const Uuid().v4()}${p.extension(name).toLowerCase()}';
        final staged = File(p.join(request.directory.path, storedName));
        staged.writeAsBytesSync(data);
        imported.add(ImportAttachment(
          fileName: storedName,
          originalName: name,
          fileSize: data.length,
          sortOrder: imported.length,
          sourcePath: staged.path,
        ));
      }
      attachments[entry.key] = imported;
    }
    return TransactionZip._(request.directory, rows, attachments);
  } finally {
    input.closeSync();
  }
}

Archive _decodeArchive(InputStreamBase input) {
  // The ZIP footer is at most 65,535 comment bytes from the end. Reject
  // a missing footer here so archive's search cannot scan an entire
  // truncated disk file byte by byte.
  const footerSize = 22;
  const maxCommentSize = 0xffff;
  final tailSize = input.length.clamp(0, footerSize + maxCommentSize);
  final tail = ByteData.sublistView(
      input.subset(input.length - tailSize, tailSize).toUint8List());
  var hasFooter = false;
  for (var offset = tail.lengthInBytes - footerSize; offset >= 0; offset--) {
    if (tail.getUint32(offset, Endian.little) == 0x06054b50 &&
        offset + footerSize + tail.getUint16(offset + 20, Endian.little) ==
            tail.lengthInBytes) {
      hasFooter = true;
      break;
    }
  }
  if (!hasFooter) {
    throw const FormatException('Incomplete ZIP archive');
  }

  final decoder = ZipDecoder();
  final archive = decoder.decodeBuffer(input);
  final paths = <String>{};
  for (final header in decoder.directory.fileHeaders) {
    final name = header.file!.filename.replaceAll('\\', '/');
    if (!paths.add(name)) {
      throw FormatException('Duplicate ZIP entry: $name');
    }
  }
  return archive;
}

List<int> _readEntry(ArchiveFile file) {
  if (!file.isFile || file.isSymbolicLink || file.size <= 0) {
    throw FormatException('Invalid ZIP entry: ${file.name}');
  }
  final data = file.content as List<int>;
  if (data.length != file.size || getCrc32(data) != file.crc32) {
    throw FormatException('Corrupt ZIP entry: ${file.name}');
  }
  // Entries from a disk ZIP share the outer InputFileStream. Closing one
  // entry closes that stream for the remaining attachments.
  file.clear();
  return data;
}
