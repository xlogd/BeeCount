import 'package:beecount_ui/beecount_ui.dart';
import 'package:flutter/material.dart';

class BeeExportTypeOption {
  const BeeExportTypeOption({required this.id, required this.label});
  final String id, label;
}

/// Controlled export scope; the App owns date picking and record filtering.
class BeeExportFilters extends StatelessWidget {
  const BeeExportFilters(
      {super.key,
      required this.title,
      required this.dateLabel,
      required this.dateValue,
      required this.dateHint,
      required this.clearDatesLabel,
      required this.typeLabel,
      required this.options,
      required this.selectedType,
      required this.onPickDates,
      required this.onClearDates,
      required this.onTypeChanged});

  final String title,
      dateLabel,
      dateValue,
      dateHint,
      clearDatesLabel,
      typeLabel;
  final List<BeeExportTypeOption> options;
  final String selectedType;
  final VoidCallback? onPickDates, onClearDates;
  final ValueChanged<String>? onTypeChanged;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        BeeMenuRow(
            key: const ValueKey('export-date-range'),
            title: dateLabel,
            subtitle: dateValue,
            leading: const BeeLineIcon('CalendarDays', size: 20),
            onTap: onPickDates),
        Text(dateHint,
            style: TextStyle(
                fontSize: 12, height: 1.5, color: Theme.of(context).hintColor)),
        Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
                key: const ValueKey('export-clear-dates'),
                onPressed: onClearDates,
                child: Text(clearDatesLabel))),
        const SizedBox(height: 8),
        Text(typeLabel,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final option in options)
            ChoiceChip(
                key: ValueKey('export-type-${option.id}'),
                label: Text(option.label),
                selected: selectedType == option.id,
                onSelected: onTypeChanged == null
                    ? null
                    : (selected) {
                        if (selected) onTypeChanged!(option.id);
                      }),
        ]),
      ]);
}
