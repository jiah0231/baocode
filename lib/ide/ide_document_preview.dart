import 'dart:async';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'document/document_model.dart';
import 'document/document_parser.dart' show parseDocumentPreview;
import 'document/document_read.dart';
import 'document/document_strings.dart';
import 'document/document_view.dart';
import 'file_service.dart';
import 'ide_button.dart';
import 'ide_hover.dart';
import 'ide_spinning.dart';

/// Office documents are parsed in memory, without a browser, network requests,
/// macros, formula evaluation or writes to the source file. A stale read cannot
/// replace the document selected after it.
class IdeDocumentPreview extends StatefulWidget {
  const IdeDocumentPreview({
    super.key,
    required this.path,
    this.files,
    this.read,
    this.onOpenInDefaultApp,
    this.revision = 0,
    this.historical = false,
  });

  final String path;
  final IdeFileService? files;
  final Future<Uint8List> Function(String path)? read;
  final VoidCallback? onOpenInDefaultApp;
  final int revision;

  /// A text-only Git revision must not silently show the working copy instead.
  final bool historical;

  @override
  State<IdeDocumentPreview> createState() => _IdeDocumentPreviewState();
}

DocumentPreviewData _parse(({String path, Uint8List bytes}) input) =>
    parseDocumentPreview(path: input.path, bytes: input.bytes);

// A bounded document can still produce a sizeable XML tree. Serialize the
// bounded read AND parse across panes, so cancelled queued work holds no bytes
// and only one parser isolate is active even during rapid tab switches.
// Do not retain a completed Future: late listeners run in that Future's zone,
// which may no longer be active when the next preview is opened.
Future<void>? _parseQueue;

Future<DocumentPreviewData> _readAndParseInOrder({
  required String path,
  IdeFileService? files,
  Future<Uint8List> Function(String)? read,
  required Future<void> cancel,
  required bool Function() current,
}) {
  void check() {
    if (!current()) {
      throw const DocumentParseException(
        'Preview cancelled.',
        code: 'cancelled',
      );
    }
  }

  final previous = _parseQueue;
  final released = Completer<void>();
  final gate = released.future;
  _parseQueue = gate;

  Future<DocumentPreviewData> run() async {
    try {
      if (previous != null) await previous;
      check();
      final bytes = await readDocumentBytes(
        path,
        files: files,
        read: read,
        cancel: cancel,
      );
      check();
      return await compute(_parse, (path: path, bytes: bytes));
    } finally {
      // Release the idle queue before returning a result to the UI. Queued
      // work still waits for this gate, even when this load fails or is stale.
      if (identical(_parseQueue, gate)) _parseQueue = null;
      released.complete();
    }
  }

  return run();
}

class _IdeDocumentPreviewState extends State<IdeDocumentPreview> {
  DocumentPreviewData? _data;
  Object? _error;
  int _generation = 0;
  Completer<void>? _cancel;
  int _section = 0;
  int _sheet = 0;
  double _zoom = 1;
  bool _originalColors = false;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(IdeDocumentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.files != widget.files ||
        oldWidget.read != widget.read ||
        oldWidget.revision != widget.revision ||
        oldWidget.historical != widget.historical) {
      _section = 0;
      _sheet = 0;
      _zoom = 1;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    _cancel?.complete();
    _cancel = null;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    setState(() {
      _data = null;
      _error = null;
    });
    if (widget.historical ||
        documentKindForPath(widget.path) == DocumentKind.legacy) {
      return;
    }
    try {
      final data = await _readAndParseInOrder(
        path: widget.path,
        files: widget.files,
        read: widget.read,
        cancel: cancel.future,
        current: () => mounted && generation == _generation,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = data;
        _section = _section
            .clamp(0, (data.sections.length - 1).clamp(0, 100000))
            .toInt();
        _sheet = _sheet
            .clamp(0, (data.sheets.length - 1).clamp(0, 100000))
            .toInt();
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = error);
    }
  }

  void _go(int delta) {
    final count = _data?.sections.length ?? 0;
    if (count == 0) return;
    setState(() => _section = (_section + delta).clamp(0, count - 1).toInt());
  }

