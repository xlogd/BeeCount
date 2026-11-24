import 'dart:io';

import 'package:path/path.dart' as p;

bool isInvoiceFile(String name) => p.extension(name).toLowerCase() == '.pdf';

Future<void> validateInvoiceFile(File file) async {
  final handle = await file.open();
  try {
    final header = await handle.read(5);
    if (!isInvoiceFile(file.path) || String.fromCharCodes(header) != '%PDF-') {
      throw const FormatException('Invalid PDF invoice');
    }
  } finally {
    await handle.close();
  }
}
