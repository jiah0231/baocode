import 'dart:async';

import 'package:flutter/material.dart';

import '../ide/ide_button.dart';
import '../l10n/l10n.dart';
import '../settings/pages/settings_widgets.dart';
import '../settings/pages/stash_hotkey_field.dart';
import '../settings/user_settings.dart';
import 'translation_host.dart';
import 'translation_strings.dart';

class TranslationSettingsCard extends StatefulWidget {
  const TranslationSettingsCard({super.key, this.settings, this.host});
  final UserSettings? settings;
  final TranslationHost? host;

  @override
  State<TranslationSettingsCard> createState() =>
      _TranslationSettingsCardState();
}

class _TranslationSettingsCardState extends State<TranslationSettingsCard> {
  bool _failed = false;

  Future<void> _write(String key, Object value) async {
    try {
      await widget.settings?.update(key, value);
      if (mounted) setState(() => _failed = false);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final zh = context.l10n.localeName.startsWith('zh');
    final host = widget.host ?? TranslationHost.instance;
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
                      ? '在其他应用选中文字后按快捷键，预览原文并点击翻译。小窗直接显示在选区附近，无需打开主窗口。BaoCode 需保持运行；开启托盘后可关闭主窗口到托盘，退出应用后快捷键失效。'
                      : 'Select text in another app, press the shortcut, then click Translate. A floating panel opens near the selection without opening the main window. BaoCode must stay running: enable the tray to close the main window to it. Quitting disables the shortcut.'
                else
                  zh ? '当前平台支持应用内翻译；跨应用快捷键目前仅支持 Windows。' : 'In-app translation is available. The cross-app shortcut currently requires Windows.',
                zh
                    ? '仅发送你确认的文字给「模型 → ${context.l10n.modelsQuickAsk}」配置的提供方；不保存翻译记录，不监听剪贴板。不支持直接读取的应用可使用下方的自动复制选项；仍无法取得文字时请手动粘贴。'
                    : 'Only confirmed text is sent to the provider configured under Models → Quick Ask. No history or clipboard monitoring. Use the automatic-copy option below for supported apps without direct selection access, or paste manually.',
                if (host.hotkeyTaken == false && hotkey.isNotEmpty)
                  zh ? '快捷键注册失败，可能被其他应用占用。请更换组合键。' : 'Could not register this shortcut. Another app may own it; choose a different combination.',
                if (host.selectionActionTaken == false &&
                    widget.settings?[TranslationHost.selectionActionKey] !=
                        false)
                  zh ? '选词按钮未能启用。仍可尝试翻译快捷键，或关闭后重新开启选词按钮。' : 'The selection button could not be enabled. Try the translation shortcut, or turn the selection button off and back on.',
                if (host.lastCaptureWarning == 'clipboardRestoreFailed')
                  context.l10n.translationClipboardRestoreFailed,
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
                          onChanged: (value) => unawaited(
                            _write(TranslationHost.hotkeyKey, value),
                          ),
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
                                    TranslationHost.hotkeyKey,
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
            if (host.supported) ...[
              SettingsSwitchRow(
                label: zh
                    ? '选词后显示翻译按钮'
                    : 'Show a translation button after selection',
                description: zh
                    ? '选中文字后在附近显示小按钮。检测时不读取正文；点击「译」后才获取原文、打开翻译窗并请求翻译；敏感或不确定内容先预览确认。'
                    : 'Show a small button near selected text. Detection does not read text; clicking Translate captures the source, opens the panel and requests translation. Sensitive or uncertain content stays in preview for confirmation.',
                value:
                    widget.settings?[TranslationHost.selectionActionKey] !=
                    false,
                enabled: widget.settings != null,
                onChanged: (value) => unawaited(
                  _write(TranslationHost.selectionActionKey, value),
                ),
              ),
              SettingsSwitchRow(
                label: zh ? '自动复制选中文字' : 'Automatically copy selected text',
                description: zh
                    ? '仅点击选词按钮或按翻译快捷键后，在支持的非敏感控件中尝试复制无法直接读取的选中文字。会临时使用剪贴板，剪贴板管理器或云同步可能看到这些文字。明确点击选词后的「译」或面板翻译后才发送到模型；关闭本选项后可手动粘贴。'
                    : 'After clicking the selection button or pressing the translation shortcut, try copying the selection from supported non-sensitive controls when direct reading fails. This temporarily uses the clipboard; clipboard managers or cloud sync may see the text. Only an explicit Translate click on the selection button or in the panel sends it to the model. Turn this off to paste manually.',
                value:
                    widget.settings?[TranslationHost.clipboardFallbackKey] !=
                    false,
                enabled: widget.settings != null,
                onChanged: (value) => unawaited(
                  _write(TranslationHost.clipboardFallbackKey, value),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
