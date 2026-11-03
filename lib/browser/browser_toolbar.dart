import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ide/ide_button.dart';
import '../ide/ide_hover.dart';
import '../ide/ide_input.dart';
import '../ide/ide_menu.dart';
import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';

/// Controls the Chrome tab displayed in the browser panel.
///
/// This widget owns only the address draft. The panel controller validates
/// addresses, performs navigation, and decides which actions are available.
/// A null callback disables its action. [connected] gates only actions on the
/// selected page; tab selection and global agent control remain available.
class BrowserPanelToolbar extends StatefulWidget {
  const BrowserPanelToolbar({
    super.key,
    required this.title,
    required this.url,
    required this.tabs,
    this.onBack,
    this.onForward,
    this.onReload,
    this.onNew,
    this.onClose,
    this.onShow,
    this.onTakeOver,
    this.onResume,
    this.onReconnectAgent,
    required this.onNavigate,
    required this.manualControl,
    this.connected = true,
    this.browserName,
    this.bindingNotice,
    this.error,
  });

  final String title;
  final String url;
  final FutureOr<List<IdeMenuEntry>> Function() tabs;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final VoidCallback? onReload;
  final VoidCallback? onNew;
  final VoidCallback? onClose;
  final VoidCallback? onShow;
  final VoidCallback? onTakeOver;
  final VoidCallback? onResume;

  /// Offered only when the caller can recover this chat's dead connection.
  /// Reconnecting does not change the global agent pause state.
  final VoidCallback? onReconnectAgent;
  final ValueChanged<String> onNavigate;
  final bool manualControl;

  /// Whether the selected page is usable, not whether every bridge is offline.
  final bool connected;
  final String? browserName;

  /// Localized explanation of the viewed and agent-bound connections.
  /// The caller owns connection selection and recovery; this is display-only.
  final String? bindingNotice;
  final String? error;

  @override
  State<BrowserPanelToolbar> createState() => _BrowserPanelToolbarState();
}

class _BrowserPanelToolbarState extends State<BrowserPanelToolbar> {
  late final TextEditingController _address;
  final FocusNode _addressFocus = FocusNode(debugLabel: 'browser address');
  final FocusNode _helpFocus = FocusNode(debugLabel: 'browser help');
  final ScrollController _noticesScroll = ScrollController();
  bool _retainSubmittedDraftOnBlur = false;
  String? _urlAtSubmission;
  bool _helpFocused = false;
  bool _helpOpen = false;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(text: widget.url);
    _addressFocus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(BrowserPanelToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Tab events and screencast rebuilds must not replace an address that
    // the user is typing, including an active input-method composition.
    if (!_addressFocus.hasFocus && oldWidget.url != widget.url) {
      _restoreAddress();
    }
    if (oldWidget.connected && !widget.connected) {
      _retainSubmittedDraftOnBlur = false;
      _addressFocus.unfocus();
    }
  }

  @override
  void dispose() {
    _addressFocus.removeListener(_focusChanged);
    _addressFocus.dispose();
    _helpFocus.dispose();
    _noticesScroll.dispose();
    _address.dispose();
    super.dispose();
  }

  void _restoreAddress() {
    _address.value = TextEditingValue(
      text: widget.url,
      selection: TextSelection.collapsed(offset: widget.url.length),
    );
  }

  void _focusChanged() {
    if (!_addressFocus.hasFocus) {
      // Leave a submitted address visible until navigation supplies its
      // resulting URL. A rejected address also stays available to correct.
      if (!_retainSubmittedDraftOnBlur || widget.url != _urlAtSubmission) {
        _restoreAddress();
      }
      _retainSubmittedDraftOnBlur = false;
      _urlAtSubmission = null;
    }
    if (mounted) setState(() {});
  }

  void _cancelEditing() {
    _retainSubmittedDraftOnBlur = false;
    _restoreAddress();
    _addressFocus.unfocus();
  }

