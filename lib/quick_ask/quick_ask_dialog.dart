import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_keys.dart';
import '../ide/ide_button.dart';
import '../ide/ide_hover.dart';
import '../ide/ide_input.dart';
import '../ide/ide_menu.dart';
import '../kernel/claude_code/claude_haiku.dart';
import '../l10n/l10n.dart';
import '../models/auxiliary_model_menu.dart';
import '../models/model_providers.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show WorkbenchThemeService, themeColors;
import 'quick_ask_context.dart';
import 'quick_ask_service.dart';

/// The snapshot is captured before the dialog takes focus. No request is
/// made until Send; closing cancels the one-shot request and discards it.
Future<void> showQuickAsk(
  BuildContext context, {
  QuickAskContext? source,
  QuickAskService? service,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierLabel: context.l10n.commonDismiss,
  barrierColor: const Color(0x40000000),
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) =>
      QuickAskDialog(source: source, service: service),
);

class QuickAskDialog extends StatefulWidget {
  const QuickAskDialog({super.key, this.source, this.service});

  final QuickAskContext? source;
  final QuickAskService? service;

  @override
  State<QuickAskDialog> createState() => _QuickAskDialogState();
}

class _QuickAskDialogState extends State<QuickAskDialog> {
  final _question = TextEditingController();
  final _replacement = TextEditingController();
  final _focus = FocusNode();
  late final _service = widget.service ?? QuickAskService();
  late final _providers = ModelProviders.current;
  QuickAskMode _mode = QuickAskMode.ask;
  Completer<void>? _cancel;
  int _generation = 0;
  String? _answer;
  String? _error;
  bool _includeContext = true;
  bool _showContext = false;
  bool _applying = false;
  bool _applied = false;
  bool _copied = false;

  bool get _busy => _cancel != null;
  bool get _canEdit =>
      widget.source?.selectedText.isNotEmpty == true &&
      widget.source?.truncated != true;

