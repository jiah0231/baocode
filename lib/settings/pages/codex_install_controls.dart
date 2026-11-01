import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../kernel/codex/codex_install.dart';
import '../../l10n/l10n.dart';
import 'settings_widgets.dart';

/// No background install or upgrade: metadata check, exact release confirmation,
/// verified install, then select that path for new local sessions.
class CodexInstallControls extends StatefulWidget {
  const CodexInstallControls({
    super.key,
    required this.onInstalled,
    this.installer,
  });
  final Future<void> Function(String path) onInstalled;
  final CodexInstaller? installer;
  @override
  State<CodexInstallControls> createState() => _CodexInstallControlsState();
}

class _CodexInstallControlsState extends State<CodexInstallControls> {
  late final CodexInstaller _installer =
      widget.installer ?? createCodexInstaller();
  // Shared across settings-page rebuilds: closing/reopening Settings must not
  // start a second installer or lose the result of the first operation.
  static final _operations =
      <String, ValueNotifier<({bool busy, String? message})>>{};
  late final _operation = _operations.putIfAbsent(
    _installer.directory,
    () => ValueNotifier((busy: false, message: null)),
  );
  bool get _busy => _operation.value.busy;
  void _report(String? message, {bool? busy}) {
    _operation.value = (busy: busy ?? _busy, message: message);
  }

  Future<void> _install() async {
    if (_busy) return;
    final l10n = context.l10n;
    final onInstalled = widget.onInstalled;
    _report(l10n.codexInstallChecking, busy: true);
    try {
      final release = await _installer.latest();
      if (!mounted) {
        _report(null);
        return;
      }
      final answer = await showIdeDialog(
        context,
        message: l10n.codexInstallConfirm,
        detail:
            '${l10n.codexInstallConfirmDetail}\n\n'
            '${release.version} · ${(release.size / (1024 * 1024)).toStringAsFixed(1)} MB\n'
            '${release.url}\n${_installer.directory}',
        buttons: [l10n.codexInstallProceed],
      );
      if (answer != 0 || !mounted) {
        _report(null);
        return;
      }
      final path = await _installer.install(release, _report);
      await onInstalled(path);
      _report('${l10n.codexInstallDone}\n$path');
    } on Object catch (error) {
      _report('${l10n.codexInstallFailed}\n$error');
    } finally {
      _report(_operation.value.message, busy: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_installer.supported) return const SizedBox.shrink();
    final l10n = context.l10n;
    return ValueListenableBuilder(
      valueListenable: _operation,
      builder: (context, operation, _) => SettingsRow(
        label: l10n.codexInstallTitle,
        description: l10n.codexInstallDescription,
        below: [
          if (operation.message != null)
            SelectableText(operation.message!, style: SettingsText.path),
        ],
        trailing: IdeButton(
          label: _busy ? l10n.codexInstallBusy : l10n.codexInstallAction,
          secondary: true,
          onPressed: _busy ? null : () => unawaited(_install()),
        ),
      ),
    );
  }
}
