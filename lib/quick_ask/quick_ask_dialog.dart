import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_keys.dart';
import '../chat/widgets/markdown_view.dart';
import '../ide/ide_input.dart';
import '../ide/ide_menu.dart';
import '../kernel/claude_code/claude_haiku.dart';
import '../l10n/l10n.dart';
import '../models/auxiliary_model_menu.dart';
import '../models/model_providers.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show WorkbenchThemeService, themeColors;
import 'quick_ask_context.dart';
import 'quick_ask_popup.dart';
import 'quick_ask_service.dart';

/// A non-modal popup. Capture the source before focus moves; only an explicit
/// send contacts a model. Escape/Close restores focus, an outside click does not.
Future<void> showQuickAsk(
  BuildContext context, {
  QuickAskContext? source,
  QuickAskService? service,
}) {
  final done = Completer<void>();
  final previousFocus = FocusManager.instance.primaryFocus;
  final overlay = Overlay.of(context, rootOverlay: true);
  final focusBox = previousFocus?.context?.findRenderObject();
  final fallback =
      focusBox is RenderBox && focusBox.attached && focusBox.hasSize
      ? focusBox.localToGlobal(Offset.zero) & focusBox.size
      : null;
  late final OverlayEntry entry;
  void close(bool restoreFocus) {
    if (done.isCompleted) return;
    entry.remove();
    entry.dispose();
    if (restoreFocus &&
        previousFocus?.context?.mounted == true &&
        previousFocus!.canRequestFocus) {
      previousFocus.requestFocus();
    }
    done.complete();
  }

  final themes = InheritedTheme.capture(from: context, to: overlay.context);
  final route = ModalRoute.of(context);
  final popup = Localizations.override(
    context: context,
    child: QuickAskDialog(
      source: source,
      service: service,
      fallbackAnchor: fallback,
      initialAnchor: source?.selectionAnchor?.call(),
      overlayContext: overlay.context,
      ownerContext: context,
      ownerRoute: route,
      onClose: close,
    ),
  );
  entry = OverlayEntry(
    builder: (_) => Positioned.fill(child: themes.wrap(popup)),
  );
  // An overlay can disappear during navigation/window teardown, without Close.
  entry.addListener(() {
    if (!entry.mounted && !done.isCompleted) {
      scheduleMicrotask(() => close(false));
    }
  });
  overlay.insert(entry);
  return done.future;
}

class QuickAskDialog extends StatefulWidget {
  const QuickAskDialog({
    super.key,
    this.source,
    this.service,
    this.fallbackAnchor,
    this.initialAnchor,
    required this.overlayContext,
    this.ownerContext,
    this.ownerRoute,
    required this.onClose,
  });

  final QuickAskContext? source;
  final QuickAskService? service;
  final Rect? fallbackAnchor;
  final Rect? initialAnchor;
  final BuildContext overlayContext;
  final BuildContext? ownerContext;
  final ModalRoute<dynamic>? ownerRoute;
  final void Function(bool restoreFocus) onClose;

  @override
  State<QuickAskDialog> createState() => _QuickAskDialogState();
}

class _QuickAskDialogState extends State<QuickAskDialog> {
  final _question = TextEditingController();
  final _replacement = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
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
  bool _complete = false;
  bool _copied = false;
  bool _pickingModel = false;
  Rect? _lastAnchor;
  final _anchorPosition = ValueNotifier<Rect?>(null);

  @override
  void initState() {
    super.initState();
    _lastAnchor = widget.initialAnchor;
    _anchorPosition.value = _localAnchor(_lastAnchor ?? widget.fallbackAnchor);
    widget.source?.selectionAnchorListenable?.addListener(_scheduleAnchor);
    WidgetsBinding.instance.addPostFrameCallback(_trackAnchor);
  }

  void _trackAnchor(Duration _) {
    if (!mounted) return;
    if (widget.ownerContext?.mounted == false ||
        (!_pickingModel && widget.ownerRoute?.isCurrent == false)) {
      widget.onClose(false);
      return;
    }
    final current = widget.source?.selectionAnchor?.call();
    if (current != null && current.isFinite) _lastAnchor = current;
    _anchorPosition.value = _localAnchor(_lastAnchor ?? widget.fallbackAnchor);
    // Observe frames already caused by source layout, without an idle ticker.
    WidgetsBinding.instance.addPostFrameCallback(_trackAnchor);
  }

  void _scheduleAnchor() => WidgetsBinding.instance.ensureVisualUpdate();

