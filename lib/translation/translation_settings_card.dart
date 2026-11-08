import 'dart:async';

import 'package:flutter/material.dart';

import '../ide/ide_button.dart';
import '../l10n/l10n.dart';
import '../settings/pages/settings_widgets.dart';
import '../settings/pages/stash_hotkey_field.dart';
import '../settings/user_settings.dart';
import 'translation_host.dart';

class TranslationSettingsCard extends StatefulWidget {
  const TranslationSettingsCard({super.key, this.settings});
  final UserSettings? settings;

  @override
  State<TranslationSettingsCard> createState() =>
      _TranslationSettingsCardState();
}

class _TranslationSettingsCardState extends State<TranslationSettingsCard> {
  bool _failed = false;

  Future<void> _write(String value) async {
    try {
      await widget.settings?.update(TranslationHost.hotkeyKey, value);
      if (mounted) setState(() => _failed = false);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final zh = context.l10n.localeName.startsWith('zh');
    final host = TranslationHost.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([host, ?widget.settings]),
      builder: (context, _) {
        final hotkey = switch (widget.settings?[TranslationHost.hotkeyKey]) {
          final String value => value,
          _ => TranslationHost.defaultHotkey,
        };
        return SettingsCard(
          children: [
            SettingsRow(
              label: zh ? '全局划词翻译' : 'Global selection translation',
              description: [
                if (host.supported)
                  zh
                      ? '在任意应用选中文字后按快捷键，预览原文并点击翻译。小窗直接显示在选区附近，无需打开主窗口。BaoCode 需保持运行；开启托盘后可关闭主窗口到托盘，退出应用后快捷键失效。'
                      : 'Select text in another app, press the shortcut, then click Translate. A floating panel opens near the selection without opening the main window. BaoCode must stay running: enable the tray to close the main window to it. Quitting disables the shortcut.'
                else
                  zh ? '当前平台支持应用内翻译；跨应用快捷键目前仅支持 Windows。' : 'In-app translation is available. The cross-app shortcut currently requires Windows.',
                zh
                    ? '仅发送你确认的文字给「模型 → ${context.l10n.modelsQuickAsk}」配置的提供方；不保存翻译记录，不监听剪贴板。无法读取的应用请手动粘贴。'
                    : 'Only confirmed text is sent to the provider configured under Models → Quick Ask. No history or clipboard monitoring. Paste manually if an app cannot expose its selection.',
                if (host.hotkeyTaken == false && hotkey.isNotEmpty)
                  zh ? '快捷键注册失败，可能被其他应用占用。请更换组合键。' : 'Could not register this shortcut. Another app may own it; choose a different combination.',
                if (_failed)
                  zh
                      ? '设置未能保存，请检查设置文件。'
                      : 'Could not save. Check the settings file.',
              ].join('\n'),
              trailing: host.supported
                  ? SettingsButtons(
                      children: [
                        StashHotkeyField(
                          hotkey: hotkey,
                          semanticLabel: zh ? '翻译快捷键' : 'Translation shortcut',
                          onRecordingStart: host.pause,
                          onRecordingStop: host.resume,
                          onChanged: (value) => unawaited(_write(value)),
                        ),
                        IdeButton(
                          label: hotkey.isEmpty
                              ? (zh ? '启用' : 'Enable')
                              : (zh ? '停用' : 'Disable'),
                          secondary: true,
                          onPressed: widget.settings == null
                              ? null
                              : () => unawaited(
                                  _write(
                                    hotkey.isEmpty
                                        ? TranslationHost.defaultHotkey
                                        : '',
                                  ),
                                ),
                        ),
                      ],
                    )
                  : null,
            ),
          ],
        );
      },
    );
  }
}
