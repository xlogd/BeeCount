/// Stable identifiers shared by CSV generation and saved column preferences.
enum TransactionExportColumn {
  type,
  category,
  subCategory,
  amount,
  currency,
  account,
  fromAccount,
  toAccount,
  note,
  time,
  tags,
  attachments,
}

const defaultTransactionExportColumns = TransactionExportColumn.values;
const transactionExportColumnsPreferenceKey = 'transaction_export_columns_v1';

List<TransactionExportColumn> restoreTransactionExportColumns(
    List<String>? saved) {
  if (saved == null) return List.of(defaultTransactionExportColumns);
  final known = {
    for (final column in TransactionExportColumn.values) column.name: column
  };
  final result = <TransactionExportColumn>[];
  for (final id in saved) {
    final column = known[id];
    if (column != null && !result.contains(column)) result.add(column);
  }
  // Preserve an intentional empty selection, but recover from obsolete IDs.
  if (saved.isNotEmpty && result.isEmpty) {
    return List.of(defaultTransactionExportColumns);
  }
  return result;
}

List<TransactionExportColumn> validateTransactionExportColumns(
    List<TransactionExportColumn>? columns) {
  final result = List<TransactionExportColumn>.unmodifiable(
      columns ?? defaultTransactionExportColumns);
  if (result.isEmpty) {
    throw ArgumentError.value(columns, 'columns', 'Select at least one column');
  }
  if (result.toSet().length != result.length) {
    throw ArgumentError.value(columns, 'columns', 'Columns must be unique');
  }
  return result;
}