  Rect? _localAnchor(Rect? global) {
    final box = widget.overlayContext.findRenderObject();
    if (global == null || box is! RenderBox || !box.attached) return null;
    return Rect.fromPoints(
      box.globalToLocal(global.topLeft),
      box.globalToLocal(global.bottomRight),
    );
  }

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
    _scroll.dispose();
    widget.source?.selectionAnchorListenable?.removeListener(_scheduleAnchor);
    _anchorPosition.dispose();
    super.dispose();
  }

  void _stop() {
    _generation++;
    final cancel = _cancel;
    _cancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  // Follow new output only while the reader is already at the bottom.
  // A user scrolling upward between receiving a chunk and layout wins.
  void _followOutput(int generation) {
    if (!_scroll.hasClients || _scroll.position.extentAfter > 32) return;
    final before = _scroll.offset;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || !_scroll.hasClients) return;
      if (_scroll.offset < before - 1) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
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
      _complete = false;
      _error = null;
      _applied = false;
      _copied = false;
      _replacement.clear();
    });
    try {
      final answer = await _service.ask(
        question: question,
        selectedText: widget.source?.selectedText ?? '',
        selectionTruncated: widget.source?.truncated ?? false,
        surroundingText: _includeContext
            ? widget.source?.contextText ?? ''
            : '',
        source: widget.source?.sourceLabel,
        sessionModel: widget.source?.sessionModel,
        mode: _mode,
        cancel: cancel.future,
        onText: (text) {
          if (!mounted || generation != _generation || text == _answer) return;
          _followOutput(generation);
          setState(() => _answer = text);
        },
      );
      if (!mounted || generation != _generation) return;
      _followOutput(generation);
      setState(() {
        _answer = answer;
        _complete = true;
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
        !_complete ||
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
          text: _mode == QuickAskMode.edit && _complete
              ? _replacement.text
              : _answer ?? '',
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
      _complete = false;
      _error = null;
      _applied = false;
      _copied = false;
    });
    _focus.requestFocus();
  }

  Future<void> _pickModel(Rect anchor) async {
    _pickingModel = true;
    try {
      await showIdeMenu(
        context,
        anchor: anchor,
        entries: auxiliaryModelEntries(
          context.l10n,
          _providers,
          current: _providers.quickAskModel ?? ModelProviders.followAuxiliary,
          auto: ModelProviders.followAuxiliary,
          autoLabel: context.l10n.aiModelAuxiliary,
          onPick: (model) => unawaited(_providers.setQuickAskModel(model)),
        ),
      );
    } finally {
      _pickingModel = false;
      if (mounted) _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([WorkbenchThemeService.instance, _providers]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final l10n = context.l10n;
    final colors = themeColors;
    final source = widget.source;
    final hasContext = source?.contextText.isNotEmpty == true;
    final edit = _mode == QuickAskMode.edit;
    final textStyle = TextStyle(
      fontSize: 13,
      height: 1.55,
      fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
      color: colors['editorWidget.foreground'],
    );
    Widget preview(String label, String text) => Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors['editorWidget.foreground'].withValues(alpha: 0.035),
          borderRadius: BorderRadius.circular(6),
        ),
        child: SelectableText(text, style: textStyle),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!ChatKeys.isComposing && !_applying) widget.onClose(true);
        },
      },
      child: FocusScope(
        autofocus: true,
        child: CustomSingleChildLayout(
          delegate: QuickAskLayout(
            anchor: _anchorPosition,
            insets:
                MediaQuery.paddingOf(context) +
                MediaQuery.viewInsetsOf(context),
          ),
          child: TapRegion(
            onTapOutside: (_) {
              if (!_pickingModel && !_applying) widget.onClose(false);
            },
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                key: const ValueKey('quick-ask-frame'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors['editorWidget.background'],
                  border: Border.all(
                    color:
                        colors.get('widget.border') ??
                        colors['editorWidget.foreground'].withValues(
                          alpha: 0.18,
                        ),
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: colors['widget.shadow'].withValues(alpha: 0.18),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: DefaultTextStyle(
                  style: textStyle,
                  child: SingleChildScrollView(
                    key: const ValueKey('quick-ask-scroll'),
                    controller: _scroll,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        IdeInputBox(
                          key: const ValueKey('quick-ask-question'),
                          controller: _question,
                          focusNode: _focus,
                          autofocus: true,
                          minLines: 1,
                          maxLines: 4,
                          radius: 7,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          semanticsLabel: edit
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
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          alignment: WrapAlignment.spaceBetween,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: colors['editorWidget.foreground']
                                    .withValues(alpha: 0.045),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  QuickAskAction(
                                    label: l10n.quickAskAsk,
                                    icon: Codicons.comment,
                                    selected: !edit,
                                    onPressed: _busy || _applying
                                        ? null
                                        : () => _setMode(QuickAskMode.ask),
                                  ),
                                  QuickAskAction(
                                    label: l10n.quickAskEdit,
                                    icon: Codicons.edit,
                                    selected: edit,
                                    onPressed: _busy || _applying || !_canEdit
                                        ? null
                                        : () => _setMode(QuickAskMode.edit),
                                  ),
                                ],
                              ),
                            ),
                            Builder(
                              builder: (context) => QuickAskAction(
                                label: quickAskModelName(l10n, _providers),
                                icon: Codicons.chip,
                                onPressed: _busy || _applying
                                    ? null
                                    : () {
                                        final anchor = anchorOf(context);
                                        if (anchor != null) {
                                          unawaited(_pickModel(anchor));
                                        }
                                      },
                              ),
                            ),
                            if (source != null)
                              QuickAskAction(
                                label: _showContext
                                    ? l10n.quickAskHideContext
                                    : l10n.quickAskShowContext,
                                icon: Codicons.eye,
                                selected: _showContext,
                                onPressed: () => setState(
                                  () => _showContext = !_showContext,
                                ),
                              ),
                            if (hasContext)
                              QuickAskAction(
                                label: _includeContext
                                    ? l10n.quickAskContextOn
                                    : l10n.quickAskContextOff,
                                icon: Codicons.attach,
                                selected: _includeContext,
                                onPressed: _busy || _applying
                                    ? null
                                    : () => setState(
                                        () =>
                                            _includeContext = !_includeContext,
                                      ),
                              ),
                            if (source?.truncated == true)
                              Semantics(
                                label: l10n.quickAskTruncated,
                                child: Icon(
                                  Codicons.warning,
                                  size: 16,
                                  color: colors['editorWarning.foreground'],
                                ),
                              ),
                            QuickAskAction(
                              label: l10n.dialogCloseDialog,
                              icon: Codicons.close,
                              onPressed: _applying
                                  ? null
                                  : () => widget.onClose(true),
                            ),
                            QuickAskAction(
                              primary: true,
                              label: _busy
                                  ? l10n.quickAskStop
                                  : l10n.quickAskSend,
                              icon: _busy ? Codicons.debugStop : Codicons.send,
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
                        if (_busy)
                          Semantics(
                            label: l10n.langLoading,
                            liveRegion: true,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  key: const ValueKey('quick-ask-progress'),
                                  width: 32,
                                  height: 2,
                                  decoration: BoxDecoration(
                                    color: colors['button.background'],
                                    borderRadius: BorderRadius.circular(1),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (_showContext && source != null) ...[
                          if (source.selectedText.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            preview(
                              l10n.quickAskSelection,
                              source.selectedText,
                            ),
                          ],
                          if (hasContext && _includeContext) ...[
                            const SizedBox(height: 6),
                            preview(l10n.quickAskNearby, source.contextText),
                          ],
                        ],
                        if (_error case final error?) ...[
                          const SizedBox(height: 6),
                          Text(
                            error,
                            style: TextStyle(color: colors['errorForeground']),
                          ),
                        ],
                        if (_answer case final answer?) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Container(
                              height: 1,
                              color: colors['editorWidget.foreground']
                                  .withValues(alpha: 0.08),
                            ),
                          ),
                          if (edit) ...[
                            preview(
                              l10n.quickAskOriginal,
                              source!.selectedText,
                            ),
                            const SizedBox(height: 6),
                            if (!_complete)
                              SelectableText(answer, style: textStyle)
                            else if (_applied || _applying)
                              SelectableText(
                                _replacement.text,
                                style: textStyle,
                              )
                            else
                              IdeInputBox(
                                key: const ValueKey('quick-ask-replacement'),
                                controller: _replacement,
                                minLines: 1,
                                maxLines: 8,
                                semanticsLabel: l10n.quickAskProposed,
                                onChanged: (_) {
                                  if (_copied) setState(() => _copied = false);
                                },
                              ),
                          ] else
                            Semantics(
                              label: l10n.quickAskAnswer,
                              child: SelectionArea(
                                child: MarkdownView(answer, style: textStyle),
                              ),
                            ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              QuickAskAction(
                                label: _copied
                                    ? l10n.quickAskCopied
                                    : l10n.quickAskCopy,
                                icon: _copied ? Codicons.check : Codicons.copy,
                                onPressed: () => unawaited(_copy()),
                              ),
                              if (edit && source!.canApply)
                                QuickAskAction(
                                  label: _applied
                                      ? l10n.quickAskApplied
                                      : l10n.quickAskApply,
                                  icon: Codicons.checkAll,
                                  selected: _applied,
                                  onPressed:
                                      !_complete ||
                                          _busy ||
                                          _applied ||
                                          _applying
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
