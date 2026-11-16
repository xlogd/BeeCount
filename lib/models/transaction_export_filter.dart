enum TransactionExportType { all, expense, income, transfer }

/// Dates represent local calendar days. Both endpoints include the whole day.
class TransactionExportFilter {
  const TransactionExportFilter.all()
      : startDate = null,
        endDate = null,
        type = TransactionExportType.all,
        _endExclusive = null;

  TransactionExportFilter(
      {DateTime? startDate,
      DateTime? endDate,
      this.type = TransactionExportType.all})
      : startDate = _day(startDate),
        endDate = _day(endDate),
        _endExclusive = endDate == null
            ? null
            : DateTime(endDate.year, endDate.month, endDate.day + 1) {
    if (this.startDate != null &&
        this.endDate != null &&
        this.startDate!.isAfter(this.endDate!)) {
      throw ArgumentError('Export start date must not follow end date');
    }
  }

  final DateTime? startDate, endDate;
  final DateTime? _endExclusive;
  final TransactionExportType type;
  bool get hasDateRange => startDate != null || endDate != null;
  bool get isActive => hasDateRange || type != TransactionExportType.all;

  static DateTime? _day(DateTime? value) =>
      value == null ? null : DateTime(value.year, value.month, value.day);

  bool matches(
          {required DateTime happenedAt, required String transactionType}) =>
      (type == TransactionExportType.all || transactionType == type.name) &&
      (startDate == null || !happenedAt.isBefore(startDate!)) &&
      (_endExclusive == null || happenedAt.isBefore(_endExclusive));
}
