import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final runRoot = Directory(Platform.environment['QA_RUN_ROOT'] ?? '').absolute;
  final owner = File('${runRoot.path}/.qa-owner');
  final evidence = Directory('${runRoot.path}/evidence');
  if (!owner.existsSync() ||
      !evidence.existsSync() ||
      owner.readAsStringSync().trim() !=
          Platform.environment['QA_RUN_ID']) {
    throw StateError('A matching private QA run is required');
  }
  await integrationDriver(
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      if (data == null || data['run_id'] != owner.readAsStringSync().trim()) {
        throw StateError('Device result does not belong to this QA run');
      }
      await File('${evidence.path}/device-acceptance.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert(data),
          flush: true);
    },
  );
}
