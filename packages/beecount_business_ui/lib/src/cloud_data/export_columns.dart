import 'package:beecount_ui/beecount_ui.dart';
import 'package:beecount_ui/multi_select.dart';
import 'package:flutter/material.dart';

class BeeExportColumnOption {
  const BeeExportColumnOption({required this.id, required this.label});
  final String id, label;
}

class BeeExportColumnLabels {
  const BeeExportColumnLabels({
    required this.title,
    required this.description,
    required this.selectionCount,
    required this.selectAll,
    required this.clear,
    required this.reset,
    required this.order,
    required this.moveUp,
    required this.moveDown,
    required this.emptySelection,
  });
  final String title, description, selectionCount, selectAll, clear, reset;
  final String order, moveUp, moveDown, emptySelection;
}

/// Controlled column selection and ordering; IDs never depend on translations.
class BeeExportColumns extends StatelessWidget {
  const BeeExportColumns({
    super.key,
    required this.options,
    required this.selectedIds,
    required this.labels,
    required this.onChanged,
  });
  final List<BeeExportColumnOption> options;
  final List<String> selectedIds;
  final BeeExportColumnLabels labels;
  final ValueChanged<List<String>>? onChanged;

  void _move(int from, int to) {
    final next = List<String>.of(selectedIds);
    next.insert(to, next.removeAt(from));
    onChanged?.call(List.unmodifiable(next));
  }

  @override
  Widget build(BuildContext context) {
    final byId = {for (final option in options) option.id: option};
    final selected = selectedIds.toSet();
    final enabled = onChanged != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(labels.title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Text(labels.description,
          style: TextStyle(
              fontSize: 12, height: 1.5, color: Theme.of(context).hintColor)),
      const SizedBox(height: 8),
      Text(labels.selectionCount, style: const TextStyle(fontSize: 12)),
      Wrap(spacing: 4, children: [
        TextButton(
            key: const ValueKey('export-columns-all'),
            onPressed: enabled && selectedIds.length < options.length
                ? () => onChanged!([
                      ...selectedIds,
                      for (final option in options)
                        if (!selected.contains(option.id)) option.id
                    ])
                : null,
            child: Text(labels.selectAll)),
        TextButton(
            key: const ValueKey('export-columns-clear'),
            onPressed: enabled && selectedIds.isNotEmpty
                ? () => onChanged!(const [])
                : null,
            child: Text(labels.clear)),
        TextButton(
            key: const ValueKey('export-columns-reset'),
            onPressed: enabled
                ? () => onChanged!(options.map((option) => option.id).toList())
                : null,
            child: Text(labels.reset)),
      ]),
      BeeMultiSelect<String>(
          selectedValues: selected,
          options: [
            for (final option in options)
              BeeMultiSelectOption(
                  key: ValueKey('export-column-${option.id}'),
                  value: option.id,
                  label: option.label)
          ],
          onChanged: !enabled
              ? null
              : (next) => onChanged!([
                    for (final id in selectedIds)
                      if (next.contains(id)) id,
                    for (final option in options)
                      if (next.contains(option.id) &&
                          !selected.contains(option.id))
                        option.id,
                  ])),
      if (selectedIds.isEmpty) ...[
        const SizedBox(height: 12),
        Semantics(
            liveRegion: true,
            child: Text(labels.emptySelection,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).colorScheme.error))),
      ] else ...[
        const SizedBox(height: 12),
        ExpansionTile(
            key: const ValueKey('export-columns-order'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(labels.order, style: const TextStyle(fontSize: 14)),
            subtitle: Text(selectedIds.map((id) => byId[id]!.label).join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
            children: [
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: selectedIds.length,
                onReorder: (from, to) {
                  if (enabled) _move(from, to > from ? to - 1 : to);
                },
                itemBuilder: (context, index) {
                  final option = byId[selectedIds[index]]!;
                  return SizedBox(
                      key: ValueKey('export-column-order-${option.id}'),
                      child: Row(children: [
                        SizedBox(
                            width: 28,
                            child: Text('${index + 1}',
                                style: TextStyle(
                                    color: Theme.of(context).hintColor))),
                        Expanded(
                            child: Text(option.label,
                                style: const TextStyle(fontSize: 13))),
                        IconButton(
                            key: ValueKey('export-column-up-${option.id}'),
                            tooltip: '${labels.moveUp}: ${option.label}',
                            constraints: const BoxConstraints.tightFor(
                                width: 36, height: 44),
                            padding: EdgeInsets.zero,
                            icon: const BeeLineIcon('ChevronUp', size: 20),
                            onPressed: enabled && index > 0
                                ? () => _move(index, index - 1)
                                : null),
                        IconButton(
                            key: ValueKey('export-column-down-${option.id}'),
                            tooltip: '${labels.moveDown}: ${option.label}',
                            constraints: const BoxConstraints.tightFor(
                                width: 36, height: 44),
                            padding: EdgeInsets.zero,
                            icon: const BeeLineIcon('ChevronDown', size: 20),
                            onPressed: enabled && index < selectedIds.length - 1
                                ? () => _move(index, index + 1)
                                : null),
                        ReorderableDragStartListener(
                            index: index,
                            enabled: enabled,
                            child: const SizedBox(
                                width: 32,
                                height: 44,
                                child: BeeLineIcon('GripVertical', size: 20))),
                      ]));
                },
              )
            ]),
      ],
    ]);
  }
}
