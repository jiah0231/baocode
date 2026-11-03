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
  bool _retainSubmittedDraftOnBlur = false;
  String? _urlAtSubmission;

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
    final controlLabel = widget.manualControl ? l10n.browserPanelResume : l10n.browserPanelTakeOver;
    final controlTooltip = widget.manualControl
        ? l10n.browserPanelResumeTooltip
        : l10n.browserPanelTakeOverTooltip;
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
                              ),
                            ),
                          Text(
                            status,
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 11,
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
                          onTapOutside: (_) => _addressFocus.unfocus(),
                        ),
                      ),
                    ),
                  ),
                ),
                TextFieldTapRegion(
                  child: _action(
                    Codicons.arrowRight,
                    l10n.browserPanelGo,
                    _submitAddress,
                  ),
                ),
              ],
            ),
            if (widget.bindingNotice case final notice?
                when notice.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  notice,
                  key: const ValueKey('browser-panel-binding-notice'),
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                l10n.browserPanelChromeNotice,
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ),
            if (widget.manualControl)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.browserPanelPausedNotice,
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                ),
              ),
            if (widget.error case final error? when error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    style: TextStyle(fontSize: 12, color: AppColors.caution),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