  void _submitAddress([String? submitted]) {
    if (!widget.connected) return;
    final address = submitted ?? _address.text;
    if (address.trim().isEmpty) {
      _cancelEditing();
      return;
    }
    _retainSubmittedDraftOnBlur = _addressFocus.hasFocus;
    _urlAtSubmission = widget.url;
    _addressFocus.unfocus();
    // The controller, not the text field, normalizes and validates schemes.
    widget.onNavigate(address);
  }

  Future<void> _showHelp() async {
    if (_helpOpen) return;
    _helpOpen = true;
    final l10n = context.l10n;
    final paused = widget.manualControl;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.surface,
          scrollable: true,
          title: Text(
            '${l10n.sidePanelBrowser} · ${l10n.menuHelp}',
            style: TextStyle(fontSize: 14, color: AppColors.text),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.browserPanelChromeNotice,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: AppColors.text,
                ),
              ),
              if (paused) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.browserPanelPausedNotice,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: AppColors.text,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.commonClose),
            ),
          ],
        ),
      );
    } finally {
      _helpOpen = false;
    }
  }

  Widget _action(
    IconData icon,
    String label,
    VoidCallback? callback, {
    bool requiresTab = true,
  }) => IdeActionButton(
    icon: icon,
    tooltip: label,
    size: 26,
    onPressed: !requiresTab || widget.connected ? callback : null,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final browserName = widget.browserName?.trim();
    final status = widget.connected
        ? l10n.browserPanelConnected(
            browserName == null || browserName.isEmpty ? 'Chrome' : browserName,
          )
        : l10n.browserPanelUnavailable;
    final title = widget.title.isEmpty ? widget.url : widget.title;
    final controlLabel = widget.manualControl
        ? l10n.browserPanelResume
        : l10n.browserPanelTakeOver;
    final controlTooltip = widget.manualControl
        ? '${l10n.browserPanelResumeTooltip}\n${l10n.browserPanelPausedNotice}'
        : l10n.browserPanelTakeOverTooltip;
    final helpTooltip = [
      l10n.menuHelp,
      l10n.browserPanelChromeNotice,
      if (widget.manualControl) l10n.browserPanelPausedNotice,
    ].join('\n\n');
    final bindingNotice = widget.bindingNotice;
    final error = widget.error;
    final hasBindingNotice =
        bindingNotice != null && bindingNotice.trim().isNotEmpty;
    final hasError = error != null && error.isNotEmpty;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.partBorder)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) => Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: math.min(164.0, constraints.maxWidth),
                    child: IdeHover(
                      message: title.isEmpty ? status : '$title\n$status',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (title.isNotEmpty)
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 12,
                                height: 1.3,
                              ),
                            ),
                          Text(
                            status,
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 11,
                              height: 1.3,
                            ),
                          ),
                          if (widget.manualControl)
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                l10n.browserPanelPausedShort,
                                style: TextStyle(
                                  color: AppColors.caution,
                                  fontSize: 11,
                                  height: 1.3,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  IdeMenuButton(
                    icon: Codicons.listFlat,
                    tooltip: l10n.browserSharedTabs,
                    entries: widget.tabs,
                    size: 26,
                  ),
                  _action(
                    Codicons.add,
                    l10n.browserPanelNewTab,
                    widget.onNew,
                    requiresTab: false,
                  ),
                  _action(Codicons.close, l10n.browserPanelCloseTab, widget.onClose),
                  _action(
                    Codicons.linkExternal,
                    l10n.browserShowInBrowser,
                    widget.onShow,
                  ),
                  if (widget.onReconnectAgent case final reconnect?)
                    IdeHover(
                      message: l10n.browserPanelReconnectAgentTooltip,
                      child: IdeButton(
                        label: l10n.browserPanelReconnectAgent,
                        icon: Codicons.plug,
                        secondary: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        onPressed: reconnect,
                      ),
                    ),
                  IdeHover(
                    message: controlTooltip,
                    child: IdeButton(
                      label: controlLabel,
                      icon: widget.manualControl
                          ? Codicons.play
                          : Codicons.debugPause,
                      secondary: !widget.manualControl,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      onPressed: widget.manualControl
                          ? widget.onResume
                          : widget.onTakeOver,
                    ),
                  ),
                  FocusableActionDetector(
                    key: const ValueKey('browser-panel-help'),
                    focusNode: _helpFocus,
                    onShowFocusHighlight: (focused) {
                      if (mounted) setState(() => _helpFocused = focused);
                    },
                    shortcuts: const {
                      SingleActivator(LogicalKeyboardKey.enter):
                          ActivateIntent(),
                      SingleActivator(LogicalKeyboardKey.space):
                          ActivateIntent(),
                    },
                    actions: {
                      ActivateIntent: CallbackAction<ActivateIntent>(
                        onInvoke: (_) {
                          unawaited(_showHelp());
                          return null;
                        },
                      ),
                    },
                    child: IdeActionButton(
                      icon: Codicons.info,
                      tooltip: helpTooltip,
                      size: 26,
                      checked: _helpFocused,
                      onPressed: () => unawaited(_showHelp()),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                _action(Codicons.arrowLeft, l10n.browserPanelBack, widget.onBack),
                _action(Codicons.arrowRight, l10n.browserPanelForward, widget.onForward),
                _action(Codicons.refresh, l10n.browserReload, widget.onReload),
                const SizedBox(width: 4),
                Expanded(
                  child: TextFieldTapRegion(
                    key: const ValueKey('browser-panel-address-region'),
                    groupId: _addressFocus,
                    // EditableText installs its outside callback only after a
                    // focused rebuild. Keep this region registered and read
                    // focus at event time, including between those frames.
                    onTapOutside: (_) {
                      if (_addressFocus.hasFocus) _cancelEditing();
                    },
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.escape):
                            _cancelEditing,
                      },
                      child: Semantics(
                        label: l10n.browserPanelAddress,
                        textField: true,
                        child: Container(
                          decoration: BoxDecoration(
                            color: IdeInputColors.background,
                            border: Border.all(
                              color: _addressFocus.hasFocus
                                  ? IdeInputColors.focusBorder
                                  : IdeInputColors.border,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: TextField(
                            key: const ValueKey('browser-panel-address'),
                            groupId: _addressFocus,
                            controller: _address,
                            focusNode: _addressFocus,
                            enabled: widget.connected,
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.go,
                            autocorrect: false,
                            enableSuggestions: false,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: IdeInputColors.foreground,
                            ),
                            cursorColor: IdeInputColors.foreground,
                            decoration: InputDecoration(
                              hintText: l10n.browserPanelAddress,
                              hintStyle: TextStyle(
                                color: IdeInputColors.placeholder,
                              ),
                              isDense: true,
                              isCollapsed: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 5,
                              ),
                              border: InputBorder.none,
                              visualDensity: VisualDensity.standard,
                            ),
                            // Keep focus changes under _submitAddress's control.
                            onEditingComplete: () {},
                            onSubmitted: _submitAddress,
                            // The enclosing region owns outside cancellation;
                            // do not also run the platform's default focus policy.
                            onTapOutside: (_) {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                TextFieldTapRegion(
                  groupId: _addressFocus,
                  child: _action(
                    Codicons.arrowRight,
                    l10n.browserPanelGo,
                    _submitAddress,
                  ),
                ),
              ],
            ),
            if (hasBindingNotice || hasError)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: ConstrainedBox(
                  // Long profile names and error details must remain readable
                  // without pushing the page and navigation off the screen.
                  constraints: BoxConstraints(
                    maxHeight: math.min(
                      160.0,
                      MediaQuery.sizeOf(context).height / 4,
                    ),
                  ),
                  child: Scrollbar(
                    controller: _noticesScroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      key: const ValueKey('browser-panel-notices'),
                      controller: _noticesScroll,
                      primary: false,
                      padding: const EdgeInsets.only(right: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (bindingNotice case final notice?
                              when notice.trim().isNotEmpty)
                            Text(
                              notice,
                              key: const ValueKey(
                                'browser-panel-binding-notice',
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.3,
                                color: AppColors.textMuted,
                              ),
                            ),
                          if (error case final message?
                              when message.isNotEmpty) ...[
                            if (hasBindingNotice) const SizedBox(height: 5),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                message,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  color: AppColors.caution,
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
          ],
        ),
      ),
    );
  }
}
