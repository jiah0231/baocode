import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ide/ide_button.dart';
import '../ide/ide_input.dart';
import '../ide/ide_menu.dart';
import '../l10n/l10n.dart';
import '../theme/workbench_theme.dart';
import '../usage/usage_ledger.dart';
import '../workspace/window_controls.dart';
import 'translation_host.dart';
import 'translation_service.dart';
import 'translation_strings.dart';

final _openTranslationViews = <Object>{};

Future<void> showTranslationDialog(
  BuildContext context, {
  String selectedText = '',
  String? captureStatus,
  TranslationService? service,
  VoidCallback? onModelSettings,
  bool preferFloating = true,
}) async {
  if (preferFloating &&
      await TranslationHost.instance.openPanel(
        TranslationCapture(
          text: selectedText,
          status: captureStatus ?? 'ok',
          inApp: true,
        ),
        onModelSettings: onModelSettings,
      )) {
    return;
  }
  if (!context.mounted) return;
  final view = View.of(context);
  if (!_openTranslationViews.add(view)) return;
  try {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: context.l10n.translationClose,
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (context, _, _) => TranslationDialog(
        selectedText: selectedText,
        captureStatus: captureStatus,
        service: service,
        onModelSettings: onModelSettings,
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  } finally {
    _openTranslationViews.remove(view);
  }
}

/// Compact, dependency-free translation panel. Nothing is submitted on open,
/// selection capture, typing or language changes. Closing destroys its state.
class TranslationDialog extends StatefulWidget {
  const TranslationDialog({
    super.key,
    this.selectedText = '',
    this.captureStatus,
    this.captureWarning,
    this.service,
    this.onModelSettings,
    this.onClose,
    this.embedded = false,
    this.active = true,
    this.onRendered,
  });
  final String selectedText;
  final bool embedded;

  /// A native panel may receive focus only after its host confirms it is shown.
  final bool active;
  final VoidCallback? onRendered;

  /// 'tooLong' means the capture was truncated: discard it, never translate a
  /// clipped selection. Any other non-null status shows manual-entry guidance.
  final String? captureStatus;
  final String? captureWarning;
  final TranslationService? service;
  final VoidCallback? onModelSettings;
  final VoidCallback? onClose;
  @override
  State<TranslationDialog> createState() => _TranslationDialogState();
}

class _TranslationDialogState extends State<TranslationDialog> {
  late final _service = widget.service ?? TranslationService();
  late final _input = TextEditingController(
    text: widget.captureStatus == 'tooLong' ? '' : widget.selectedText,
  );
  final _sourceFocus = FocusNode(debugLabel: 'Translation source');
  String _source = 'auto';
  String _target = 'zh';
  String _answer = '';
  TranslationFailure? _error;
  bool _busy = false;
  bool _copied = false;
  bool _copyFailed = false;
  bool _edited = false;
  int _generation = 0;
  Completer<void>? _cancel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onRendered?.call();
      _focusActivePanel();
    });
  }

  void _focusActivePanel() {
    if (mounted && widget.embedded && widget.active) {
      _sourceFocus.requestFocus();
    }
  }

  @override
  void didUpdateWidget(TranslationDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      // Wait for the host's ExcludeFocus to permit the panel's subtree again.
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusActivePanel());
    }
  }

  @override
  void dispose() {
    _stop();
    _input.dispose();
    _sourceFocus.dispose();
    super.dispose();
  }

  void _stop() {
    _generation++;
    if (_cancel?.isCompleted == false) _cancel!.complete();
    _cancel = null;
  }

  void _change(VoidCallback change) {
    _stop();
    setState(() {
      change();
      _busy = false;
      _answer = '';
      _error = null;
      _copied = false;
      _copyFailed = false;
    });
  }

  void _close() {
    _stop();
    widget.onClose?.call();
  }

  Future<void> _translate() async {
    _stop();
    final generation = _generation;
    final cancel = Completer<void>();
    _cancel = cancel;
    setState(() {
      _busy = true;
      _answer = '';
      _error = null;
      _copied = false;
      _copyFailed = false;
    });
    try {
      final result = await _service.translate(
        text: _input.text,
        source: _source,
        target: _target,
        cancel: cancel.future,
        onText: (value) {
          if (mounted && generation == _generation) {
            setState(() => _answer = value);
          }
        },
      );
      if (mounted && generation == _generation) {
        setState(() => _answer = result);
      }
    } on TranslationCancelled {
      // Closing or editing invalidates this result.
    } on TranslationException catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error.reason;
          _answer = '';
        });
      }
    } on Object {
      if (mounted && generation == _generation) {
        setState(() {
          _error = TranslationFailure.requestFailed;
          _answer = '';
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: _answer));
      if (mounted) {
        setState(() {
          _copied = true;
          _copyFailed = false;
        });
      }
    } on Object {
      if (mounted) setState(() => _copyFailed = true);
    }
  }

  Widget _language(bool source) => Builder(
    builder: (context) {
      final code = source ? _source : _target;
      return IdeButton(
        label: context.l10n.translationLanguage(code),
        secondary: true,
        onPressed: () {
          final box = context.findRenderObject()! as RenderBox;
          showIdeMenu(
            context,
            anchor: box.localToGlobal(Offset.zero) & box.size,
            entries: [
              for (final language in translationLanguages)
                if (source || language != 'auto')
                  IdeMenuAction(
                    context.l10n.translationLanguage(language),
                    checked: code == language,
                    onSelected: () => _change(() {
                      if (source) {
                        _source = language;
                      } else {
                        _target = language;
                      }
                    }),
                  ),
            ],
          );
        },
      );
    },
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      WorkbenchThemeService.instance,
      _service.providers,
      UsageLedger.current,
    ]),
    builder: (context, _) {
      final l = context.l10n;
      String? model;
      try {
        model = _service.destination.label;
      } on TranslationException {
        /* Safe configuration message below. */
      }
      final tooLong =
          _input.text.length > translationSourceLimit ||
          (!_edited && widget.captureStatus == 'tooLong');
      final error = tooLong ? TranslationFailure.sourceTooLong : _error;
      final restoreFailed =
          widget.captureStatus == 'clipboardRestoreFailed' ||
          widget.captureWarning == 'clipboardRestoreFailed';
      final viewport = MediaQuery.sizeOf(context);
      return CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(widget.embedded ? 0 : 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: widget.embedded ? double.infinity : 720,
                  minHeight: widget.embedded ? viewport.height : 0,
                  maxHeight: widget.embedded
                      ? viewport.height
                      : math.max(100, viewport.height - 48),
                ),
                child: Material(
                  color: themeColors['editorWidget.background'],
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: themeColors['editorWidget.border']),
                  ),
                  elevation: widget.embedded ? 0 : 12,
                  clipBehavior: Clip.antiAlias,
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                      fontSize: 13,
                      height: 1.5,
                      color: themeColors['foreground'],
                    ),
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(widget.embedded ? 12 : 18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanStart: widget.embedded
                                      ? (_) => unawaited(
                                          WindowControls.dragWindow(
                                            viewId: View.of(context).viewId,
                                          ),
                                        )
                                      : null,
                                  child: Text(
                                    l.translationTitle,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                              IdeButton(
                                label: l.translationClose,
                                secondary: true,
                                onPressed: _close,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            model ??
                                l.translationError(TranslationFailure.noModel),
                            style: TextStyle(
                              fontSize: 11,
                              color: themeColors['descriptionForeground'],
                            ),
                          ),
                          SizedBox(height: widget.embedded ? 8 : 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _language(true),
                              IdeButton(
                                label: l.translationSwap,
                                secondary: true,
                                onPressed: _source == 'auto'
                                    ? null
                                    : () => _change(() {
                                        final previous = _source;
                                        _source = _target;
                                        _target = previous;
                                        if (_answer.isNotEmpty) {
                                          _input.text = _answer;
                                          _edited = true;
                                        }
                                      }),
                              ),
                              _language(false),
                            ],
                          ),
                          SizedBox(height: widget.embedded ? 10 : 14),
                          if (restoreFailed ||
                              (!_edited &&
                                  widget.captureStatus != null &&
                                  widget.captureStatus != 'ok' &&
                                  !tooLong)) ...[
                            Text(
                              restoreFailed
                                  ? l.translationClipboardRestoreFailed
                                  : l.translationNoSelection,
                              style: TextStyle(
                                color:
                                    themeColors[restoreFailed
                                        ? 'errorForeground'
                                        : 'descriptionForeground'],
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final source = Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(l.translationSource),
                                      ),
                                      Text(
                                        '${_input.text.length} / $translationSourceLimit',
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  IdeInputBox(
                                    key: const ValueKey('translation-source'),
                                    controller: _input,
                                    focusNode: _sourceFocus,
                                    autofocus: !widget.embedded,
                                    semanticsLabel: l.translationSource,
                                    placeholder: l.translationPlaceholder,
                                    minLines: widget.embedded ? 3 : 7,
                                    maxLines: widget.embedded ? 6 : 10,
                                    padding: EdgeInsets.all(
                                      widget.embedded ? 8 : 10,
                                    ),
                                    onChanged: (_) =>
                                        _change(() => _edited = true),
                                  ),
                                ],
                              );
                              final result = Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    _busy
                                        ? l.translationWorking
                                        : l.translationResult,
                                  ),
                                  const SizedBox(height: 6),
                                  Container(
                                    height: widget.embedded ? 120 : 200,
                                    padding: EdgeInsets.all(
                                      widget.embedded ? 8 : 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: themeColors['input.background'],
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: SingleChildScrollView(
                                      child: SelectableText(
                                        _answer.isEmpty
                                            ? l.translationWaiting
                                            : _answer,
                                        key: const ValueKey(
                                          'translation-result',
                                        ),
                                        style: TextStyle(
                                          color:
                                              themeColors[_answer.isEmpty
                                                  ? 'descriptionForeground'
                                                  : 'foreground'],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                              return constraints.maxWidth < 520
                                  ? Column(
                                      children: [
                                        source,
                                        SizedBox(
                                          height: widget.embedded ? 10 : 14,
                                        ),
                                        result,
                                      ],
                                    )
                                  : Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(child: source),
                                        const SizedBox(width: 16),
                                        Expanded(child: result),
                                      ],
                                    );
                            },
                          ),
                          if (error != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              l.translationError(error),
                              style: TextStyle(
                                color: themeColors['errorForeground'],
                              ),
                            ),
                          ],
                          if (_copyFailed) Text(l.translationCopyFailed),
                          SizedBox(height: widget.embedded ? 10 : 14),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              IdeButton(
                                label: _busy
                                    ? l.translationCancel
                                    : _error != null
                                    ? l.translationRetry
                                    : l.translationTitle,
                                onPressed: _busy
                                    ? () => _change(() {})
                                    : tooLong || model == null
                                    ? null
                                    : _translate,
                              ),
                              IdeButton(
                                label: _copied
                                    ? l.translationCopied
                                    : l.translationCopy,
                                secondary: true,
                                onPressed: _busy || _answer.isEmpty
                                    ? null
                                    : _copy,
                              ),
                              if (widget.onModelSettings != null)
                                IdeButton(
                                  label: l.translationModel,
                                  secondary: true,
                                  onPressed: () {
                                    _close();
                                    widget.onModelSettings?.call();
                                  },
                                ),
                            ],
                          ),
                          SizedBox(height: widget.embedded ? 8 : 12),
                          Text(
                            l.translationPrivacy,
                            style: TextStyle(
                              fontSize: 11,
                              color: themeColors['descriptionForeground'],
                            ),
                          ),
                          Text(
                            l.translationModelHint,
                            style: TextStyle(
                              fontSize: 11,
                              color: themeColors['descriptionForeground'],
                            ),
                          ),
                          if (UsageLedger.current.enabled &&
                              UsageLedger.current.trace)
                            Text(
                              l.translationTraceWarning,
                              style: TextStyle(
                                color: themeColors['errorForeground'],
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
