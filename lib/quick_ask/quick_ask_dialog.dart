import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

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
import 'quick_ask_diff.dart';
import 'quick_ask_popup.dart';
import 'quick_ask_review.dart';
import 'quick_ask_service.dart';

/// A non-modal popup. Capture the source before focus moves; only an explicit
/// send contacts a model. Escape/Close restores focus, an outside click does not.
Future<void> showQuickAsk(
  BuildContext context, {
  QuickAskContext? source,
  QuickAskService? service,
  FutureOr<bool> Function(String prompt)? onAgentSubmit,
  String? agentLabel,
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
      onAgentSubmit: onAgentSubmit,
      agentLabel: agentLabel,
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
    this.onAgentSubmit,
    this.agentLabel,
    this.fallbackAnchor,
    this.initialAnchor,
    required this.overlayContext,
    this.ownerContext,
    this.ownerRoute,
    required this.onClose,
  });

  final QuickAskContext? source;
  final QuickAskService? service;
  final FutureOr<bool> Function(String prompt)? onAgentSubmit;
  final String? agentLabel;
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
  bool _agent = false;
  bool _handingOff = false;
  Completer<void>? _cancel;
  int _generation = 0;
  String? _answer;
  String? _error;
  bool _includeContext = true;
  bool _includeSelection = true;
  bool _showContext = false;
  bool _applying = false;
  bool _applied = false;
  QuickAskDiff? _diff;
  bool _editProposal = false;
  bool _complete = false;
  bool _copied = false;
  bool _pickingMenu = false;
  final _frameKey = GlobalKey();
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
        (!_pickingMenu && widget.ownerRoute?.isCurrent == false)) {
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

  String get _proposed => _diff?.replacement ?? _replacement.text;

  void _reviewReplacement() {
    _diff = QuickAskDiff(widget.source!.selectedText, _replacement.text);
    _copied = false;
  }

  void _changeReview() {
    setState(() {
      _copied = false;
      final text = _proposed;
      final selection = _replacement.selection;
      _replacement.value = TextEditingValue(
        text: text,
        selection: selection.isValid
            ? TextSelection(
                baseOffset: selection.baseOffset.clamp(0, text.length),
                extentOffset: selection.extentOffset.clamp(0, text.length),
              )
            : TextSelection.collapsed(offset: text.length),
      );
    });
  }

  bool get _busy => _cancel != null || _handingOff;
  bool get _canEdit =>
      _includeSelection &&
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

  void _insertNewline() {
    final value = _question.value;
    if (ChatKeys.isComposing || !value.composing.isCollapsed) return;
    final editable = _focus.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (editable == null) return;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    // Treat this as keyboard editing, preserving the field's undo and input
    // connection behavior instead of assigning the controller behind it.
    editable.userUpdateTextEditingValue(
      TextEditingValue(
        text: value.text.replaceRange(start, end, '\n'),
        selection: TextSelection.collapsed(offset: start + 1),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  Future<void> _send() async {
    if (_busy ||
        _applying ||
        ChatKeys.isComposing ||
        !_question.value.composing.isCollapsed) {
      return;
    }
    final l10n = context.l10n;
    final question = _question.text.trim();
    if (question.isEmpty || question.length > quickAskQuestionLimit) {
      setState(() => _error = l10n.quickAskQuestionHint);
      return;
    }
    if (_agent) {
      final submit = widget.onAgentSubmit;
      if (submit == null) return;
      setState(() {
        _handingOff = true;
        _error = null;
      });
      try {
        final accepted = await submit(
          buildQuickAskAgentPrompt(
            question: question,
            selectedText: _includeSelection
                ? widget.source?.selectedText ?? ''
                : '',
            selectionTruncated:
                _includeSelection && (widget.source?.truncated ?? false),
            surroundingText: _includeContext
                ? widget.source?.contextText ?? ''
                : '',
            source: widget.source?.sourceLabel,
          ),
        );
        if (!mounted) return;
        if (accepted) {
          widget.onClose(false);
          return;
        }
        setState(() => _error = l10n.quickAskAgentFailed);
      } on Object {
        // A send may have reached its kernel before throwing. Do not retry it.
        if (mounted) setState(() => _error = l10n.quickAskAgentFailed);
      } finally {
        if (mounted) setState(() => _handingOff = false);
      }
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
      _diff = null;
      _editProposal = false;
    });
    try {
      final answer = await _service.ask(
        question: question,
        selectedText: _includeSelection
            ? widget.source?.selectedText ?? ''
            : '',
        selectionTruncated:
            _includeSelection && (widget.source?.truncated ?? false),
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
        if (_mode == QuickAskMode.edit) _reviewReplacement();
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
        _mode != QuickAskMode.edit ||
        _diff?.hasChanges != true) {
      return;
    }
    setState(() => _applying = true);
    var applied = false;
    try {
      applied = await apply(_proposed);
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
              ? _proposed
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
      _diff = null;
      _editProposal = false;
    });
    _focus.requestFocus();
  }

  void _setAgent(bool agent) {
    if (_busy || _applying || (agent && widget.onAgentSubmit == null)) return;
    setState(() {
      _agent = agent;
      _mode = QuickAskMode.ask;
      _answer = null;
      _error = null;
      _complete = false;
      _applied = false;
      _copied = false;
      _diff = null;
      _editProposal = false;
    });
    _focus.requestFocus();
  }

  Future<void> _menu({bool modes = false, Offset? position}) async {
    if (_pickingMenu) return;
    final anchor = anchorOf(_frameKey.currentContext!);
    if (anchor == null) return;
    final l10n = context.l10n;
    _pickingMenu = true;
    try {
      await showIdeMenu(
        context,
        anchor: position == null ? anchor : null,
        position: position,
        entries: modes
            ? [
                IdeMenuAction(
                  'Chat',
                  checked: !_agent,
                  enabled: !_busy && !_applying,
                  onSelected: () => _setAgent(false),
                ),
                IdeMenuAction(
                  'Agent',
                  checked: _agent,
                  enabled: !_busy && !_applying && widget.onAgentSubmit != null,
                  onSelected: () => _setAgent(true),
                ),
              ]
            : [
                IdeMenuAction(
                  _busy ? l10n.quickAskStop : l10n.quickAskSend,
                  keybinding: _busy ? null : 'Enter',
                  enabled: !_applying && !_handingOff,
                  onSelected: () =>
                      _busy ? setState(_stop) : unawaited(_send()),
                ),
                if (!_agent) ...[
                  IdeMenuAction(
                    l10n.quickAskAsk,
                    checked: _mode == QuickAskMode.ask,
                    enabled: !_busy && !_applying,
                    onSelected: () => _setMode(QuickAskMode.ask),
                  ),
                  IdeMenuAction(
                    l10n.quickAskEdit,
                    checked: _mode == QuickAskMode.edit,
                    enabled: !_busy && !_applying && _canEdit,
                    onSelected: () => _setMode(QuickAskMode.edit),
                  ),
                ],
                const IdeMenuSeparator(),
                if (widget.source != null) ...[
                  IdeMenuAction(
                    _showContext
                        ? l10n.quickAskHideContext
                        : l10n.quickAskShowContext,
                    onSelected: () =>
                        setState(() => _showContext = !_showContext),
                  ),
                  if (widget.source!.selectedText.isNotEmpty)
                    IdeMenuAction(
                      l10n.quickAskSelection,
                      checked: _includeSelection,
                      enabled: !_busy && !_applying,
                      onSelected: () => setState(() {
                        _includeSelection = !_includeSelection;
                        if (!_includeSelection) _mode = QuickAskMode.ask;
                        _answer = null;
                        _complete = false;
                      }),
                    ),
                  if (widget.source!.contextText.isNotEmpty)
                    IdeMenuAction(
                      _includeContext
                          ? l10n.quickAskContextOn
                          : l10n.quickAskContextOff,
                      checked: _includeContext,
                      enabled: !_busy && !_applying,
                      onSelected: () =>
                          setState(() => _includeContext = !_includeContext),
                    ),
                ],
                if (!_agent)
                  IdeMenuAction(
                    quickAskModelName(l10n, _providers),
                    enabled: !_busy && !_applying,
                    submenu: auxiliaryModelEntries(
                      l10n,
                      _providers,
                      current:
                          _providers.quickAskModel ??
                          ModelProviders.followAuxiliary,
                      auto: ModelProviders.followAuxiliary,
                      autoLabel: l10n.aiModelAuxiliary,
                      onPick: (model) =>
                          unawaited(_providers.setQuickAskModel(model)),
                    ),
                  ),
                if (_answer != null) ...[
                  const IdeMenuSeparator(),
                  IdeMenuAction(
                    _copied ? l10n.quickAskCopied : l10n.quickAskCopy,
                    onSelected: () => unawaited(_copy()),
                  ),
                  if (_mode == QuickAskMode.edit && _complete)
                    IdeMenuAction(
                      l10n.quickAskProposed,
                      checked: _editProposal,
                      enabled: !_busy && !_applying && !_applied,
                      onSelected: () => setState(() {
                        _editProposal = !_editProposal;
                        if (_editProposal) {
                          _replacement.text = _proposed;
                        }
                      }),
                    ),
                  if (_mode == QuickAskMode.edit &&
                      widget.source?.canApply == true)
                    IdeMenuAction(
                      _applied ? l10n.quickAskApplied : l10n.quickAskApply,
                      enabled:
                          _complete &&
                          !_busy &&
                          !_applied &&
                          !_applying &&
                          _diff?.hasChanges == true,
                      onSelected: () => unawaited(_apply()),
                    ),
                ],
                const IdeMenuSeparator(),
                IdeMenuAction(
                  l10n.dialogCloseDialog,
                  keybinding: 'Esc',
                  enabled: !_applying && !_handingOff,
                  onSelected: () => widget.onClose(true),
                ),
              ],
      );
    } finally {
      _pickingMenu = false;
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
        const SingleActivator(LogicalKeyboardKey.f10, shift: true): () =>
            unawaited(_menu()),
        const SingleActivator(LogicalKeyboardKey.contextMenu): () =>
            unawaited(_menu()),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!ChatKeys.isComposing &&
              _question.value.composing.isCollapsed &&
              !_applying &&
              !_handingOff) {
            widget.onClose(true);
          }
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
              if (!_pickingMenu && !_applying && !_handingOff) {
                widget.onClose(false);
              }
            },
            child: GestureDetector(
              key: _frameKey,
              onSecondaryTapUp: (details) =>
                  unawaited(_menu(position: details.globalPosition)),
              child: Semantics(
                customSemanticsActions: {
                  CustomSemanticsAction(label: l10n.quickAskShowContext): () =>
                      unawaited(_menu()),
                  if (!_busy && !_applying)
                    CustomSemanticsAction(label: l10n.quickAskSend): () =>
                        unawaited(_send()),
                  if (_cancel != null)
                    CustomSemanticsAction(label: l10n.quickAskStop): () =>
                        setState(_stop),
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
                          color: colors['widget.shadow'].withValues(
                            alpha: 0.18,
                          ),
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
                                  shift: true,
                                ): _insertNewline,
                                const SingleActivator(
                                  LogicalKeyboardKey.enter,
                                  includeRepeats: false,
                                ): () =>
                                    unawaited(_send()),
                                const SingleActivator(
                                  LogicalKeyboardKey.enter,
                                  includeRepeats: false,
                                  control: true,
                                ): () =>
                                    unawaited(_send()),
                                const SingleActivator(
                                  LogicalKeyboardKey.enter,
                                  includeRepeats: false,
                                  meta: true,
                                ): () =>
                                    unawaited(_send()),
                              },
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: QuickAskAction(
                                key: const ValueKey('quick-ask-mode'),
                                label: _agent ? 'Agent' : 'Chat',
                                help: _agent
                                    ? '${l10n.quickAskAgentHint}${widget.agentLabel == null ? '' : '\n${widget.agentLabel}'}'
                                    : '${l10n.quickAskChatHint}\n${quickAskModelName(l10n, _providers)}',
                                icon: Codicons.chevronDown,
                                showLabel: true,
                                onPressed: _busy || _applying
                                    ? null
                                    : () => unawaited(_menu(modes: true)),
                              ),
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
                              const SizedBox(height: 6),
                              SelectableText(
                                _agent
                                    ? l10n.quickAskAgentHint
                                    : l10n.quickAskPrivacy,
                                style: textStyle,
                              ),
                              if (source.truncated && _includeSelection)
                                Text(
                                  l10n.quickAskTruncated,
                                  style: TextStyle(
                                    color: colors['editorWarning.foreground'],
                                  ),
                                ),
                              if (_includeSelection &&
                                  source.selectedText.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                preview(
                                  l10n.quickAskSelection,
                                  source.selectedText,
                                ),
                              ],
                              if (hasContext && _includeContext) ...[
                                const SizedBox(height: 6),
                                preview(
                                  l10n.quickAskNearby,
                                  source.contextText,
                                ),
                              ],
                            ],
                            if (_error case final error?) ...[
                              const SizedBox(height: 6),
                              Text(
                                error,
                                style: TextStyle(
                                  color: colors['errorForeground'],
                                ),
                              ),
                            ],
                            if (_answer case final answer?) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: Container(
                                  height: 1,
                                  color: colors['editorWidget.foreground']
                                      .withValues(alpha: 0.08),
                                ),
                              ),
                              if (edit) ...[
                                if (!_complete) ...[
                                  preview(
                                    l10n.quickAskOriginal,
                                    source!.selectedText,
                                  ),
                                  const SizedBox(height: 6),
                                  SelectableText(answer, style: textStyle),
                                ] else if (_applied)
                                  SelectableText(_proposed, style: textStyle)
                                else ...[
                                  if (_diff case final diff?)
                                    QuickAskReview(
                                      diff: diff,
                                      enabled: !_applying && !_busy,
                                      onChanged: _changeReview,
                                    ),
                                  if (_editProposal && !_applying) ...[
                                    const SizedBox(height: 8),
                                    IdeInputBox(
                                      key: const ValueKey(
                                        'quick-ask-replacement',
                                      ),
                                      controller: _replacement,
                                      minLines: 1,
                                      maxLines: 8,
                                      semanticsLabel: l10n.quickAskProposed,
                                      onChanged: (_) =>
                                          setState(_reviewReplacement),
                                    ),
                                  ],
                                  if (source!.canApply) ...[
                                    const SizedBox(height: 8),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: QuickAskAction(
                                        key: const ValueKey('quick-ask-apply'),
                                        label: l10n.quickAskApply,
                                        help: l10n.quickAskApplyHint,
                                        icon: Codicons.check,
                                        showLabel: true,
                                        primary: true,
                                        onPressed:
                                            _applying ||
                                                _busy ||
                                                _diff?.hasChanges != true
                                            ? null
                                            : () => unawaited(_apply()),
                                      ),
                                    ),
                                  ],
                                ],
                              ] else
                                Semantics(
                                  label: l10n.quickAskAnswer,
                                  child: SelectionArea(
                                    child: MarkdownView(
                                      answer,
                                      style: textStyle,
                                    ),
                                  ),
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
        ),
      ),
    );
  }
}
