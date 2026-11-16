import 'package:beecount_business_ui/transaction_export.dart';
import 'package:beecount_ui/beecount_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../models/transaction_export_column.dart';
import '../../../../providers.dart';
import '../../../../services/system/logger_service.dart';
import '../../../shared/dialogs/app_dialogs.dart';
import 'export_csv.dart';
import 'export_platform.dart';
import '../../../shared/scaffold/widgets/page_scaffold.dart';

/// Captures column preferences and binds CSV generation to platform I/O.
class ExportControls extends ConsumerStatefulWidget {
  const ExportControls({super.key});
  @override
  ConsumerState<ExportControls> createState() => _ExportControlsState();
}

class _ExportControlsState extends ConsumerState<ExportControls> {
  bool exporting = false;
  double progress = 0;
  String? savedPath, errorMessage;
  List<TransactionExportColumn> columns =
      List.of(defaultTransactionExportColumns);
  bool columnsReady = false;
  late final Future<SharedPreferences> preferences;
  Future<void> preferenceWrites = Future.value();

  @override
  void initState() {
    super.initState();
    preferences = SharedPreferences.getInstance();
    _restoreColumns();
  }

  Future<void> _restoreColumns() async {
    var restored =
        List<TransactionExportColumn>.of(defaultTransactionExportColumns);
    try {
      restored = restoreTransactionExportColumns((await preferences)
          .getStringList(transactionExportColumnsPreferenceKey));
    } catch (error) {
      logger.warning('Export', 'Unable to restore export columns: $error');
    }
    if (!mounted) return;
    setState(() {
      columns = restored;
      columnsReady = true;
    });
  }

  void _changeColumns(List<String> ids) {
    if (exporting || !columnsReady) return;
    final next = restoreTransactionExportColumns(ids);
    setState(() {
      columns = next;
      savedPath = null;
      errorMessage = null;
    });
    // Serialize writes so rapid selection and reorder actions persist in order.
    final saved = next.map((column) => column.name).toList();
    preferenceWrites = preferenceWrites.then((_) async {
      final prefs = await preferences;
      if (!await prefs.setStringList(
          transactionExportColumnsPreferenceKey, saved)) {
        throw StateError('Column preferences were not saved');
      }
    }).catchError((Object error) {
      logger.warning('Export', 'Unable to save export columns: $error');
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final platform = ref.watch(transactionExportPlatformProvider);
    final ledger = ref.watch(currentLedgerProvider).valueOrNull;
    return V4PageScaffold(
        body: Column(children: [
      BeePageHeader(title: l.exportTitle, leading: const BackButton()),
      Expanded(
          child: BeePageBody(eager: true, children: [
        BeeTransactionExport(
            description: l.exportDescription,
            ledgerLabel: l.configIncludeLedgers,
            ledgerName: ledger?.name,
            fieldLabels: [
              for (final column in columns) exportCsvColumnLabel(l, column)
            ],
            fieldsEditor: BeeExportColumns(
                options: [
                  for (final column in TransactionExportColumn.values)
                    BeeExportColumnOption(
                        id: column.name, label: exportCsvColumnLabel(l, column))
                ],
                selectedIds: columns.map((column) => column.name).toList(),
                labels: BeeExportColumnLabels(
                    title: l.exportColumnsTitle,
                    description: l.exportColumnsDescription,
                    selectionCount: l.exportColumnsSelected(
                        columns.length, TransactionExportColumn.values.length),
                    selectAll: l.exportColumnsSelectAll,
                    clear: l.exportColumnsClear,
                    reset: l.exportColumnsReset,
                    order: l.exportColumnsOrder,
                    moveUp: l.exportColumnsMoveUp,
                    moveDown: l.exportColumnsMoveDown,
                    emptySelection: l.exportColumnsEmpty),
                onChanged: !columnsReady || exporting ? null : _changeColumns),
            actionLabel: platform.shareAfterSave
                ? l.exportButtonIOS
                : l.exportButtonAndroid,
            exporting: exporting,
            progress: progress,
            savedMessage:
                savedPath == null ? null : l.exportSavedTo(savedPath!),
            errorTitle: l.exportFailedTitle,
            errorMessage: errorMessage,
            onExport:
                exporting || !columnsReady || columns.isEmpty ? null : _export),
      ]))
    ]));
  }

  Future<void> _export() async {
    if (exporting || !columnsReady || columns.isEmpty) return;
    final selectedColumns = List<TransactionExportColumn>.unmodifiable(columns);
    // Capture the same current ledger at the moment the export is requested.
    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    final platform = ref.read(transactionExportPlatformProvider);
    final l = AppLocalizations.of(context);
    setState(() {
      exporting = true;
      progress = 0;
      savedPath = null;
      errorMessage = null;
    });
    try {
      final directory = await platform.exportDirectory();
      final csv = await buildTransactionExportCsv(
          repo: repo,
          ledgerId: ledgerId,
          l10n: l,
          columns: selectedColumns,
          onProgress: (value) {
            if (mounted) setState(() => progress = value * .9);
          });
      final now = DateTime.now();
      final fraction =
          (now.millisecond * 1000 + now.microsecond).toString().padLeft(6, '0');
      final ts = '${DateFormat('yyyyMMdd_HHmmss').format(now)}_$fraction';
      final path = p.join(directory, 'beecount_$ts.csv');
      await platform.writeCsv(path, csv);
      if (!mounted) return;
      setState(() {
        savedPath = path;
        progress = 1;
      });
      if (platform.shareAfterSave) {
        // Preserve iOS system sharing, including its original dismiss behavior.
        await platform.shareCsv(path, l.exportShareText);
        if (!mounted) return;
        await AppDialog.info(context,
            title: l.exportSuccessTitle,
            message: l.exportSuccessMessageIOS(path));
      } else {
        await AppDialog.info(context,
            title: l.exportSuccessTitle,
            message: l.exportSuccessMessageAndroid(path));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => errorMessage = error.toString());
      await AppDialog.error(context,
          title: l.exportFailedTitle, message: error.toString());
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }
}