  @override
  void dispose() {
    _stop();
    _question.dispose();
    _replacement.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _stop() {
    _generation++;
    final cancel = _cancel;
    _cancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  Future<void> _send() async {
    if (_busy || _applying || ChatKeys.isComposing) return;
    final l10n = context.l10n;
    final question = _question.text.trim();
    if (question.isEmpty || question.length > quickAskQuestionLimit) {
      setState(() => _error = l10n.quickAskQuestionHint);
      return;
    }
    final cancel = Completer<void>();
    final generation = ++_generation;
    setState(() {
      _cancel = cancel;
      _answer = null;
      _error = null;
      _applied = false;
      _copied = false;
      _replacement.clear();
    });
    try {
      final answer = await _service.ask(
        question: question,
        selectedText: widget.source?.selectedText ?? '',
        surroundingText: _includeContext
            ? widget.source?.contextText ?? ''
            : '',
        source: widget.source?.sourceLabel,
        mode: _mode,
        cancel: cancel.future,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _answer = answer;
        _replacement.text = answer;
      });
    } on ClaudeHaikuCancelled {
      // Cancellation deliberately leaves no error or late result.
    } on QuickAskException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(
        () => _error = error.reason == QuickAskFailure.timeout
            ? l10n.quickAskTimeout
            : l10n.quickAskFailed,
      );
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() => _error = l10n.quickAskFailed);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _cancel = null);
      }
    }
  }

  Future<void> _apply() async {
    final apply = widget.source?.applyReplacement;
    if (apply == null ||
        _applying ||
        _busy ||
        _applied ||
        _answer == null ||
        _mode != QuickAskMode.edit) {
      return;
    }
    setState(() => _applying = true);
    var applied = false;
    try {
      applied = await apply(_replacement.text);
    } on Object {
      // Keep the proposed text available to copy when its source went away.
    }
    if (!mounted) return;
    setState(() {
      _applying = false;
      _applied = applied;
      _error = applied ? null : context.l10n.quickAskSourceChanged;
    });
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(
        ClipboardData(
          text: _mode == QuickAskMode.edit ? _replacement.text : _answer ?? '',
        ),
      );
      if (mounted) setState(() => _copied = true);
    } on Object {
      if (mounted) setState(() => _error = context.l10n.quickAskCopyFailed);
    }
  }

  void _setMode(QuickAskMode mode) {
    if (_busy || _applying || mode == _mode) return;
    setState(() {
      _mode = mode;
      _answer = null;
      _error = null;
      _applied = false;
      _copied = false;
    });
    _focus.requestFocus();
  }

  Future<void> _pickModel(Rect anchor) => showIdeMenu(
    context,
    anchor: anchor,
    entries: auxiliaryModelEntries(
      context.l10n,
      _providers,
      current: _providers.quickAskModel,
      autoLabel: context.l10n.aiModelAuxiliary,
      onPick: (model) => unawaited(_providers.setQuickAskModel(model)),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([WorkbenchThemeService.instance, _providers]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final l10n = context.l10n;
    final colors = themeColors;
    final size = MediaQuery.sizeOf(context);
    final source = widget.source;
    final foreground = colors['editorWidget.foreground'];
    final secondary = colors['descriptionForeground'];
    final hasContext = source?.contextText.isNotEmpty == true;
    final edit = _mode == QuickAskMode.edit;
    final textStyle = TextStyle(fontSize: 12, height: 1.5, color: foreground);
    Widget preview(String label, String text) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: secondary)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(8),
          color: colors['textCodeBlock.background'],
          child: SelectableText(text, style: textStyle),
        ),
      ],
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!ChatKeys.isComposing && !_applying) Navigator.pop(context);
        },
      },
      child: FocusScope(
        autofocus: true,
        child: Align(
          alignment: const Alignment(0, -0.35),
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              key: const ValueKey('quick-ask-frame'),
              width: math.min(660.0, math.max(0.0, size.width - 24)),
              constraints: BoxConstraints(
                maxHeight: math.max(0.0, size.height - 48),
              ),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors['editorWidget.background'],
                border: Border.all(
                  color: colors.get('widget.border') ?? colors['focusBorder'],
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(color: colors['widget.shadow'], blurRadius: 20),
                ],
              ),
              child: DefaultTextStyle(
                style: textStyle,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Codicons.sparkle, size: 16, color: foreground),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.quickAskTitle,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IdeActionButton(
                          icon: Codicons.close,
                          tooltip: l10n.dialogCloseDialog,
                          onPressed: _applying
                              ? null
                              : () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                IdeButton(
                                  label: l10n.quickAskAsk,
                                  secondary: edit,
                                  onPressed: _busy
                                      ? null
                                      : () => _setMode(QuickAskMode.ask),
                                ),
                                IdeButton(
                                  label: l10n.quickAskEdit,
                                  secondary: !edit,
                                  onPressed: _busy || !_canEdit
                                      ? null
                                      : () => _setMode(QuickAskMode.edit),
                                ),
                                Builder(
                                  builder: (context) => IdeButton(
                                    label: quickAskModelName(l10n, _providers),
                                    secondary: true,
                                    onPressed: _busy
                                        ? null
                                        : () {
                                            final anchor = anchorOf(context);
                                            if (anchor != null) {
                                              unawaited(_pickModel(anchor));
                                            }
                                          },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              source?.sourceLabel ?? l10n.quickAskNoSelection,
                              style: TextStyle(fontSize: 11, color: secondary),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.quickAskPrivacy,
                              style: TextStyle(fontSize: 11, color: secondary),
                            ),
                            if (source?.truncated == true) ...[
                              const SizedBox(height: 4),
                              Text(
                                l10n.quickAskTruncated,
                                style: TextStyle(
                                  color: colors['editorWarning.foreground'],
                                ),
                              ),
                            ],
                            if (source != null) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  IdeButton(
                                    label: _showContext
                                        ? l10n.quickAskHideContext
                                        : l10n.quickAskShowContext,
                                    secondary: true,
                                    onPressed: () => setState(
                                      () => _showContext = !_showContext,
                                    ),
                                  ),
                                  if (hasContext)
                                    IdeButton(
                                      label: _includeContext
                                          ? l10n.quickAskContextOn
                                          : l10n.quickAskContextOff,
                                      secondary: true,
                                      onPressed: _busy
                                          ? null
                                          : () => setState(
                                              () => _includeContext =
                                                  !_includeContext,
                                            ),
                                    ),
                                ],
                              ),
                              if (_showContext) ...[
                                const SizedBox(height: 8),
                                if (source.selectedText.isNotEmpty)
                                  preview(
                                    l10n.quickAskSelection,
                                    source.selectedText,
                                  ),
                                if (hasContext && _includeContext) ...[
                                  const SizedBox(height: 8),
                                  preview(
                                    l10n.quickAskNearby,
                                    source.contextText,
                                  ),
                                ],
                              ],
                            ],
                            const SizedBox(height: 12),
                            IdeInputBox(
                              key: const ValueKey('quick-ask-question'),
                              controller: _question,
                              focusNode: _focus,
                              autofocus: true,
                              minLines: 2,
                              maxLines: 5,
                              semanticsLabel: l10n.quickAskQuestionHint,
                              placeholder: edit
                                  ? l10n.quickAskEditHint
                                  : l10n.quickAskQuestionHint,
                              shortcuts: {
                                const SingleActivator(
                                  LogicalKeyboardKey.enter,
                                  control: true,
                                ): () =>
                                    unawaited(_send()),
                                const SingleActivator(
                                  LogicalKeyboardKey.enter,
                                  meta: true,
                                ): () =>
                                    unawaited(_send()),
                              },
                            ),
                            if (_error case final error?) ...[
                              const SizedBox(height: 8),
                              Text(
                                error,
                                style: TextStyle(
                                  color: colors['errorForeground'],
                                ),
                              ),
                            ],
                            if (_answer case final answer?) ...[
                              const SizedBox(height: 12),
                              if (edit) ...[
                                preview(
                                  l10n.quickAskOriginal,
                                  source!.selectedText,
                                ),
                                const SizedBox(height: 8),
                                Text(l10n.quickAskProposed),
                                const SizedBox(height: 4),
                                if (_applied || _applying)
                                  SelectableText(
                                    _replacement.text,
                                    style: textStyle,
                                  )
                                else
                                  IdeInputBox(
                                    key: const ValueKey(
                                      'quick-ask-replacement',
                                    ),
                                    controller: _replacement,
                                    minLines: 3,
                                    maxLines: 12,
                                    semanticsLabel: l10n.quickAskProposed,
                                    onChanged: (_) {
                                      if (_copied) {
                                        setState(() => _copied = false);
                                      }
                                    },
                                  ),
                                const SizedBox(height: 6),
                                Text(
                                  source.canApply
                                      ? l10n.quickAskApplyHint
                                      : l10n.quickAskCopyHint,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: secondary,
                                  ),
                                ),
                              ] else
                                preview(l10n.quickAskAnswer, answer),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  IdeButton(
                                    label: _copied
                                        ? l10n.quickAskCopied
                                        : l10n.quickAskCopy,
                                    secondary: true,
                                    onPressed: () => unawaited(_copy()),
                                  ),
                                  if (edit && source!.canApply)
                                    IdeButton(
                                      label: _applied
                                          ? l10n.quickAskApplied
                                          : l10n.quickAskApply,
                                      onPressed: _applied || _applying
                                          ? null
                                          : () => unawaited(_apply()),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.quickAskSendHint,
                            style: TextStyle(fontSize: 11, color: secondary),
                          ),
                        ),
                        IdeButton(
                          label: _busy ? l10n.quickAskStop : l10n.quickAskSend,
                          spinning: _busy,
                          onPressed: _applying
                              ? null
                              : () {
                                  if (_busy) {
                                    setState(_stop);
                                  } else {
                                    unawaited(_send());
                                  }
                                },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
