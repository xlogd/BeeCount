import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/document_flatten_service.dart';

Future<List<File>?> reviewDocumentPages(
    BuildContext context, List<File> files, DocumentFlattenService service) {
  assert(files.isNotEmpty);
  return Navigator.of(context).push<List<File>>(MaterialPageRoute(
      builder: (_) => _DocumentFlattenPage(files: files, service: service)));
}

class _DocumentFlattenPage extends StatefulWidget {
  const _DocumentFlattenPage({required this.files, required this.service});

  final List<File> files;
  final DocumentFlattenService service;

  @override
  State<_DocumentFlattenPage> createState() => _DocumentFlattenPageState();
}

class _DocumentFlattenPageState extends State<_DocumentFlattenPage> {
  final _results = <int, File>{};
  final _selected = <int>{};
  final _failed = <int>{};
  var _page = 0;
  var _busy = false;
  var _confirmed = false;

  Future<void> _flatten() async {
    if (_busy) return;
    final page = _page;
    setState(() {
      _busy = true;
      _failed.remove(page);
    });
    try {
      final result = await widget.service.flatten(widget.files[page]);
      if (!mounted) {
        await discardFlattenedPreview(result);
        return;
      }
      setState(() {
        _results[page] = result;
        _selected.add(page);
      });
    } catch (_) {
      if (mounted) setState(() => _failed.add(page));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _confirm() {
    if (_busy) return;
    _confirmed = true;
    Navigator.of(context).pop([
      for (var i = 0; i < widget.files.length; i++)
        _selected.contains(i) ? _results[i]! : widget.files[i],
    ]);
  }

  @override
  void dispose() {
    for (final entry in _results.entries) {
      if (!_confirmed || !_selected.contains(entry.key)) {
        unawaited(discardFlattenedPreview(entry.value));
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final result = _results[_page];
    final useFlattened = _selected.contains(_page);
    final file = useFlattened ? result! : widget.files[_page];
    return Scaffold(
      appBar: AppBar(title: Text(l.documentFlattenReview)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerLowest,
                child: Center(
                  child: InteractiveViewer(
                    key: ValueKey(file.path),
                    child: Image.file(file,
                        key: const ValueKey('document-flatten-preview'),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            Text(l.documentFlattenFailed)),
                  ),
                ),
              ),
            ),
            if (widget.files.length > 1)
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                    tooltip: l.commonPrevious,
                    onPressed: _busy || _page == 0
                        ? null
                        : () => setState(() => _page--),
                    icon: const Icon(Icons.navigate_before)),
                Text('${_page + 1} / ${widget.files.length}'),
                IconButton(
                    tooltip: l.commonNext,
                    onPressed: _busy || _page == widget.files.length - 1
                        ? null
                        : () => setState(() => _page++),
                    icon: const Icon(Icons.navigate_next)),
              ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(l.documentFlattenProcessing,
                        textAlign: TextAlign.center),
                  ] else if (result == null)
                    OutlinedButton.icon(
                      key: const ValueKey('document-flatten-run'),
                      onPressed: _flatten,
                      icon: const Icon(Icons.auto_fix_high_outlined),
                      label: Text(l.documentFlattenAction),
                    )
                  else
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                            value: false,
                            label: Text(l.documentFlattenOriginal)),
                        ButtonSegment(
                            value: true, label: Text(l.documentFlattenResult)),
                      ],
                      selected: {useFlattened},
                      onSelectionChanged: (value) => setState(() {
                        if (value.single) {
                          _selected.add(_page);
                        } else {
                          _selected.remove(_page);
                        }
                      }),
                    ),
                  if (_failed.contains(_page))
                    Text(l.documentFlattenFailed,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const ValueKey('document-flatten-confirm'),
                    onPressed: _busy ? null : _confirm,
                    child: Text(l.commonConfirm),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
