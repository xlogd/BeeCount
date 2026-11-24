import 'dart:io';

import 'package:beecount_business_ui/transaction_export.dart';
import 'package:beecount_ui/beecount_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../models/transaction_export_column.dart';
import '../../../../models/transaction_export_filter.dart';
import '../../../../providers.dart';
import '../../../../services/attachment_service.dart';
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
  TransactionExportFilter filter = const TransactionExportFilter.all();
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

  void _changeType(String id) {
    if (exporting) return;
    final type =
        TransactionExportType.values.singleWhere((type) => type.name == id);
    setState(() {
      filter = TransactionExportFilter(
          startDate: filter.startDate, endDate: filter.endDate, type: type);
      savedPath = null;
      errorMessage = null;
    });
  }

  Future<void> _pickDates() async {
    if (exporting) return;
    final l = AppLocalizations.of(context);
    final selected = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1900),
        lastDate: DateTime(9999, 12, 31),
        initialDateRange: filter.startDate == null || filter.endDate == null
            ? null
            : DateTimeRange(start: filter.startDate!, end: filter.endDate!),
        helpText: l.exportDateRangePickerTitle,
        confirmText: l.commonConfirm,
        builder: (pickerContext, child) {
          final theme = Theme.of(pickerContext);
          final media = MediaQuery.of(pickerContext);
          final material = MaterialLocalizations.of(pickerContext);
          final style = theme.datePickerTheme.rangePickerHeaderHeadlineStyle ??
              theme.textTheme.titleLarge ??
              const TextStyle(fontSize: 22);
          // Flutter's calendar range header leaves the first date unflexed.
          // Fit that summary without reducing the calendar/input text scale.
          final available = (media.size.width -
                  media.padding.horizontal -
                  (media.size.width < 360 ? 42 : 72) -
                  64 -
                  56)
              .clamp(40.0, double.infinity);
          var measured = 0.0;
          for (final label in [
            material.dateRangeStartLabel,
            material.formatShortMonthDay(DateTime(9999, 12, 31)),
            material.formatShortDate(DateTime(9999, 12, 31))
          ]) {
            final painter = TextPainter(
                text: TextSpan(text: '$label – ', style: style),
                textDirection: Directionality.of(pickerContext),
                textScaler: media.textScaler)
              ..layout();
            if (painter.width > measured) measured = painter.width;
            painter.dispose();
          }
          final fitted = measured <= available
              ? style
              : style.copyWith(
                  fontSize: (style.fontSize ?? 22) * available / measured);
          return Theme(
              data: theme.copyWith(
                  inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                      isDense: true,
                      constraints: const BoxConstraints(minHeight: 48),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8)),
                  datePickerTheme: theme.datePickerTheme
                      .copyWith(rangePickerHeaderHeadlineStyle: fitted)),
              child: child!);
        });
    if (selected == null || !mounted || exporting) return;
    setState(() {
      filter = TransactionExportFilter(
          startDate: selected.start, endDate: selected.end, type: filter.type);
      savedPath = null;
      errorMessage = null;
    });
  }

  void _clearDates() {
    if (exporting) return;
    setState(() {
      filter = TransactionExportFilter(type: filter.type);
      savedPath = null;
      errorMessage = null;
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
            filtersEditor: BeeExportFilters(
                title: l.exportFiltersTitle,
                dateLabel: l.exportDateRangeLabel,
                dateValue: filter.hasDateRange
                    ? '${DateFormat.yMd(l.localeName).format(filter.startDate!)} – ${DateFormat.yMd(l.localeName).format(filter.endDate!)}'
                    : l.exportAllDates,
                dateHint: l.exportDateRangeHint,
                clearDatesLabel: l.exportClearDates,
                typeLabel: l.exportRecordTypeLabel,
                options: [
                  BeeExportTypeOption(id: 'all', label: l.exportAllTypes),
                  BeeExportTypeOption(
                      id: 'expense', label: l.exportTypeExpense),
                  BeeExportTypeOption(id: 'income', label: l.exportTypeIncome),
                  BeeExportTypeOption(
                      id: 'transfer', label: l.exportTypeTransfer),
                ],
                selectedType: filter.type.name,
                onPickDates: exporting ? null : _pickDates,
                onClearDates:
                    exporting || !filter.hasDateRange ? null : _clearDates,
                onTypeChanged: exporting ? null : _changeType),
            fieldLabels: [
              l.exportCsvHeaderSequence,
              for (final column in columns)
                if (column != TransactionExportColumn.attachments)
                  exportCsvColumnLabel(l, column)
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
    final selectedFilter = filter;
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
      var recordCount = 0;
      final includeAttachments =
          selectedColumns.contains(TransactionExportColumn.attachments);
      var attachments = <TransactionExportAttachment>[];
      final csv = await buildTransactionExportCsv(
          repo: repo,
          ledgerId: ledgerId,
          l10n: l,
          columns: selectedColumns,
          filter: selectedFilter,
          packageAttachments: includeAttachments,
          onAttachments: (value) => attachments = value,
          onRecordCount: (value) => recordCount = value,
          onProgress: (value) {
            if (mounted) setState(() => progress = value * .9);
          });
      if (!mounted) return;
      if (selectedFilter.isActive && recordCount == 0) {
        await AppDialog.info(context,
            title: l.exportTitle, message: l.exportNoMatchingRecords);
        return;
      }
      final now = DateTime.now();
      final fraction =
          (now.millisecond * 1000 + now.microsecond).toString().padLeft(6, '0');
      final ts = '${DateFormat('yyyyMMdd_HHmmss').format(now)}_$fraction';
      final hasAttachments = includeAttachments && attachments.isNotEmpty;
      final path =
          p.join(directory, 'beecount_$ts.${hasAttachments ? 'zip' : 'csv'}');
      if (hasAttachments) {
        final attachmentDirectory =
            await ref.read(attachmentServiceProvider).getAttachmentDirectory();
        final files = <TransactionExportFile>[];
        for (final attachment in attachments) {
          final name = attachment.attachment.fileName;
          if (name != p.basename(name) ||
              name.contains('\\') ||
              name == '.' ||
              name == '..') {
            throw FormatException('Invalid attachment file name', name);
          }
          files.add(TransactionExportFile(
              File(p.join(attachmentDirectory.path, name)),
              attachment.archivePath));
        }
        await platform.writePackage(path, csv, files);
      } else {
        await platform.writeCsv(path, csv);
      }
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
