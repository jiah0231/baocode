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
import 'translation_confirmation.dart';
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

/// A hotkey/manual opening is a preview. A validated explicit selection-entry
/// click can submit once, after the native panel is visible. Passive selection,
/// typing and language changes never submit. Closing destroys its state.
class TranslationDialog extends StatefulWidget {
  const TranslationDialog({
    super.key,
    this.selectedText = '',
    this.capture,
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
  final TranslationCapture? capture;
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
  // The host keys each new request by generation. Rebuilding/updating an old
  // view cannot upgrade its original preview into a new click authorization.
  late final _capture = widget.capture;
  String? get _captureStatus => _capture?.status ?? widget.captureStatus;
  late final _input = TextEditingController(
    text: _capture != null
        ? (_capture.status == 'ok' ? _capture.text : '')
        : widget.captureStatus == 'tooLong'
        ? ''
        : widget.selectedText,
  );
  bool _autoAttempted = false;
  bool _entrySubmitted = false;
  bool get _reviewNeeded =>
      _capture?.requiresConfirmation == true ||
      translationNeedsReview(_input.text);
  final _resultScroll = ScrollController();
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
      _maybeTranslateEntry();
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusActivePanel();
        _maybeTranslateEntry();
      });
    }
  }

  void _maybeTranslateEntry() {
    if (!mounted || !widget.embedded || !widget.active || _autoAttempted) {
      return;
    }
    _autoAttempted = true;
    if (_capture?.requestsImmediateTranslation != true ||
        _edited ||
        _input.text != _capture!.text ||
        _reviewNeeded ||
        (UsageLedger.current.enabled && UsageLedger.current.trace)) {
      return;
    }
    try {
      // Never auto-send later merely because model setup changes.
      _service.destination;
    } on TranslationException {
      return;
    }
    _entrySubmitted = true;
    unawaited(_translate());
  }

  @override
  void dispose() {
    _stop();
    _resultScroll.dispose();
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
    _autoAttempted = true;
    _stop();
    setState(() {
      change();
      _entrySubmitted = false;
      _busy = false;
      _answer = '';
      _error = null;
      _copied = false;
      _copyFailed = false;
    });
  }

  void _close() {
    _autoAttempted = true;
    _stop();
    widget.onClose?.call();
  }

  Future<void> _translate() async {
    _autoAttempted = true;
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

  /// The native popup has a fixed chrome and independent bounded text regions.
  /// Streaming only rebuilds the result; it never changes the reader's offset.
  Widget _compactContent({
    required String? model,
    required bool tooLong,
    required TranslationFailure? error,
    required bool restoreFailed,
  }) {
    final l = context.l10n;
    final largeText = MediaQuery.textScalerOf(context).scale(13) > 20;
    final notices = <String>[
      if (model == null) l.translationError(TranslationFailure.noModel),
      if (restoreFailed)
        l.translationClipboardRestoreFailed
      else if (!_edited &&
          _captureStatus != null &&
          _captureStatus != 'ok' &&
          !tooLong)
        l.translationNoSelection,
      if (_capture?.requestsImmediateTranslation == true && _reviewNeeded)
        l.translationReviewRequired(model ?? l.translationModel),
      if (error != null) l.translationError(error),
      if (_copyFailed) l.translationCopyFailed,
      if (UsageLedger.current.enabled && UsageLedger.current.trace)
        _capture?.requestsImmediateTranslation == true && !_entrySubmitted
            ? '${l.translationAutoTracePaused} ${l.translationTraceWarning}'
            : l.translationTraceWarning,
    ];
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => unawaited(
                    WindowControls.dragWindow(viewId: View.of(context).viewId),
                  ),
                  child: Text(
                    l.translationTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Tooltip(
                message:
                    '${model ?? l.translationModel}\n${l.translationPrivacy}\n${l.translationModelHint}',
                triggerMode: TooltipTriggerMode.tap,
                child: Semantics(
                  label:
                      '${model ?? l.translationModel}. ${l.translationPrivacy} ${l.translationModelHint}',
                  button: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: SizedBox(
                      width: largeText ? 72 : 140,
                      child: Text(
                        model ?? l.translationModel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: themeColors['descriptionForeground'],
                        ),
                      ),
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
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _language(true),
                const SizedBox(width: 6),
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
                const SizedBox(width: 6),
                _language(false),
              ],
            ),
          ),
          const SizedBox(height: 4),
          if (!largeText)
            Row(
              children: [
                Expanded(
                  child: Text(
                    l.translationSource,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                Text(
                  '${_input.text.length} / $translationSourceLimit',
                  style: TextStyle(
                    fontSize: 10,
                    color: themeColors['descriptionForeground'],
                  ),
                ),
              ],
            ),
          IdeInputBox(
            key: const ValueKey('translation-source'),
            controller: _input,
            focusNode: _sourceFocus,
            semanticsLabel: l.translationSource,
            placeholder: l.translationPlaceholder,
            minLines: largeText ? 1 : 2,
            maxLines: largeText ? 1 : 2,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            onChanged: (_) => _change(() => _edited = true),
          ),
          const SizedBox(height: 4),
          Text(
            _busy ? l.translationWorking : l.translationResult,
            style: const TextStyle(fontSize: 11),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: themeColors['input.background'],
                borderRadius: BorderRadius.circular(4),
              ),
              child: Scrollbar(
                controller: _resultScroll,
                child: SingleChildScrollView(
                  key: const ValueKey('translation-result-scroll'),
                  controller: _resultScroll,
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final notice in notices)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            notice,
                            style: TextStyle(
                              color: themeColors['errorForeground'],
                            ),
                          ),
                        ),
                      if (_entrySubmitted)
                        Text(
                          l.translationEntrySubmitted,
                          style: TextStyle(
                            fontSize: 11,
                            color: themeColors['descriptionForeground'],
                          ),
                        ),
                      SelectableText(
                        _answer.isEmpty ? l.translationWaiting : _answer,
                        key: const ValueKey('translation-result'),
                        style: TextStyle(
                          color:
                              themeColors[_answer.isEmpty
                                  ? 'descriptionForeground'
                                  : 'foreground'],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Builder(
            builder: (context) {
              final actions = <Widget>[
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
                const SizedBox(width: 6),
                IdeButton(
                  label: _copied ? l.translationCopied : l.translationCopy,
                  secondary: true,
                  onPressed: _busy || _answer.isEmpty ? null : _copy,
                ),
                if (widget.onModelSettings != null) ...[
                  const SizedBox(width: 6),
                  IdeButton(
                    label: l.translationModel,
                    secondary: true,
                    onPressed: () {
                      _close();
                      widget.onModelSettings?.call();
                    },
                  ),
                ],
              ];
              if (largeText) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: actions),
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (final action in actions)
                    if (action is SizedBox) action else Expanded(child: action),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

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
          (!_edited && _captureStatus == 'tooLong');
      final error = tooLong ? TranslationFailure.sourceTooLong : _error;
      final restoreFailed =
          _captureStatus == 'clipboardRestoreFailed' ||
          widget.captureWarning == 'clipboardRestoreFailed';
      final viewport = MediaQuery.sizeOf(context);
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          if (widget.embedded) ...{
            const SingleActivator(LogicalKeyboardKey.f4, alt: true): _close,
            const SingleActivator(LogicalKeyboardKey.keyW, control: true):
                _close,
            const SingleActivator(
              LogicalKeyboardKey.keyW,
              control: true,
              shift: true,
            ): _close,
          },
        },
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
                    child: widget.embedded
                        ? _compactContent(
                            model: model,
                            tooLong: tooLong,
                            error: error,
                            restoreFailed: restoreFailed,
                          )
                        : SingleChildScrollView(
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
                                                  viewId: View.of(context)
                                                      .viewId,
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
                                      l.translationError(
                                        TranslationFailure.noModel,
                                      ),
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
                                        _captureStatus != null &&
                                        _captureStatus != 'ok' &&
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(l.translationSource),
                                            ),
                                            Text(
                                              '${_input.text.length} / $translationSourceLimit',
                                              style: const TextStyle(
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        IdeInputBox(
                                          key: const ValueKey(
                                            'translation-source',
                                          ),
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
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
                                            color:
                                                themeColors['input.background'],
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
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
                                                height: widget.embedded
                                                    ? 10
                                                    : 14,
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
                                if (_capture?.requestsImmediateTranslation ==
                                        true &&
                                    _reviewNeeded) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    l.translationReviewRequired(
                                      model ?? l.translationModel,
                                    ),
                                    style: TextStyle(
                                      color: themeColors['errorForeground'],
                                    ),
                                  ),
                                ],
                                if (_entrySubmitted)
                                  Text(
                                    l.translationEntrySubmitted,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color:
                                          themeColors['descriptionForeground'],
                                    ),
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
                                    _capture?.requestsImmediateTranslation ==
                                                true &&
                                            !_entrySubmitted
                                        ? '${l.translationAutoTracePaused} ${l.translationTraceWarning}'
                                        : l.translationTraceWarning,
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