  @override
  Widget build(BuildContext context) {
    final strings = DocumentStrings(context);
    final data = _data;
    final presentation = data?.kind == DocumentKind.presentation;
    return ColoredBox(
      color: AppColors.code,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: AppColors.text, fontSize: 13),
        child: Focus(
          onKeyEvent: (node, event) {
            if (!presentation ||
                event is! KeyDownEvent ||
                HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed ||
                HardwareKeyboard.instance.isAltPressed) {
              return KeyEventResult.ignored;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                event.logicalKey == LogicalKeyboardKey.pageDown) {
              _go(1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                event.logicalKey == LogicalKeyboardKey.pageUp) {
              _go(-1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border(
                    bottom: BorderSide(color: AppColors.partBorder),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      strings.readOnly,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    if (data != null) ...[
                      _button(
                        strings.zoomOut,
                        Codicons.remove,
                        _zoom <= .5
                            ? null
                            : () => setState(
                                () => _zoom = (_zoom - .1)
                                    .clamp(.5, 2)
                                    .toDouble(),
                              ),
                      ),
                      _button(
                        '${(_zoom * 100).round()}%',
                        null,
                        () => setState(() => _zoom = 1),
                        tip: strings.fit,
                      ),
                      _button(
                        strings.zoomIn,
                        Codicons.add,
                        _zoom >= 2
                            ? null
                            : () => setState(
                                () => _zoom = (_zoom + .1)
                                    .clamp(.5, 2)
                                    .toDouble(),
                              ),
                      ),
                      if (data.sheets.isEmpty)
                        _button(
                          _originalColors ? strings.themed : strings.original,
                          Codicons.colorMode,
                          () => setState(
                            () => _originalColors = !_originalColors,
                          ),
                        ),
                      if (presentation) ...[
                        _button(
                          strings.previous,
                          Codicons.chevronLeft,
                          _section == 0 ? null : () => _go(-1),
                        ),
                        Text(strings.page(_section + 1, data.sections.length)),
                        _button(
                          strings.next,
                          Codicons.chevronRight,
                          _section + 1 >= data.sections.length
                              ? null
                              : () => _go(1),
                        ),
                        _button(
                          _reading ? strings.layout : strings.reading,
                          Codicons.book,
                          () => setState(() => _reading = !_reading),
                        ),
                      ],
                    ],
                    _button(
                      strings.reload,
                      Codicons.refresh,
                      () => unawaited(_load()),
                    ),
                    if (widget.onOpenInDefaultApp != null)
                      _button(
                        strings.openExternal,
                        Codicons.linkExternal,
                        widget.onOpenInDefaultApp,
                      ),
                  ],
                ),
              ),
              Expanded(child: _body(context, strings)),
              if (data != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    border: Border(
                      top: BorderSide(color: AppColors.partBorder),
                    ),
                  ),
                  child: IdeHover(
                    message: [
                      strings.fidelity,
                      ...data.warnings.map(strings.warning),
                    ].join('\n'),
                    child: Text(
                      data.warnings.isEmpty
                          ? strings.fidelity
                          : data.warnings.map(strings.warning).join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button(
    String label,
    IconData? icon,
    VoidCallback? action, {
    String? tip,
  }) {
    final button = IdeButton(
      label: label,
      icon: icon,
      secondary: true,
      onPressed: action,
    );
    return tip == null ? button : IdeHover(message: tip, child: button);
  }

  Widget _body(BuildContext context, DocumentStrings strings) {
    if (widget.historical) return _message(strings.revision);
    if (documentKindForPath(widget.path) == DocumentKind.legacy) {
      return _message(strings.legacy);
    }
    final error = _error;
    if (error != null) {
      return _message(
        error is DocumentParseException
            ? strings.parseError(error.code, error.message)
            : strings.readError,
        retry: true,
      );
    }
    final data = _data;
    if (data == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IdeSpinning(Icon(Codicons.loading, color: AppColors.textMuted)),
            const SizedBox(height: 10),
            Text(strings.loading),
          ],
        ),
      );
    }
    if (data.sheets.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                for (var i = 0; i < data.sheets.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: IdeButton(
                      label: data.sheets[i].name,
                      secondary: _sheet != i,
                      onPressed: () => setState(() => _sheet = i),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: DocumentSheetView(
              key: ValueKey((widget.path, _sheet)),
              sheet: data.sheets[_sheet],
              zoom: _zoom,
            ),
          ),
        ],
      );
    }
    if (data.sections.isEmpty) return _message(strings.empty);
    if (data.kind == DocumentKind.presentation) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final section = data.sections[_section];
          return Row(
            children: [
              if (constraints.maxWidth >= 600)
                Container(
                  width: 158,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    border: Border(
                      right: BorderSide(color: AppColors.partBorder),
                    ),
                  ),
                  child: ListView.builder(
                    itemCount: data.sections.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: IdeButton(
                        label: '${index + 1}  ${data.sections[index].title}',
                        secondary: _section != index,
                        onPressed: () => setState(() => _section = index),
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: DocumentSectionView(
                  key: ValueKey((widget.path, _section, _reading)),
                  section: section,
                  zoom: _zoom,
                  originalColors: _originalColors,
                  slideLayout: !_reading,
                ),
              ),
            ],
          );
        },
      );
    }
    return DocumentFlowView(
      key: PageStorageKey(('document', widget.path)),
      sections: data.sections,
      zoom: _zoom,
      originalColors: _originalColors,
    );
  }

  Widget _message(String message, {bool retry = false}) {
    final strings = DocumentStrings(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Codicons.file, size: 40, color: AppColors.textMuted),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (retry) ...[
                const SizedBox(height: 14),
                IdeButton(
                  label: strings.retry,
                  onPressed: () => unawaited(_load()),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
